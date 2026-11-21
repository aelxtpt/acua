import CoreGraphics
import Foundation

struct RemoteHostedPIPWindowObservation: Sendable {
    struct Window: Sendable {
        let id: CGWindowID
        let role: String
        let subrole: String?
        let isModal: Bool
        let parent: CGWindowID?
        let isOnScreen: Bool
    }

    let pid: Int32
    let selected: Window
    let mainWindowID: CGWindowID?
    let windows: [CGWindowID: Window]
}

@MainActor
final class RemoteHostedPIPController {
    struct Turn: Equatable, Sendable {
        let threadID: String
        let turnID: String
    }

    private let publisher: RemoteHostedPIPContentPublisher
    private var activeTurn: Turn?
    private var streams: [CGWindowID: RemoteHostedPIPContentStream] = [:]
    private var streamOwners: [CGWindowID: Int32] = [:]
    private var recentWindow: [Int32: CGWindowID] = [:]
    private var lastObservation: [Int32: RemoteHostedPIPWindowObservation] = [:]
    private var cursorWindowID: CGWindowID?
    private var cursorTargetID: CGWindowID?

    init(publisher: RemoteHostedPIPContentPublisher) { self.publisher = publisher }

    func begin(_ turn: Turn) {
        guard turn != activeTurn else { return }
        end()
        activeTurn = turn
        for observation in lastObservation.values { publish(observation, for: turn) }
    }

    func end(threadID: String? = nil) {
        if let threadID, activeTurn?.threadID != threadID { return }
        activeTurn = nil
        for stream in streams.values { stream.willEndStream() }
        streams.removeAll()
        streamOwners.removeAll()
        recentWindow.removeAll()
        publisher.setComputerUseCursorLocation(.zero, isActive: false)
    }

    func observe(_ observation: RemoteHostedPIPWindowObservation, turn: Turn?) {
        guard turn == nil || turn == activeTurn else { return }
        lastObservation[observation.pid] = observation
        if let activeTurn { publish(observation, for: activeTurn) }
    }

    func updateCursor(at point: CGPoint?, overlayID: CGWindowID?, targetID: CGWindowID?) {
        publisher.setComputerUseCursorLocation(point ?? .zero, isActive: point != nil, coalescing: point != nil)
        guard cursorWindowID != overlayID || cursorTargetID != targetID else { return }
        if let cursorTargetID { streams[cursorTargetID]?.setCursorWindowID(nil) }
        cursorWindowID = overlayID
        cursorTargetID = targetID
        if let targetID { streams[targetID]?.setCursorWindowID(overlayID) }
    }

    func removeApp(pid: Int32) {
        lastObservation.removeValue(forKey: pid)
        for (id, owner) in streamOwners where owner == pid { endStream(id) }
        recentWindow.removeValue(forKey: pid)
    }

    private func endStream(_ id: CGWindowID) {
        streamOwners.removeValue(forKey: id)
        streams.removeValue(forKey: id)?.willEndStream()
    }

    private func publish(_ observation: RemoteHostedPIPWindowObservation, for turn: Turn) {
        let selected = observation.selected
        let main = observation.mainWindowID
        let recent = recentWindow[observation.pid].flatMap { observation.windows[$0]?.id }
        let existing = [recent, main].compactMap { $0 }.first { streams[$0] != nil }
        func owner(_ window: RemoteHostedPIPWindowObservation.Window, recent: CGWindowID?) -> CGWindowID? {
            RemoteHostedPIPWindowOwnership.ownerWindowID(for: window.id, role: window.role, subrole: window.subrole,
                isModal: window.isModal, parentWindowID: window.parent, mostRecentWindowID: recent,
                mainWindowID: main, existingParentWindowID: existing)
        }
        let primary = owner(selected, recent: recent) ?? selected.id
        if primary == selected.id, selected.role == "AXWindow",
           selected.subrole != "AXFloatingWindow", selected.subrole != "AXDialog" {
            recentWindow[observation.pid] = primary
        }
        let associated = Set(observation.windows.values.compactMap { window in
            window.id != primary && window.isOnScreen && owner(window, recent: primary) == primary ? window.id : nil
        })
        for id in associated.sorted() { endStream(id) }
        let stream: RemoteHostedPIPContentStream
        if let current = streams[primary] {
            stream = current
            stream.setAssociatedWindowIDs(associated)
        } else {
            stream = publisher.publishWindowStream(threadID: turn.threadID, turnID: turn.turnID, windowID: primary,
                                                   associatedWindowIDs: associated)
            streams[primary] = stream
            streamOwners[primary] = observation.pid
            if primary == cursorTargetID { stream.setCursorWindowID(cursorWindowID) }
        }
        stream.noteInteraction()
    }
}
