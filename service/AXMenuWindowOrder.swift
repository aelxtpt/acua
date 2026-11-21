import AppKit
import ApplicationServices

enum AXMenuWindowOrder {
    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
    }

    static func menuWindow(ownedBy pid: pid_t, below windows: [Window]) -> CGWindowID? {
        windows.first { $0.pid == pid && ($0.layer == 101 || $0.layer == 24) }?.id
    }

    static func needsRaise(_ foreground: CGWindowID, observed: Set<CGWindowID>, order: [CGWindowID]) -> Bool {
        guard let index = order.firstIndex(of: foreground) else { return false }
        return order[..<index].contains(where: observed.contains)
    }

    static func windowID(_ menu: AXUIElement, knownPID: pid_t?) -> CGWindowID? {
        guard let pid = knownPID ?? (try? AccessibilityWindowSPI.actualPID(menu)),
              let anchor = try? AccessibilityWindowSPI.windowID(menu) else { return nil }
        return menuWindow(ownedBy: pid, below: windows([.optionOnScreenBelowWindow, .excludeDesktopElements], relativeTo: anchor))
    }

    static func restore(foreground: NSRunningApplication?, targetPID: pid_t, session: AppSessions.Token,
                        menu: AXUIElement, menuPID: pid_t?, trackMenu: (CGWindowID?) -> Set<CGWindowID>) async {
        guard !Task.isCancelled, let running = NSRunningApplication(processIdentifier: targetPID),
              !running.isTerminated, AppResolver.processKey(running) == session.process else { return }
        let menuID = await findMenuWindow(menu, knownPID: menuPID)
        guard !Task.isCancelled, (try? AppSessions.shared.check(session)) != nil else { return }
        let observed = trackMenu(menuID)
        guard let foreground, !observed.isEmpty, !Task.isCancelled else { return }
        let owners = windows(.excludeDesktopElements).filter { observed.contains($0.id) }.map(\.pid)
        let foregroundPID = foreground.processIdentifier
        let foregroundKey = AppResolver.processKey(foreground)
        guard !owners.isEmpty, !owners.contains(foregroundPID) else { return }
        let application = AXUIElementCreateApplication(foregroundPID)
        AXUIElementSetMessagingTimeout(application, 1)
        guard let window = AX.axElement(AX.copy(application, kAXFocusedWindowAttribute as String)),
              let foregroundWindow = try? AccessibilityWindowSPI.windowID(window) else { return }

        for _ in 0..<20 {
            do {
                try await Task.sleep(for: .milliseconds(5))
                try AppSessions.shared.check(session)
            } catch { return }
            let order = windows([.optionOnScreenOnly, .excludeDesktopElements]).map(\.id)
            if needsRaise(foregroundWindow, observed: observed, order: order) {
                guard let focused = AX.axElement(AX.copy(application, kAXFocusedWindowAttribute as String)),
                      CFEqual(focused, window), !running.isTerminated, !foreground.isTerminated,
                      !Permissions.screenLocked(), let current = NSWorkspace.shared.frontmostApplication,
                      AppResolver.processKey(current) == foregroundKey, !Task.isCancelled,
                      (try? AppSessions.shared.check(session)) != nil else { return }
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }
    }

    private static func findMenuWindow(_ menu: AXUIElement, knownPID: pid_t?) async -> CGWindowID? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        while !Task.isCancelled {
            if let id = windowID(menu, knownPID: knownPID) {
                return id
            }
            guard ContinuousClock.now < deadline else { break }
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return nil }
        }
        return nil
    }

    private static func windows(_ options: CGWindowListOption, relativeTo id: CGWindowID = kCGNullWindowID) -> [Window] {
        let list = CGWindowListCopyWindowInfo(options, id) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue else { return nil }
            return Window(id: id, pid: pid, layer: layer)
        }
    }
}
