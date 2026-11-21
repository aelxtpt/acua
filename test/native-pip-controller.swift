import Foundation

@main @MainActor
private enum NativePIPControllerTests {
    static func main() {
        let publisher = RemoteHostedPIPContentPublisher()
        let controller = RemoteHostedPIPController(publisher: publisher)
        let first = RemoteHostedPIPController.Turn(threadID: "thread-a", turnID: "turn-a")
        let second = RemoteHostedPIPController.Turn(threadID: "thread-a", turnID: "turn-b")
        let other = RemoteHostedPIPController.Turn(threadID: "thread-b", turnID: "turn-c")
        let parent = window(100)
        let dialog = window(101, subrole: "AXDialog", modal: true)
        let standalone = window(102)
        let sheet = window(103, role: "AXSheet", parent: parent.id)

        func current() -> [RemoteHostedPIPContentStream] {
            publisher.streamsByPresentationID.values.compactMap { $0 as? RemoteHostedPIPContentStream }
        }

        controller.observe(observation(parent, main: parent.id), turn: nil)
        check(current().isEmpty, "capture without an active turn does not publish")
        controller.begin(first)
        guard let stream = current().first else { fail("first turn creates presentation") }
        check(current().count == 1 && stream.threadID == first.threadID && stream.turnID == first.turnID,
              "first turn seeds its presentation from the previous capture")
        controller.begin(first)
        check(current().first === stream, "repeated requests in the same turn reuse the presentation")
        controller.observe(observation(dialog, main: parent.id, others: [parent, sheet]), turn: first)
        check(current().count == 1 && current().first === stream,
              "modal window updates the parent presentation")
        controller.observe(observation(standalone, main: parent.id, others: [parent]), turn: first)
        check(current().count == 2, "independent window receives a separate presentation")

        let previous = current()
        controller.begin(second)
        check(previous.allSatisfy(\.isInvalidated), "a different turn ends all previous presentations")
        check(current().count == 1 && current().first?.turnID == second.turnID,
              "new presentation uses the latest capture and new turn ID")
        let count = current().count
        controller.observe(observation(parent, main: parent.id), turn: first)
        check(current().count == count, "late capture from an old turn cannot publish in the new turn")
        controller.end(threadID: other.threadID)
        check(current().count == count, "a different thread cannot end the active thread")
        controller.end(threadID: second.threadID)
        check(current().isEmpty, "the active thread end removes its presentations")
        controller.observe(observation(sheet, main: parent.id, others: [parent]), turn: nil)
        controller.begin(other)
        check(current().count == 1 && current().first?.threadID == other.threadID,
              "a new thread can seed a parent from an explicit sheet relationship")
        controller.removeApp(pid: 42)
        check(current().isEmpty, "application termination ends its presentations")
        controller.begin(first)
        check(current().isEmpty, "terminated applications are not replayed")
    }

    private static func window(_ id: UInt32, role: String = "AXWindow", subrole: String? = "AXStandardWindow",
                               modal: Bool = false, parent: UInt32? = nil) -> RemoteHostedPIPWindowObservation.Window {
        .init(id: id, role: role, subrole: subrole, isModal: modal, parent: parent, isOnScreen: true)
    }

    private static func observation(_ selected: RemoteHostedPIPWindowObservation.Window, main: UInt32?,
                                    others: [RemoteHostedPIPWindowObservation.Window] = []) -> RemoteHostedPIPWindowObservation {
        .init(pid: 42, selected: selected, mainWindowID: main,
              windows: Dictionary(uniqueKeysWithValues: ([selected] + others).map { ($0.id, $0) }))
    }

    private static func check(_ result: Bool, _ title: String) {
        guard result else { fail(title) }
        print("PASS \(title)")
    }

    private static func fail(_ title: String) -> Never {
        fputs("FAIL \(title)\n", stderr)
        exit(1)
    }
}
