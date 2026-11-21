import AppKit
import ApplicationServices
import Darwin

enum KeyboardFocusResolver {
    typealias Focus = SystemKeyboardFocusState.Focus
    private typealias ListPIDs = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias Name = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32) -> Int32
    private static let processImage = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY | RTLD_LOCAL)
    private static let list: ListPIDs? = processImage.flatMap { dlsym($0, "proc_listallpids") }.map { unsafeBitCast($0, to: ListPIDs.self) }
    private static let name: Name? = processImage.flatMap { dlsym($0, "proc_name") }.map { unsafeBitCast($0, to: Name.self) }
    private static let lock = NSLock()
    private static var cachedBridge: Int32?
    private static func processName(_ pid: Int32) -> String? {
        guard let name else { return nil }
        var bytes = [CChar](repeating: 0, count: 256)
        guard name(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }
    static func viewBridgePID() -> Int32? {
        lock.lock(); let cached = cachedBridge; lock.unlock()
        if let cached, processName(cached) == "ViewBridgeAuxiliary" { return cached }
        guard let list else { return nil }
        let capacity = max(64, min(65536, Int(list(nil, 0)) + 64))
        var pids = [Int32](repeating: 0, count: capacity)
        let count = min(capacity, max(0, Int(list(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))))
        let found = pids.prefix(count).first { $0 > 0 && processName($0) == "ViewBridgeAuxiliary" }
        lock.lock(); cachedBridge = found; lock.unlock()
        return found
    }
    static func current() -> Focus {
        let observation = KeyboardFocusSPI.observe()
        var pid = observation?.resolvedPID
        // 0x10075AB38: missing PSN for an auxiliary process not represented by
        // NSRunningApplication is a special successful auxiliary-focus result.
        if let observation, observation.queryStatus == 0, observation.processStatus == -600,
           !observation.flag, let bridge = viewBridgePID(), NSRunningApplication(processIdentifier: bridge) == nil {
            pid = bridge
        }
        guard let pid else { return .regularApp(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) }
        return resolve(pid)
    }
    static func hostName(_ localizedName: String) -> String? {
        guard localizedName.contains("("), localizedName.contains(")") else { return nil }
        guard let last = localizedName.lastIndex(where: { $0 != ")" }) else { return nil }
        let end = localizedName.index(after: last)
        guard let open = localizedName[..<last].lastIndex(of: "(") else { return nil }
        return String(localizedName[localizedName.index(after: open)..<end])
    }
    private static func regularPID(_ element: AXUIElement?) -> Int32? {
        guard let element else { return nil }
        var pid: Int32 = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited else { return nil }
        return pid
    }
    static func resolve(_ pid: Int32) -> Focus {
        let bridge = viewBridgePID()
        let app = NSRunningApplication(processIdentifier: pid)
        guard pid == bridge || app?.activationPolicy == .prohibited else { return .regularApp(pid) }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.1)
        let focused = AX.axElement(AX.copy(ax, kAXFocusedUIElementAttribute as String))
        var host = regularPID(focused)
        if host == nil, let focused {
            var elementPID: Int32 = 0
            if AXUIElementGetPid(focused, &elementPID) == .success {
                let other = AXUIElementCreateApplication(elementPID)
                AXUIElementSetMessagingTimeout(other, 0.1)
                host = regularPID(other)
                if host == nil {
                    let window = AX.axElement(AX.copy(other, kAXFocusedWindowAttribute as String)) ?? AX.axElement(AX.copy(other, kAXMainWindowAttribute as String))
                    host = regularPID(window)
                }
            }
        }
        if host == nil, pid != bridge, let localized = app?.localizedName, let expected = hostName(localized) {
            let matches = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && $0.localizedName == expected }
            if matches.count == 1 { host = matches[0].processIdentifier }
        }
        let owner = host ?? NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if pid != bridge { return .viewService(appPID: owner, servicePID: pid) }
        let service = focused.flatMap { try? AccessibilityWindowSPI.actualPID($0) }.flatMap { actual -> Int32? in
            guard NSRunningApplication(processIdentifier: actual)?.activationPolicy != .regular,
                  NSRunningApplication(processIdentifier: actual)?.activationPolicy != .accessory else { return nil }
            return actual
        }
        return .viewService(appPID: owner, servicePID: service)
    }

    static func focusedProcessKind(in pid: Int32) -> HostedFocusRepair.ProcessKind? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let focused = AX.axElement(AX.copy(application, kAXFocusedUIElementAttribute as String)) else { return nil }
        for element in AXParentChain(start: focused, parent: { AX.axElement(AX.copy($0, kAXParentAttribute as String)) }) {
            guard let owner = try? AccessibilityWindowSPI.actualPID(element),
                  let app = NSRunningApplication(processIdentifier: owner), app.isFinishedLaunching else { continue }
            return app.activationPolicy == .prohibited ? .service : .application
        }
        return nil
    }
}
