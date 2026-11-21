import AppKit
import SwiftUI

enum AppshotPermissionTransitionGeometry {
    typealias Appearance = SystemSettingsTransitionAppearance

    static func frame(from source: CGRect, to target: CGRect, progress: CGFloat) -> CGRect {
        SystemSettingsTransitionGeometry.frame(from:source,to:target,progress:progress).integral
    }
}

@MainActor
final class AppshotPermissionTransition {
    struct Snapshot {
        let frame: CGRect
        let image: NSImage?
        let cornerRadius: CGFloat

        var capture: SettingsAccessoryCapture<NSImage> {
            .init(frameOnScreen: frame, artwork: image, cornerRadius: cornerRadius)
        }

        @MainActor static func capture(_ view: NSView, cornerRadius: CGFloat = 24) -> Snapshot? {
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let frame = screenFrame(of: view), !bounds.isEmpty,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            view.cacheDisplay(in: bounds, to: bitmap)
            guard let image = bitmap.cgImage else { return nil }
            return Snapshot(frame: frame, image: NSImage(cgImage: image, size: bounds.size), cornerRadius: cornerRadius)
        }

        @MainActor static func screenFrame(of view: NSView) -> CGRect? {
            view.window?.convertToScreen(view.convert(view.bounds, to: nil)).integral
        }
    }

    private final class ArtworkState: ObservableObject {
        @Published var radius: CGFloat = 24
        @Published var progress: Double = 0
        @Published var sourceImage: NSImage?
        @Published var targetImage: NSImage?

        init(source: NSImage?, target: NSImage?) {
            sourceImage = source
            targetImage = target
        }
    }

    private struct Artwork: View {
        @ObservedObject var state: ArtworkState

        var body: some View {
            let radius = state.radius
            let appearance = SystemSettingsTransitionAppearance(progress: state.progress,
                                                                 hasSourceImage: state.sourceImage != nil,
                                                                 hasTargetImage: state.targetImage != nil)
            let clip = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                clip.fill(.regularMaterial)
                ZStack {
                    if let source = state.sourceImage {
                        image(source).opacity(appearance.sourceOpacity).blur(radius: appearance.sourceBlur)
                    }
                    if let target = state.targetImage {
                        image(target).opacity(appearance.targetOpacity).blur(radius: appearance.targetBlur)
                    }
                }
                .clipShape(clip)
            }
        }

        private func image(_ image: NSImage) -> some View {
            Image(nsImage: image)
                .interpolation(.high)
                .frame(width: image.size.width, height: image.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private final class Overlay: NSPanel {
        private let screenFrame: CGRect
        private let artworkState: ArtworkState
        private let replicaView: SystemSettingsTransitionReplicantView

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        init(screen: NSScreen, source: NSImage?, target: NSImage?) {
            screenFrame = screen.frame
            let state = ArtworkState(source: source, target: target)
            artworkState = state
            let artwork = NSHostingView(rootView: Artwork(state: state))
            replicaView = SystemSettingsTransitionReplicantView(frame: CGRect(origin: .zero, size: screen.frame.size), artwork: artwork)
            super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            level = .init(rawValue: 25)
            collectionBehavior = .init(rawValue: 4425)
            backgroundColor = .clear
            isOpaque = false
            hasShadow = false
            ignoresMouseEvents = true
            isReleasedWhenClosed = false
            animationBehavior = .none

            contentView = replicaView
        }

        func setReplicaFrame(_ frame: CGRect) {
            replicaView.setReplicaFrame(frame, on: screenFrame)
        }

        func setRadius(_ radius: CGFloat) {
            replicaView.setCornerRadius(radius)
            artworkState.radius = radius
        }

        func setProgress(_ progress: Double) {
            artworkState.progress = progress
            replicaView.setProgress(progress)
        }

        func setTargetImage(_ image: NSImage?) {
            artworkState.targetImage = image
        }
    }

    typealias Controller = SettingsTransitionController<NSImage>

    private final class NativeOverlayGroup: Controller.Overlay {
        let windows: [Overlay]

        init(source: NSImage?, target: NSImage?) {
            let windows = NSScreen.screens.map { Overlay(screen: $0, source: source, target: target) }
            self.windows = windows
            super.init(frame: { frame in windows.forEach { $0.setReplicaFrame(frame) } },
                       radius: { radius in windows.forEach { $0.setRadius(radius) } },
                       progress: { progress in windows.forEach { $0.setProgress(progress) } },
                       targetArtwork: { image in windows.forEach { $0.setTargetImage(image) } },
                       alpha: { alpha in windows.forEach { $0.alphaValue = alpha } },
                       show: { windows.forEach { $0.orderFrontRegardless() } },
                       close: { windows.forEach { $0.close() } })
        }

        func makeDriver() -> SystemSettingsDisplayLinkDriver {
            if let first = windows.first { return SystemSettingsDisplayLinkDriver(window: first) }
            // Fall back to the main screen, then trap if it is absent.
            guard let main = NSScreen.main else { preconditionFailure("No main screen for the settings transition") }
            return SystemSettingsDisplayLinkDriver(screen: main)
        }
    }

    static func makeController() -> Controller {
        Controller(environment: nativeEnvironment())
    }

    private static func nativeEnvironment() -> Controller.Environment {
        .init(makeOverlay: { NativeOverlayGroup(source: $0, target: $1) },
              makeAnimation: { configuration, overlay in
                  guard let group = overlay as? NativeOverlayGroup else { preconditionFailure("Unexpected native transition overlay") }
                  return SystemSettingsTransitionAnimationBinding<NSImage>.make(configuration: configuration, driver: group.makeDriver())
              })
    }

    private let source: Snapshot
    private var target: Snapshot
    private let onFinish: @MainActor () -> Void
    private let controller: Controller

    init?(source: Snapshot, target: Snapshot, onFinish: @escaping @MainActor () -> Void) {
        self.source = source
        self.target = target
        self.onFinish = onFinish
        controller = Self.makeController()
    }

    func start() {
        controller.start(from: source.capture, to: target.capture, completion: onFinish)
    }

    func retarget(_ snapshot: Snapshot) {
        target = snapshot
        controller.retarget(snapshot.capture)
    }

    func cancel() {
        controller.stop()
    }
}
