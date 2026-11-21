import AppKit
import CoreGraphics

// Dedicated background run loop, annotated-session/tail/listen-only. No
// automatic startup: the complete recorder and its capture policy must own
// this source.
final class EventStreamInputTap {
    enum StartError: Error { case couldNotCreateTap, couldNotCreateSource }
    private var session: Session?
    private var handler: ((EventStreamInputObservation) -> Void)?

    var isInstalled: Bool { precondition(Thread.isMainThread); return session != nil }

    func start(windowOwner: @escaping (UInt32) -> Int32?,
               onInput: @escaping (EventStreamInputObservation) -> Void) throws {
        precondition(Thread.isMainThread)
        guard session == nil else { return }
        let next = Session()
        try next.configure()
        next.onEvent = { [weak self, weak next] type, event in
            // The tap must never wait for AX, a consumer, or the main thread.
            guard let copy = event.copy() else { return }
            DispatchQueue.main.async { [weak self, weak next] in
                guard let self, let next, self.session === next,
                      let observation = EventStreamInputObservation.read(type: type, event: copy, windowOwner: windowOwner) else { return }
                self.handler?(observation)
            }
        }
        handler = onInput
        session = next
        next.start()
    }

    func stop() {
        precondition(Thread.isMainThread)
        let old = session
        session = nil
        handler = nil
        old?.stop()
    }

    deinit { session?.stop() }

    private final class Session {
        var onEvent: ((CGEventType, CGEvent) -> Void)?
        private var port: CFMachPort?
        private var source: CFRunLoopSource?
        private let lock = NSLock()
        private var stopped = false
        private var loop: CFRunLoop?

        func configure() throws {
            let callback: CGEventTapCallBack = { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let session = Unmanaged<Session>.fromOpaque(context).takeUnretainedValue()
                session.receive(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }
            guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap,
                place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: EventStreamInputPolicy.eventMask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw StartError.couldNotCreateTap }
            port = tap
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                throw StartError.couldNotCreateSource
            }
            self.source = source
        }

        func start() {
            guard let port else { return }
            CGEvent.tapEnable(tap: port, enable: true)
            let thread = Thread { [self] in run() }
            thread.name = "EventTap EventStream annotatedSession tail listenOnly"
            thread.qualityOfService = .background
            thread.start()
        }

        private func run() {
            guard let source else { return }
            let current = CFRunLoopGetCurrent()!
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            loop = current
            lock.unlock()
            CFRunLoopAddSource(current, source, .commonModes)
            while true {
                lock.lock(); let done = stopped; lock.unlock()
                if done { break }
                CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
            }
            CFRunLoopRemoveSource(current, source, .commonModes)
            lock.lock(); loop = nil; lock.unlock()
        }

        func stop() {
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            stopped = true
            let current = loop
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
            if let current {
                // A queued stop also handles stop arriving just before Run starts.
                CFRunLoopPerformBlock(current, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
                CFRunLoopWakeUp(current)
            }
        }

        private func receive(type: CGEventType, event: CGEvent) {
            lock.lock(); let done = stopped; lock.unlock()
            guard !done else { return }
            if type == .tapDisabledByTimeout {
                if let port { CGEvent.tapEnable(tap: port, enable: true) }
            } else if type != .tapDisabledByUserInput {
                onEvent?(type, event)
            }
        }
    }
}
