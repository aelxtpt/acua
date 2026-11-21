import AppKit
import ApplicationServices
import Foundation

struct ControllerFocusNativeEvent: @unchecked Sendable { let event: CGEvent }

/// Construct native packets without the legacy finite-geometry
/// guard or synthesized-input tagging. Construction does not post any event.
struct ControllerFocusNativeEvents: Sendable {
    enum Failure: Error { case cannotCreateEvent }
    let setWindowLocation: @Sendable (ControllerFocusNativeEvent, CGPoint) -> Void

    func events(_ packet: ControllerFocusPacket) throws -> [ControllerFocusNativeEvent] {
        switch packet {
        case .keyFocusReturned: return [try other(type: 21, subtype: Int16(bitPattern: 0x8000))]
        case .deactivation: return [try other(type: 13, subtype: 2)]
        case let .activation(id, frame, point):
            let activate = try other(type: 13, subtype: 1, id: id, flags: id == 0 ? 0 : 786432)
            guard id != 0, let frame, let point else { return [activate] }
            var result = [activate]
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: Int(id), context: nil, eventNumber: index + 1, clickCount: 1, pressure: 1)?.cgEvent else {
                    throw Failure.cannotCreateEvent
                }
                event.flags = []
                event.location = point
                event.setIntegerValueField(.mouseEventNumber, value: 0)
                event.setIntegerValueField(.mouseEventClickState, value: 3)
                event.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(id))
                event.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(id))
                let wrapper = ControllerFocusNativeEvent(event: event)
                let global = event.location
                setWindowLocation(wrapper, global.applying(.init(translationX: -frame.minX, y: -frame.minY)))
                result.append(wrapper)
            }
            return result
        }
    }
    private func other(type: UInt, subtype: Int16, id: UInt32 = 0, flags: UInt = 0) throws -> ControllerFocusNativeEvent {
        guard let type = NSEvent.EventType(rawValue: type),
              let event = NSEvent.otherEvent(with: type, location: .zero, modifierFlags: .init(rawValue: flags),
                timestamp: 0, windowNumber: Int(id), context: nil, subtype: subtype, data1: 0, data2: 0)?.cgEvent else {
            throw Failure.cannotCreateEvent
        }
        return .init(event: event)
    }
    func send(_ packet: ControllerFocusPacket, to pid: Int32) throws {
        for wrapper in try events(packet) {
            wrapper.event.timestamp = DispatchTime.now().uptimeNanoseconds
            wrapper.event.postToPid(pid)
        }
    }
}

/// One worker per tap, weak owner in native callback.
/// This class never prompts for input permissions. A failed native tap retains
/// its handler and may be retried.
final class ControllerFocusNativeTap: ControllerFocusTap, @unchecked Sendable {
    typealias Event = ControllerFocusNativeEvent
    typealias Handler = @Sendable (UInt32, Event) -> Event?
    private final class Callback: @unchecked Sendable { weak var owner: ControllerFocusNativeTap? }
    private final class Context {
        let callback: Callback
        let port: CFMachPort
        init(_ callback: Callback, _ port: CFMachPort) { self.callback = callback; self.port = port }
    }
    private let configuration: ControllerFocusTapConfiguration
    private let lock = NSLock()
    private var handler: Handler?
    private var port: CFMachPort?
    private var worker: SettingsAXObserverRunLoop?
    init(_ configuration: ControllerFocusTapConfiguration) { self.configuration = configuration }
    func start(_ handler: @escaping Handler) {
        lock.withLock {
            guard worker == nil else { return }
            self.handler = handler
            let callback = Callback(); callback.owner = self
            let nativeCallback: CGEventTapCallBack = { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let callback = Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue()
                guard let owner = callback.owner else { return Unmanaged.passUnretained(event) }
                return owner.receive(type, event).map { Unmanaged.passUnretained($0) }
            }
            let mask = configuration.types.reduce(UInt64(0)) { $0 | UInt64(1) << $1 }
            let place: CGEventTapPlacement = configuration.tail ? .tailAppendEventTap : .headInsertEventTap
            let options: CGEventTapOptions = configuration.listenOnly ? .listenOnly : .defaultTap
            let context = Unmanaged.passUnretained(callback).toOpaque()
            let result: CFMachPort?
            switch configuration.location {
            case .process(let pid):
                result = CGEvent.tapCreateForPid(pid: pid, place: place, options: options,
                    eventsOfInterest: mask, callback: nativeCallback, userInfo: context)
            case .annotatedSession:
                result = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: place, options: options,
                    eventsOfInterest: mask, callback: nativeCallback, userInfo: context)
            }
            guard let result else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, result, 0)!
            port = result
            CGEvent.tapEnable(tap: result, enable: true)
            let next = SettingsAXObserverRunLoop(source: source, context: Context(callback, result),
                name: "EventTap \(configuration.location) \(place.rawValue)",
                qos: configuration.listenOnly ? .utility : .userInteractive)
            next.start(); worker = next
        }
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type.rawValue == UInt32.max { return event } // disabled by user input
        if type.rawValue == UInt32.max - 1 {
            let port = lock.withLock { port }
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return event
        }
        let handler = lock.withLock { handler }
        guard let handler else { return event }
        return handler(type.rawValue, .init(event: event))?.event
    }
    func stop() {
        let previous = lock.withLock {
            let previous = worker
            if worker != nil, let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port); self.port = nil }
            worker = nil
            return previous
        }
        previous?.detach()
    }
    deinit { stop() }
}
