import CoreGraphics
import Foundation

// Unit tests for the app snapshot when the app's window cannot be matched to a
// WindowServer window for a moment (a window that is opening, animating or
// changing size). A fake backend plays the app; nothing is captured.

private enum FakeFailure: Error, Equatable { case windowUnavailable, noPrimaryWindow, terminated }

@MainActor private final class FakeBackend: ControllerAppSnapshotBackend {
    typealias Context = String
    typealias Window = String
    typealias Plan = String
    typealias Cache = String
    typealias Previous = String
    typealias Selection = String
    typealias Image = String
    typealias Tree = String
    typealias Attachment = String

    /// Failures thrown by the first reads of the focused window, in order.
    var failures: [FakeFailure]
    var contextReads = 0
    var waits = 0
    var terminatesWhileWaiting = false
    var isTerminated = false

    init(failures: [FakeFailure]) { self.failures = failures }

    func terminatedError() -> any Error { FakeFailure.terminated }
    func focusedContext() throws -> String {
        contextReads += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        return "context"
    }
    func isTransientContextFailure(_ error: any Error) -> Bool { (error as? FakeFailure) == .windowUnavailable }
    func waitBeforeContextRetry() async throws {
        waits += 1
        if terminatesWhileWaiting { isTerminated = true }
    }

    var focusedMenuBarItem: String? { nil }
    var stageManagerEnabled: Bool { false }
    func prepareStageManager(_ context: String) async throws {}
    func plan(_ context: String, root: String?, skipScreenshot: Bool) throws -> String { "plan" }
    func visibleCursorWindowID() -> UInt32? { nil }
    var ownerDiffingEnabled: Bool { false }
    func previousRevision() -> String? { nil }
    func captureSelection(_ context: String, plan: String, root: String?, cache: String?,
                          previous: String?, enableDiffing: Bool) async throws -> String { "selection" }
    func captureImage(_ context: String, plan: String, cursorWindowID: UInt32?) async throws -> String { "image" }
    var classifierEnabled: Bool { false }
    func makeTree(_ selection: String, diffingEnabled: Bool) throws -> String { "tree" }
    func makeAttachment(_ selection: String, image: String?, classifierEnabled: Bool) throws -> String { "attachment" }
    func retainImage(_ image: String) {}
    func publishTree(_ tree: String) {}
    func publishWindow(_ selection: String) {}
    func notifyDidUpdate() {}
    func imageSize(_ image: String) -> CGSize { CGSize(width: 10, height: 10) }
}

@main
enum AcuaAppSnapshotRetryTests {
    nonisolated(unsafe) private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    @MainActor private static func capture(_ backend: FakeBackend) async -> Result<String, any Error> {
        do {
            let result = try await ControllerAppSnapshotOperation(backend: backend)
                .capture(cache: nil, disableAXDiffing: false, skipScreenshot: true)
            return .success(result.axTree)
        } catch { return .failure(error) }
    }

    private static func failure(_ result: Result<String, any Error>) -> FakeFailure? {
        guard case .failure(let error) = result else { return nil }
        return error as? FakeFailure
    }

    @MainActor static func main() async {
        let healthy = FakeBackend(failures: [])
        let first = await capture(healthy)
        check("Snapshot_WindowAvailable_CapturesWithoutWaiting",
              (try? first.get()) == "tree" && healthy.contextReads == 1 && healthy.waits == 0, "\(first)")

        // What a GPUI window did on first contact: unavailable once or twice,
        // then there on the next read.
        let animating = FakeBackend(failures: [.windowUnavailable, .windowUnavailable])
        let recovered = await capture(animating)
        check("Snapshot_WindowUnavailableTwice_WaitsAndCaptures",
              (try? recovered.get()) == "tree" && animating.contextReads == 3 && animating.waits == 2,
              "\(recovered) reads=\(animating.contextReads) waits=\(animating.waits)")

        let limit = ControllerAppSnapshotContextRetry.attempts
        let gone = FakeBackend(failures: Array(repeating: .windowUnavailable, count: limit + 3))
        let exhausted = await capture(gone)
        check("Snapshot_WindowNeverAvailable_ReturnsTheErrorAfterTheLastTry",
              failure(exhausted) == .windowUnavailable && gone.contextReads == limit && gone.waits == limit - 1,
              "\(exhausted) reads=\(gone.contextReads) waits=\(gone.waits)")

        let noWindow = FakeBackend(failures: [.noPrimaryWindow])
        let permanent = await capture(noWindow)
        check("Snapshot_OtherFailure_IsNotRetried",
              failure(permanent) == .noPrimaryWindow && noWindow.contextReads == 1 && noWindow.waits == 0,
              "\(permanent) reads=\(noWindow.contextReads)")

        let quitting = FakeBackend(failures: [.windowUnavailable, .windowUnavailable])
        quitting.terminatesWhileWaiting = true
        let terminated = await capture(quitting)
        check("Snapshot_AppQuitsWhileWaiting_ReportsTermination",
              failure(terminated) == .terminated && quitting.contextReads == 1, "\(terminated) reads=\(quitting.contextReads)")

        print("\(passed) app snapshot retry tests passed")
    }
}
