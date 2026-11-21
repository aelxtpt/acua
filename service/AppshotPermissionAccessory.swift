import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class AppshotPermissionAccessory: NSPanel, SettingsAccessoryDragDelegate {
    typealias Permission = AppshotPermissionSettingsVisits.Permission

    static let settingsBundleIdentifier = "com.apple.systempreferences"

    static var applicationBundleURL: URL? {
        guard let url = NSRunningApplication.current.bundleURL, url.pathExtension == "app" else { return nil }
        return url
    }

    let permission: Permission
    private let onBack: () -> Void
    private let onDrop: (CGPoint) -> Void
    private let applicationName: String
    private let applicationIcon: NSImage
    private let foregroundController = NSViewController()
    private var foregroundHost: NSView?
    private var arrow: AppshotPermissionArrow?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(permission: Permission, appURL: URL?,
         onBack: @escaping () -> Void, onDrop: @escaping (CGPoint) -> Void) {
        self.permission = permission
        self.onBack = onBack
        self.onDrop = onDrop
        applicationName = appURL.map { FileManager.default.displayName(atPath: $0.path) }
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
        applicationIcon = SettingsAccessoryAssets.applicationIcon(bundleURL: appURL)
        super.init(contentRect: .zero, styleMask: SettingsAccessoryWindowConfiguration.styleMask, backing: .buffered, defer: false)
        let source = SettingsAccessoryDraggableView(applicationName: applicationName, applicationBundleURL: appURL,
            icon: applicationIcon, destination: settingsDestination, hintArrow: SettingsAccessoryAssets.hintArrow)
        source.dragDelegate = self
        let foreground = SettingsAccessoryContent(onBack: { [weak self] in self?.onBack() }) {
            SettingsAccessoryDragHost(source: source)
        }.background(.regularMaterial, ignoresSafeAreaEdges: .all)
        let host = SettingsAccessoryHostingView(rootView: foreground)
        foregroundHost = host
        SettingsAccessoryWindowConfiguration.install(host, in: foregroundController)
        SettingsAccessoryWindowConfiguration.apply(to: self, controller: foregroundController)
        arrow = AppshotPermissionArrow.make()
        if let arrow {
            arrow.position(over: frame)
            addChildWindow(arrow, ordered: .above)
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        arrow?.position(over: frame)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(point)
        arrow?.position(over: frame)
    }

    override func close() {
        if let arrow, arrow.parent === self {
            removeChildWindow(arrow)
            arrow.close()
        }
        super.close()
    }

    func presentationWindow() -> SettingsAccessoryPresentation<NSImage>.Window {
        .init(fittingSize: { [self] in foregroundHost!.fittingSize },
              frameForContent: { [self] in frameRect(forContentRect: $0) },
              setFrame: { [self] in setFrame($0, display: false) },
              layout: { [self] in layoutIfNeeded() },
              capture: { [self] in transitionSnapshot()?.capture },
              setAlphas: { [self] value in
                  alphaValue=value;foregroundController.view.alphaValue=value;arrow?.alphaValue=value
              }, revealAfterForward: { [self] in
                  foregroundController.view.alphaValue=1;arrow?.alphaValue=1;alphaValue=1
              }, orderFront: { [self] in orderFrontRegardless() },
              close: { [self] in close() },
              completionTarget: { [weak self] in
                  guard let self else { return nil }
                  return {
                      self.foregroundController.view.alphaValue=1;self.arrow?.alphaValue=1
                      self.alphaValue=1;self.orderFrontRegardless()
                  }
              })
    }

    private var settingsDestination: SystemSettings.Destination {
        .init(paneID: SystemSettings.Destination.privacy.paneID, anchor: permission.rawValue)
    }

    func transitionSnapshot() -> AppshotPermissionTransition.Snapshot? {
        let content = SettingsAccessoryForeground(applicationName: applicationName, destination: settingsDestination,
            hintArrow: SettingsAccessoryAssets.hintArrow, showsHintArrow: true, onBack: { [weak self] in self?.onBack() },
            row: { [applicationName, applicationIcon] in SettingsAccessoryApplicationRow(applicationName: applicationName, icon: applicationIcon) })
        guard let capture = SettingsAccessoryForegroundCapture.capture(window: self, controllerView: foregroundController.view,
            hostingView: foregroundHost, content: content) else { return nil }
        return .init(frame: capture.frameOnScreen, image: capture.artwork, cornerRadius: capture.cornerRadius)
    }

    static func recordingWindowIsNamed(_ settings: NSRunningApplication) -> Bool {
        SystemSettingsWindowRecord.nativeWindows(ownerPID:settings.processIdentifier,onscreenOnly:true)
            .first(where: { $0.qualifiesAsMainSettingsWindow })?.name != nil
    }

    static func settingsDialogsAreGone(_ settings: NSRunningApplication) -> Bool {
        SystemSettingsWindowRecord.nativeWindows(ownerPID:settings.processIdentifier,onscreenOnly:true)
            .allSatisfy { $0.qualifiesAsMainSettingsWindow }
    }

    func settingsAccessoryDidDrop(at point: CGPoint) {
        onDrop(point)
    }
}
