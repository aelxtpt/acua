import Foundation

/// Shows the service's approval dialogs (app approval and approval forms)
/// for requests that arrive on connection threads.
///
/// The XPC layer does not cancel a running request when its client exits
/// (handlers are allowed to finish), so the dialog also watches the
/// requesting process: once it is gone the dialog closes unanswered, and a
/// request still queued behind another dialog never opens one.
enum AcuaServiceDialogPresenter {
    /// Only one dialog at a time; a second request waits for the first answer.
    private static let dialogSlot = DispatchSemaphore(value: 1)

    /// `show` runs on the main thread and must return once `dismissal` is
    /// requested or its own timeout passes. `dismissed` is the answer when the
    /// dialog never opened or closed unanswered.
    static func present<Answer>(dismissed: Answer,
                                _ show: @escaping @MainActor (AcuaAppApprovalDismissal) -> Answer) -> Answer {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { show(.init()) }
        }

        let requester = RequestRuntime.peerPID
        let waitSeconds = AcuaAppApprovalDialog.timeoutSeconds + 5
        guard waitWhileRequesterRuns(dialogSlot, requester: requester, maximumSeconds: waitSeconds) else {
            return dismissed
        }
        defer { dialogSlot.signal() }

        guard isRunning(requester) else {
            return dismissed
        }

        let answered = DispatchSemaphore(value: 0)
        let answer = AnswerBox(dismissed)
        let dismissal = AcuaAppApprovalDismissal()
        DispatchQueue.main.async {
            answer.value = MainActor.assumeIsolated { show(dismissal) }
            answered.signal()
        }

        if !waitWhileRequesterRuns(answered, requester: requester, maximumSeconds: waitSeconds) {
            // The dialog polls the flag and closes within its poll interval.
            dismissal.request()
            answered.wait()
            return dismissed
        }
        return answer.value
    }

    /// Waits for `semaphore` while the request is live and its client runs.
    /// Returns false on cancellation, deadline, timeout or a client that exited.
    private static func waitWhileRequesterRuns(_ semaphore: DispatchSemaphore, requester: Int32?,
                                               maximumSeconds: TimeInterval) -> Bool {
        let pollSeconds = 0.25
        let limit = ProcessInfo.processInfo.systemUptime + maximumSeconds
        while ProcessInfo.processInfo.systemUptime < limit {
            do {
                try RequestRuntime.check()
            } catch {
                return false
            }

            if semaphore.wait(timeout: .now() + pollSeconds) == .success {
                return true
            }

            guard isRunning(requester) else { return false }
        }
        return false
    }

    /// A request without a peer PID (in-process) is treated as running.
    private static func isRunning(_ pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return true }
        // EPERM still means the process exists.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Written on the main thread, read after the semaphore signals.
    private final class AnswerBox<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }
}
