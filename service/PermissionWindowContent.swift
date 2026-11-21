import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Select the existing State property wrapper explicitly. Newer SDKs also
// export a State macro whose plugin is not shipped with Command Line Tools.
private typealias PermissionHoverState<Value> = SwiftUI.State<Value>

@MainActor private struct PermissionVibrantBlending: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    // Vibrant blending for the window's text. The inverse blending modifier
    // is a different view modifier and is not used by these texts.
    func body(content: Content) -> some View {
        content.blendMode(colorScheme == .dark ? .plusLighter : .plusDarker)
    }
}

@MainActor struct PermissionWindowContent: View {
    let state: PermissionWindowViewState
    let catalog: PermissionCatalog
    let registry: PermissionRowRegistry<PermissionRequirement, NSView, NSImage>
    let onRequestPermission: @MainActor (PermissionRequirement) -> Void
    let onOpenSettings: @MainActor (PermissionRequirement) -> Void
    var buttonTitleProvider: PermissionWindowViewState.ButtonTitleProvider = { _, _, _ in nil }
    var onSkip: (@MainActor () -> Void)?
    var onRefresh: @MainActor () -> Void = {}

    var body: some View {
        VStack {
            PermissionHeaderIcon(icon: catalog.headerIcon)
                .frame(width: 64, height: 64).padding(.bottom, 20)
            Text(catalog.title).font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary).offset(y: -11).modifier(PermissionVibrantBlending())
            Text(catalog.description).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .modifier(PermissionVibrantBlending()).lineSpacing(2)
                .frame(maxWidth: 518).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            VStack(spacing: 18) {
                ForEach(state.visibleRows(in: catalog), id: \.permission) { row in
                    let presentation = state.presentation(for: row, in: catalog, buttonTitleProvider: buttonTitleProvider)
                    PermissionWindowRow(row: row, presentation: presentation, registry: registry,
                        action: { onRequestPermission(row.permission) },
                        inProgressAction: { onOpenSettings(row.permission) })
                }
            }.padding(.top, 21).padding(.horizontal, 41)
        }
        .offset(y: -9).padding(.top, 28).padding(.bottom, 32)
        .background(.regularMaterial, ignoresSafeAreaEdges: .all)
        .frame(width: 600)
        .overlay(alignment: .bottomTrailing) {
            if let onSkip, state.showsSkip(in: catalog) {
                Button("Skip", action: onSkip).buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary).disabled(state.value.activeRequest != nil)
                    .frame(height: 41).padding(.trailing, 57)
            }
        }
        .task(priority: .userInitiated) {
            // No polling task effects for an empty supplemental
            //set. Otherwise refresh before checking cached values, every second.
            guard catalog.rows.contains(where: \.isSupplemental) else { return }
            while !Task.isCancelled {
                onRefresh()
                if !state.hasMissingSupplementalPermission(in: catalog) { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

@MainActor private struct PermissionHeaderIcon: View {
    let icon: PermissionCatalog.HeaderIcon
    var body: some View {
        switch icon {
        case let .symbol(name):
            Image(systemName: name).resizable().aspectRatio(contentMode: .fit).foregroundStyle(.tint)
        case let .application(identifier):
            Image(nsImage: NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                .resizable().aspectRatio(contentMode: .fit)
        case .currentApplication:
            Image(nsImage: NSApp.applicationIconImage).resizable().aspectRatio(contentMode: .fit)
        }
    }
}

@MainActor struct PermissionWindowRow: View {
    let row: PermissionCatalog.Row
    let presentation: PermissionRowPresentation
    let registry: PermissionRowRegistry<PermissionRequirement, NSView, NSImage>
    let action: @MainActor () -> Void
    let inProgressAction: @MainActor () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if presentation.isInProgress {
                PermissionInProgressRow(action: inProgressAction).transition(.opacity)
            }
            content(snapshot: false)
                .opacity(presentation.isInProgress ? 0 : 1)
                .allowsHitTesting(!presentation.isInProgress)
        }
        .frame(height: 80)
        .background {
            if !presentation.isInProgress {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(colorScheme == .dark ? Color(nsColor: .separatorColor).opacity(0.75) : .clear,
                                          lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.09), radius: 25, x: 0, y: 5)
                    .shadow(color: .black.opacity(0.2), radius: 3)
            }
        }
        .background {
            PermissionRowTransitionSourceProbe(requirement: row.permission, registry: registry,
                snapshotProvider: { size, scale, dark in snapshot(size: size, scale: scale, dark: dark) })
        }
    }

    /// ImageRenderer renders the HStack alone, with no row material,
    /// placeholder, probe or window capture. Size, scale, scheme and tint are explicit.
    func snapshot(size: CGSize, scale: CGFloat, dark: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: content(snapshot: true)
            .environment(\.colorScheme, dark ? .dark : .light).tint(Color(nsColor: .controlAccentColor)))
        renderer.proposedSize = .init(size)
        renderer.scale = scale
        return renderer.nsImage
    }

    private func content(snapshot: Bool) -> some View {
        HStack(spacing: 0) {
            ZStack { PermissionCatalogIcon(icon: row.icon).frame(width: row.iconFrameSize, height: row.iconFrameSize) }
                .frame(width: 64, height: 64).padding(.leading, 8).padding(.trailing, 12.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
                    .offset(y: -1).modifier(PermissionVibrantBlending())
                Text(row.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    .modifier(PermissionVibrantBlending())
            }.frame(maxWidth: .infinity, alignment: .leading)
            if presentation.isGranted {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Done ")
                    Image(systemName: "checkmark").imageScale(.small)
                }.font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).padding(.trailing, 6)
            } else if snapshot {
                permissionButton
            } else {
                permissionButton.background {
                    PermissionActionSourceProbe(requirement: row.permission, registry: registry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(.trailing, 20)
    }

    private var permissionButton: some View {
        Button(presentation.buttonTitle, action: action).buttonStyle(.automatic)
            .clipShape(Capsule(style: .continuous)).frame(minWidth: 62).offset(x: 4)
            .keyboardShortcut(presentation.isProminent && presentation.isInteractionEnabled ? .defaultAction : nil)
            .disabled(!presentation.isInteractionEnabled)
    }
}

@MainActor private struct PermissionInProgressRow: View {
    let action: @MainActor () -> Void
    @PermissionHoverState private var hovering = false
    var body: some View {
        Button(action: action) {
            Text("COMPLETE IN SYSTEM SETTINGS").font(.system(size: 12, weight: .medium))
                .kerning(0.7).foregroundStyle(.secondary)
        }.buttonStyle(PermissionInProgressButtonStyle(hovering: hovering))
            .frame(maxWidth: .infinity, maxHeight: .infinity).onHover { hovering = $0 }
    }
}

private struct PermissionInProgressButtonStyle: ButtonStyle {
    let hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.primary.opacity(hovering ? 0.018 : 0)) }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.primary.opacity(configuration.isPressed ? 0.22 : hovering ? 0.18 : 0.16),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.992 : 1).opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

@MainActor private struct PermissionCatalogIcon: View {
    let icon: PermissionCatalog.Row.Icon
    var body: some View {
        switch icon {
        case let .application(identifier, fallback):
            nativeImage(NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }, fallback: fallback)
        case let .bundle(path, fallback):
            nativeImage(Bundle(path: path).map { NSWorkspace.shared.icon(forFile: $0.bundlePath) }, fallback: fallback)
        case let .contentType(identifier, fallback):
            nativeImage(UTType(identifier).map { NSWorkspace.shared.icon(for: $0) }, fallback: fallback)
        case let .symbol(name): Image(systemName: name).font(.system(size: 32)).symbolRenderingMode(.multicolor)
        }
    }
    private func nativeImage(_ image: NSImage?, fallback: String) -> some View {
        Group {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
            else { Image(systemName: fallback).font(.system(size: 32)).symbolRenderingMode(.multicolor) }
        }
    }
}
