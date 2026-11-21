import AppKit
import CoreGraphics

struct LockScreenPhysicalInputEvent: Sendable {
    let sourcePID: Int64?
}

@MainActor final class SystemLockScreenPhysicalInputMonitor: LockScreenPhysicalInputMonitor {
    nonisolated static let eventTypes: [UInt32] = [1,2,3,4,5,6,7,10,11,12,22,23,24,25,26,27]
    nonisolated static let eventMask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
    private let ignoredProcessID: Int32
    private let events: @MainActor () -> AsyncStream<LockScreenPhysicalInputEvent>
    private var task: Task<Void, Never>?

    init(ignoredProcessID: Int32 = getpid(),
         events: @escaping @MainActor () -> AsyncStream<LockScreenPhysicalInputEvent> = LockScreenNativeInputTap.events) {
        self.ignoredProcessID = ignoredProcessID
        self.events = events
    }
    var isMonitoring: Bool { task != nil }
    func start(onInput: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        let events = self.events, ignored = ignoredProcessID
        task = Task { @MainActor in
            for await event in events() {
                guard !Task.isCancelled else { return }
                guard let source = event.sourcePID else { continue }
                // Perform a checked Int32 conversion, trapping on
                // an out-of-range injected value rather than truncating it.
                let sourcePID = Int32(source)
                guard sourcePID != ignored else { continue }
                onInput()
                return
            }
        }
    }
    func stop() {
        task?.cancel()
        task = nil
    }
    deinit { task?.cancel() }
}

/// Native producer matching EventTap.events: session/tail/listen-only,
/// unbounded stream, timeout reenable and termination-owned source cleanup.
private final class LockScreenNativeInputTap: @unchecked Sendable {
    private let continuation: AsyncStream<LockScreenPhysicalInputEvent>.Continuation
    private let lock = NSLock()
    private var stopped = false
    private var loop: CFRunLoop?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    @MainActor static func events() -> AsyncStream<LockScreenPhysicalInputEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let session = LockScreenNativeInputTap(continuation)
            continuation.onTermination = { [session] _ in session.stop() }
            session.start()
        }
    }
    private init(_ continuation: AsyncStream<LockScreenPhysicalInputEvent>.Continuation) {
        self.continuation = continuation
    }
    private func start() {
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let session = Unmanaged<LockScreenNativeInputTap>.fromOpaque(context).takeUnretainedValue()
            session.receive(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: SystemLockScreenPhysicalInputMonitor.eventMask,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            // EventTap's failed creation does not finish its AsyncStream.
            return
        }
        self.port = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CGEvent.tapEnable(tap: port, enable: true)
        let thread = Thread { [self] in run() }
        thread.name = "EventTap session tail listenOnly lock-screen"
        thread.start()
    }
    private func run() {
        let current = CFRunLoopGetCurrent()!
        lock.lock()
        if stopped { lock.unlock(); return }
        loop = current
        lock.unlock()
        CFRunLoopAddSource(current, source, .commonModes)
        while true {
            lock.lock(); let done = stopped; lock.unlock()
            if done { break }
            if CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false) == .finished { break }
        }
        CFRunLoopRemoveSource(current, source, .commonModes)
        lock.lock(); loop = nil; lock.unlock()
    }
    private func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let current = loop
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let current {
            CFRunLoopPerformBlock(current, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
            CFRunLoopWakeUp(current)
        }
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        lock.lock(); let done = stopped; lock.unlock()
        guard !done else { return }
        if type == .tapDisabledByTimeout {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        } else if type != .tapDisabledByUserInput {
            let cgEvent = NSEvent(cgEvent: event)?.cgEvent
            continuation.yield(.init(sourcePID: cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)))
        }
    }
}
