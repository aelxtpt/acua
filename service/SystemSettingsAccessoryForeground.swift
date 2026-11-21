import AppKit
import SwiftUI

/// Instruction text. Keep literal names, spacing, and attributed color runs.
enum SettingsAccessoryInstruction {
    static func permissionLabel(_ destination: SystemSettings.Destination?) -> AttributedString? {
        guard destination?.paneID == SystemSettings.Destination.privacy.paneID else { return nil }
        let label: String
        switch destination?.anchor {
        case "Privacy_ScreenCapture": label = "Screenshots"
        case "Privacy_Accessibility": label = "Accessibility"
        case "Privacy_AllFiles": label = "Full Disk Access"
        default: return nil
        }
        var result = AttributedString(label)
        result.foregroundColor = .primary
        return result
    }

    static func text(applicationName: String, destination: SystemSettings.Destination?) -> AttributedString {
        var prefix = AttributedString("Drag ")
        prefix.foregroundColor = .secondary
        var name = AttributedString(applicationName)
        name.foregroundColor = .primary
        prefix.append(name)
        let fullDisk = destination == .privacyFullDiskAccess
        var suffix = AttributedString(fullDisk ? " to the list to allow " : " to the list above to allow ")
        suffix.foregroundColor = .secondary
        prefix.append(suffix)
        if let permission = permissionLabel(destination) { prefix.append(permission) }
        return prefix
    }
}

@MainActor enum SettingsAccessoryAssets {
    /// The arrow that points the user at the app row to drag, drawn from an
    /// SF Symbol so the bundle ships no image file for it.
    static let hintArrow: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 26, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        guard let image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        image.size = NSSize(width: 29, height: 33)
        return image
    }()

    static func applicationIcon(bundleURL: URL?) -> NSImage {
        let image: NSImage
        if let bundleURL { image = NSWorkspace.shared.icon(forFile: bundleURL.path) }
        else { image = NSImage(named: NSImage.applicationIconName) ?? NSImage() }
        image.size = NSSize(width: 32, height: 32)
        return image
    }

    static let adaptivePrimary = NSColor(name: NSColor.Name("adaptivePrimary")) { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return match == .darkAqua || match == .vibrantDark ? .textColor : .labelColor
    }
}

/// Shared icon and name row. The native NSBox supplies its skin.
struct SettingsAccessoryApplicationLabel: View {
    let applicationName: String
    let icon: NSImage
    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: icon)
            Text(applicationName).foregroundStyle(.primary)
            Spacer()
        }
    }
}

/// The drag instruction. A hidden arrow keeps its layout space so the text does not shift.
struct SettingsAccessoryDragHint: View {
    let applicationName: String
    let destination: SystemSettings.Destination?
    let hintArrow: NSImage?
    let showsHintArrow: Bool
    var body: some View {
        HStack(spacing: 8) {
            (hintArrow.map { Image(nsImage: $0) } ?? Image(systemName: "arrow.up"))
                .resizable()
                .frame(width: 28)
                .shadow(color: .black.opacity(0.23), radius: 7, x: 0, y: 4)
                .opacity(showsHintArrow ? 1 : 0)
            Text(SettingsAccessoryInstruction.text(applicationName: applicationName, destination: destination))
                .font(.body)
                .offset(x: 0, y: 3)
        }
    }
}

/// Pure SwiftUI stand-in for the native box in foreground images.
struct SettingsAccessoryApplicationRow: View {
    let applicationName: String
    let icon: NSImage
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(colorScheme == .dark ? Color.black.opacity(0.06) : Color.white.opacity(0.65))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(colorScheme == .dark
                            ? Color(nsColor: SettingsAccessoryAssets.adaptivePrimary.withAlphaComponent(0.08))
                            : Color(nsColor: NSColor(red: 223.0 / 255, green: 221.0 / 255, blue: 227.0 / 255, alpha: 1)), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                SettingsAccessoryApplicationLabel(applicationName: applicationName, icon: icon)
                    .padding(.horizontal, 4).padding(.vertical, 5)
            }
    }
}

/// Identical outer layout around native and snapshot columns.
struct SettingsAccessoryContent<Column: View>: View {
    let onBack: () -> Void
    @ViewBuilder let column: () -> Column
    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(nsColor: .tertiarySystemFill)))
            }
            .buttonStyle(.plain).padding(.bottom, 27)
            column()
        }
        .padding(.leading, 18).frame(width: 531, height: 110)
    }
}

/// Foreground artwork deliberately excludes the window material.
struct SettingsAccessoryForeground<Row: View>: View {
    static var size: CGSize { CGSize(width: 531, height: 110) }
    let applicationName: String
    let destination: SystemSettings.Destination?
    let hintArrow: NSImage?
    let showsHintArrow: Bool
    let onBack: () -> Void
    @ViewBuilder let row: () -> Row
    var body: some View {
        SettingsAccessoryContent(onBack: onBack) {
            VStack(alignment: .leading, spacing: 7) {
                SettingsAccessoryDragHint(applicationName: applicationName, destination: destination,
                    hintArrow: hintArrow, showsHintArrow: showsHintArrow).padding(.leading, 4)
                row().frame(height: 42).padding(.trailing, 10)
            }
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

/// Renders the foreground itself; never a screen or window bitmap capture.
@MainActor enum SettingsAccessoryForegroundCapture {
    static func capture<Content: View>(window: NSWindow, controllerView: NSView?, hostingView: NSView?, content: Content) -> SettingsAccessoryCapture<NSImage>? {
        guard let hostingView, let contentView = window.contentView else { return nil }
        contentView.layoutSubtreeIfNeeded()
        controllerView?.layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        let boundsInWindow = contentView.convert(contentView.bounds, to: nil)
        let frame = window.convertToScreen(boundsInWindow).integral
        let dark = contentView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        let scheme: ColorScheme = dark == .darkAqua || dark == .vibrantDark ? .dark : .light
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
        renderer.proposedSize = ProposedViewSize(width: boundsInWindow.width, height: boundsInWindow.height)
        renderer.scale = window.backingScaleFactor
        return .init(frameOnScreen: frame, artwork: renderer.nsImage, cornerRadius: 14)
    }
}
