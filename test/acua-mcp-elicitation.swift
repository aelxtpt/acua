import Foundation
import MCP

// Unit tests for how the MCP helper asks the client for approval: never by
// elicitation to a client that did not declare it, and never past the
// cancellation of the tool call that asked. No client or service is involved;
// the elicitation itself is a closure.

@main
enum AcuaMCPElicitationTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct Failure: Error, Equatable {}

    /// An elicitation the client never answers.
    private static func neverAnswered() async throws -> CreateElicitation.Result {
        try await withCheckedThrowingContinuation { (_: CheckedContinuation<CreateElicitation.Result, Error>) in }
    }

    static func main() async {
        await untilCancelledTests()
        await capabilityTests()
        await eventStreamTests()
        print("\(passed) MCP elicitation tests passed")
    }

    // MARK: - Waiting no longer than the tool call

    private static func untilCancelledTests() async {
        let value = try? await AcuaMCPElicitation.untilCancelled { 42 }
        check("UntilCancelled_OperationFinishes_ReturnsItsValue", value == 42)

        do {
            _ = try await AcuaMCPElicitation.untilCancelled { () async throws -> Int in throw Failure() }
            check("UntilCancelled_OperationThrows_RethrowsItsError", false)
        } catch {
            check("UntilCancelled_OperationThrows_RethrowsItsError", error as? Failure == Failure())
        }

        // The SDK's elicitation wait ignores cancellation; the call must not.
        let started = Date()
        let waiting = Task { try await AcuaMCPElicitation.untilCancelled { try await neverAnswered() } }
        try? await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        let outcome = await waiting.result
        let elapsed = Date().timeIntervalSince(started)
        if case .failure(let error) = outcome {
            check("UntilCancelled_UnansweredAndCancelled_ThrowsCancellation", error is CancellationError, "\(error)")
        } else {
            check("UntilCancelled_UnansweredAndCancelled_ThrowsCancellation", false)
        }
        check("UntilCancelled_UnansweredAndCancelled_ReturnsPromptly", elapsed < 2, "\(elapsed)")

        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AcuaMCPElicitation.untilCancelled { try await neverAnswered() }
        }
        if case .failure(let error) = await alreadyCancelled.result {
            check("UntilCancelled_CallAlreadyCancelled_ThrowsCancellation", error is CancellationError)
        } else {
            check("UntilCancelled_CallAlreadyCancelled_ThrowsCancellation", false)
        }

        // An answer that arrives after the cancellation is dropped: the call
        // stays cancelled, and the late result resumes nothing a second time
        // (a double resume would crash this test).
        let answered = Counter()
        let late = Task {
            try await AcuaMCPElicitation.untilCancelled { () async throws -> Int in
                try? await Task.sleep(for: .milliseconds(300))
                answered.increment()
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        late.cancel()
        let lateOutcome = await late.result
        try? await Task.sleep(for: .milliseconds(400))
        if case .failure(let error) = lateOutcome {
            check("UntilCancelled_AnswerAfterCancellation_IsDropped", error is CancellationError && answered.count == 1)
        } else {
            check("UntilCancelled_AnswerAfterCancellation_IsDropped", false)
        }
    }

    // MARK: - Declared capability

    private final class Forms: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        func record(_ channel: String) { lock.lock(); asked.append(channel); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return asked }
    }

    private static let form = AcuaApprovalForm(message: "Allow?", detail: "Details", schema: .init())

    private static func capabilityTests() async {
        let withoutElicitation = Forms()
        let dialogAnswer = try? await AcuaMCPElicitation.request(form, clientSupportsElicitation: false,
            elicit: { _ in withoutElicitation.record("elicitation"); return .init(action: .accept) },
            serviceDialog: { _ in withoutElicitation.record("dialog"); return .init(action: .decline) })
        check("Request_ClientWithoutElicitation_AsksTheServiceDialog", withoutElicitation.all == ["dialog"], "\(withoutElicitation.all)")
        check("Request_ClientWithoutElicitation_ReturnsTheDialogsAnswer", dialogAnswer?.action == .decline)

        let withElicitation = Forms()
        let elicited = try? await AcuaMCPElicitation.request(form, clientSupportsElicitation: true,
            elicit: { _ in withElicitation.record("elicitation"); return .init(action: .accept) },
            serviceDialog: { _ in withElicitation.record("dialog"); return .init(action: .decline) })
        check("Request_ClientWithElicitation_SendsTheElicitationOnly", withElicitation.all == ["elicitation"], "\(withElicitation.all)")
        check("Request_ClientWithElicitation_ReturnsTheClientsAnswer", elicited?.action == .accept)

        // The dialog wait ends with the tool call too.
        let waiting = Task {
            try await AcuaMCPElicitation.request(form, clientSupportsElicitation: false,
                elicit: { _ in .init(action: .accept) }, serviceDialog: { _ in try await neverAnswered() })
        }
        try? await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        if case .failure(let error) = await waiting.result {
            check("Request_ServiceDialogAndCancelled_ThrowsCancellation", error is CancellationError)
        } else {
            check("Request_ServiceDialogAndCancelled_ThrowsCancellation", false)
        }
    }

    // MARK: - Record & Replay

    private final class EventStreamCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    private static func status(recording: Bool) -> ComputerUseIPCEventStreamSessionStatus {
        let data = Data(#"{"isRecording": \#(recording), "maxDurationSeconds": 1800}"#.utf8)
        return try! JSONDecoder().decode(ComputerUseIPCEventStreamSessionStatus.self, from: data)
    }

    private static func eventStream(_ calls: EventStreamCalls, answer: CreateElicitation.Result.Action) -> CUAMCPEventStream {
        CUAMCPEventStream(
            status: { calls.record("status"); return status(recording: false) },
            start: { calls.record("start"); return status(recording: true) },
            stop: { _ in calls.record("stop"); return status(recording: false) },
            telemetry: { _ in },
            serviceDialog: { form in
                calls.record("dialog: \(form.message) | \(form.detail ?? "")")
                return .init(action: answer)
            })
    }

    private static func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case .text(let text) = content { return text }
            return nil
        }.joined()
    }

    private static func eventStreamTests() async {
        // Never connected: an elicitation request would fail rather than reach anyone.
        let server = Server(name: "Record & Replay", version: "test")
        let start = CallTool.Parameters(name: "event_stream_start", arguments: [:])

        let declinedCalls = EventStreamCalls()
        let declined = await CUAMCPInvocationContext.$clientSupportsElicitation.withValue(false) {
            await eventStream(declinedCalls, answer: .decline).call(start, server: server)
        }
        check("EventStreamStart_ClientWithoutElicitation_AsksTheServiceDialog",
              declinedCalls.all == ["status", "dialog: \(CUAMCPEventStream.approvalMessage) | \(CUAMCPEventStream.approvalSubtitle)"],
              "\(declinedCalls.all)")
        check("EventStreamStart_DialogDeclined_IsTheElicitationDenial",
              declined.isError == true && text(declined) == "Record & Replay approval denied via MCP elicitation.", text(declined))

        let acceptedCalls = EventStreamCalls()
        let accepted = await CUAMCPInvocationContext.$clientSupportsElicitation.withValue(false) {
            await eventStream(acceptedCalls, answer: .accept).call(start, server: server)
        }
        check("EventStreamStart_DialogAllowed_StartsRecording",
              acceptedCalls.all.last == "start" && accepted.isError != true, "\(acceptedCalls.all) \(text(accepted))")
    }
}
