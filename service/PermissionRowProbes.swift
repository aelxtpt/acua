import AppKit
import SwiftUI

/// Probe views never participate in hit testing. Registration
/// occurs after super's layout/window callback, without observing desktop input.
@MainActor class PermissionProbeView: NSView {
    var onUpdate: (@MainActor (PermissionProbeView) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let update = onUpdate
        update?(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let update = onUpdate
        update?(self)
    }
}
@MainActor final class PermissionActionProbeView: PermissionProbeView {}
@MainActor final class PermissionTransitionProbeView: PermissionProbeView {}

typealias PermissionProbeSchedule = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void

/// make installs a callback only; update also queues a separate
/// registration capturing THAT update's values, not the later current callback.
@MainActor struct PermissionActionSourceProbe<Requirement: Hashable & Sendable, Artwork: Sendable>: NSViewRepresentable {
    let requirement: Requirement
    let registry: PermissionRowRegistry<Requirement, NSView, Artwork>
    func makeProbeView() -> PermissionActionProbeView {
        let view = PermissionActionProbeView(frame: .zero)
        view.onUpdate = { registry.registerAction($0, for: requirement) }
        return view
    }
    func updateProbe(_ view: PermissionActionProbeView,
                     schedule: PermissionProbeSchedule = { DispatchQueue.main.async(execute: $0) }) {
        view.onUpdate = { registry.registerAction($0, for: requirement) }
        schedule { registry.registerAction(view, for: requirement) }
    }
    func makeNSView(context: Context) -> PermissionActionProbeView { makeProbeView() }
    func updateNSView(_ view: PermissionActionProbeView, context: Context) { updateProbe(view) }
}

/// Dismantle uses the default NSViewRepresentable behavior:
/// there is no invented unregister pass or generation guard on queued updates.
@MainActor struct PermissionRowTransitionSourceProbe<Requirement: Hashable & Sendable, Artwork: Sendable>: NSViewRepresentable {
    let requirement: Requirement
    let registry: PermissionRowRegistry<Requirement, NSView, Artwork>
    let snapshotProvider: PermissionRowRegistry<Requirement, NSView, Artwork>.SnapshotProvider?
    func makeProbeView() -> PermissionTransitionProbeView {
        let view = PermissionTransitionProbeView(frame: .zero)
        view.onUpdate = { registry.registerSource($0, snapshotProvider: snapshotProvider, for: requirement) }
        return view
    }
    func updateProbe(_ view: PermissionTransitionProbeView,
                     schedule: PermissionProbeSchedule = { DispatchQueue.main.async(execute: $0) }) {
        view.onUpdate = { registry.registerSource($0, snapshotProvider: snapshotProvider, for: requirement) }
        schedule { registry.registerSource(view, snapshotProvider: snapshotProvider, for: requirement) }
    }
    func makeNSView(context: Context) -> PermissionTransitionProbeView { makeProbeView() }
    func updateNSView(_ view: PermissionTransitionProbeView, context: Context) { updateProbe(view) }
}
