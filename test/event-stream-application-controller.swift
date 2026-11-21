import Foundation

private final class Observer {
    let pid: Int32
    init(_ pid: Int32) { self.pid = pid }
}

@main
struct Tests {
    @MainActor static func main() {
        var checks = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), "FAIL: \(name)")
            checks += 1; print("PASS: \(name)")
        }
        var recording = false, sequence = 0
        var events: [String] = []
        var identities: [EventStreamRecordIdentity] = []
        var records: [EventStreamRecord] = []
        var deniedMetadata: EventStreamApp? = .init(name: "Denied", secureInput: false, processIdentifier: 3)
        enum Failure: Error { case observer }
        var fails = false, returnsNil = false
        weak var released: Observer?
        let controller = EventStreamApplicationCaptureController<Int32, Observer>(backend: .init(
            isRecording: { recording }, processIdentifier: { $0 },
            nextIdentity: { date in
                sequence += 1; events.append("identity:\(sequence)")
                return .init(id: sequence, timestamp: date)
            }, observe: { pid in
                events.append("observe:\(pid)")
                if fails { throw Failure.observer }
                if returnsNil { return nil }
                let value = Observer(pid); released = value; return value
            }, stop: { events.append("stop:\($0.pid)") },
            applicationSnapshot: { pid in events.append("metadata:\(pid)"); return deniedMetadata },
            captureWindowChanged: { pid, identity in
                events.append("capture:\(pid)"); identities.append(identity)
            }, emit: { events.append("emit"); records.append($0) },
            observationFailed: { _, pid in events.append("error:\(pid)") }))
        let date = Date(timeIntervalSince1970: 123)
        controller.refresh(1, at: date)
        check("inactive refresh performs no reads or work", events.isEmpty && controller.currentProcessIdentifier == nil)
        recording = true
        controller.refresh(1, at: date)
        check("default policy installs observer before capture", events == ["identity:1", "observe:1", "capture:1"])
        check("event timestamp comes from notification", identities.last?.timestamp == date)
        check("controller retains active observer", released != nil && controller.hasObserver)
        events = []; controller.refresh(1, at: date)
        check("same permitted PID and active observer is a no-op", events.isEmpty)
        controller.refresh(2, at: date)
        check("PID switch allocates identity then replaces observer", events == ["identity:2", "stop:1", "observe:2", "capture:2"])
        check("PID tracks the actual switch", controller.currentProcessIdentifier == 2)
        events = []; controller.shouldCaptureApplication = { _ in false }
        controller.refresh(2, at: date)
        check("policy change on same PID stops AX and emits metadata", events == ["identity:3", "stop:2", "metadata:2", "emit"])
        check("denied path has no AX or input payload", records.last?.kind == .windowChanged && records.last?.ax == nil && records.last?.window == nil && records.last?.keyboard == nil && records.last?.mouse == nil)
        check("denied snapshot is forwarded", records.last?.app == deniedMetadata)
        check("stopped observer is released", released == nil && !controller.hasObserver)
        events = []; controller.refresh(2, at: date)
        check("same denied PID without observer is a no-op", events.isEmpty)
        deniedMetadata = nil; controller.refresh(3, at: date)
        check("denied PID switch can emit without application metadata", records.last?.app == nil && records.last?.id == 4)
        events = []; controller.shouldCaptureApplication = nil
        controller.refresh(3, at: date)
        check("clearing policy retries current PID with default permission", events == ["identity:5", "observe:3", "capture:3"])
        events = []; fails = true
        controller.refresh(4, at: date)
        check("observer failure reports error and still captures", events == ["identity:6", "stop:3", "observe:4", "error:4", "capture:4"])
        check("observer failure retains current PID without observer", controller.currentProcessIdentifier == 4 && !controller.hasObserver)
        events = []; controller.refresh(4, at: date)
        check("same allowed PID retries failed observer", events == ["identity:7", "observe:4", "error:4", "capture:4"])
        fails = false; returnsNil = true; events = []
        controller.refresh(4, at: date)
        check("nil observer also permits capture", events == ["identity:8", "observe:4", "capture:4"] && !controller.hasObserver)
        events = []; controller.refresh(0, at: date)
        check("zero PID captures without creating observer", events == ["identity:9", "capture:0"])
        events = []; controller.refresh(-1, at: date)
        check("negative PID captures without creating observer", events == ["identity:10", "capture:-1"])
        returnsNil = false; events = []; controller.refresh(5, at: date)
        check("valid PID resumes observation", controller.hasObserver && events == ["identity:11", "observe:5", "capture:5"])
        events = []; controller.stopObserver()
        check("observer stop leaves PID for ordered recorder cleanup", events == ["stop:5"] && controller.currentProcessIdentifier == 5)
        controller.stopObserver()
        check("repeated observer stop is inert", events == ["stop:5"])
        controller.clearCurrentApplication()
        check("PID cleanup is separate and emits nothing", controller.currentProcessIdentifier == nil && events == ["stop:5"])
        events = []; controller.refresh(5, at: date)
        check("new recording observation preserves shared identity sequence", identities.last?.id == 12 && events == ["identity:12", "observe:5", "capture:5"])
        recording = false; events = []; controller.refresh(6, at: date)
        check("inactive refresh preserves observer and PID until cleanup", events.isEmpty && controller.currentProcessIdentifier == 5 && controller.hasObserver)
        controller.stopObserver(); controller.clearCurrentApplication()
        check("final cleanup releases observer", released == nil && !controller.hasObserver && controller.currentProcessIdentifier == nil)
        print("\(checks) checks")
    }
}
