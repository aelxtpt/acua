import AppKit
import SwiftUI

@MainActor
final class AppshotPermissionArrow: NSPanel, NSWindowDelegate {
    private final class ArtworkState: ObservableObject {
        @Published var visible = false
        @Published var stretching = false
        @Published var hovering = false
        @Published var hoverPulse = UUID()
    }

    private struct Artwork: View {
        let image: NSImage
        @ObservedObject var state: ArtworkState

        var body: some View {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28 * image.size.height / image.size.width)
                .scaleEffect(x: state.stretching ? 1.15 : 1, y: state.stretching ? 1.6 : 1, anchor: .bottom)
                .shadow(color: .black.opacity(0.23), radius: 7, x: 0, y: 4)
                .offset(y: -10)
                .onHover { inside in
                    state.hovering = inside
                    if inside && state.visible {
                        stretch(true)
                        state.hoverPulse = UUID()
                    }
                }
                .frame(width: 100, height: 100, alignment: .bottom)
                .task(id: state.visible) {
                    guard state.visible else { state.stretching = false; state.hovering = false; return }
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                        while !Task.isCancelled {
                            if !state.hovering { stretch(true) }
                            try await Task.sleep(for: .milliseconds(250))
                            if !state.hovering { stretch(false) }
                            try await Task.sleep(for: .seconds(4))
                        }
                    } catch { }
                }
                .task(id: state.hoverPulse) {
                    guard state.hovering && state.visible else { return }
                    do { try await Task.sleep(for: .milliseconds(250)); stretch(false) }
                    catch { }
                }
                .accessibilityHidden(true)
        }

        private func stretch(_ value: Bool) {
            withAnimation(.interpolatingSpring(mass: 1, stiffness: 200, damping: 11, initialVelocity: 0)) {
                state.stretching = value
            }
        }
    }

    private static var image: NSImage? { SettingsAccessoryAssets.hintArrow }

    private let artwork = ArtworkState()

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make() -> AppshotPermissionArrow? { image.map { AppshotPermissionArrow(image: $0) } }

    private init(image: NSImage) {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: .borderless, backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .floating
        collectionBehavior = .managed
        delegate = self
        let controller = NSViewController()
        contentViewController = controller
        SettingsAccessoryWindowConfiguration.install(
            NSHostingView(rootView: Artwork(image: image, state: artwork)), in: controller)
    }

    func position(over panelFrame: CGRect) {
        setFrame(SettingsAccessoryLayout.arrowFrame(accessory: panelFrame), display: false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = occlusionState.contains(.visible)
        if artwork.visible != visible { artwork.visible = visible }
    }

    override func close() {
        artwork.visible = false
        delegate = nil
        super.close()
    }
}
