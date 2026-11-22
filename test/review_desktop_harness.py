"""Build the desktop test entry and controlled fault seams on the selected graph."""

from review_codec_harness import build_fixture, native_socket_route, replace_once


ENTRY = '''
// These arguments are recognized only in this temporary test executable.
if CommandLine.arguments == [CommandLine.arguments[0], "--owned-desktop-contracts"] {
    let resolver = SenderRequestContext.Resolver(ancestorPIDs: { _ in [] },
        identity: { _ in preconditionFailure("unexpected identity lookup") }, responsiblePID: { _ in nil })
    guard let base = resolver.resolve(getpid()) else { exit(2) }
    let types: [String?] = [nil, "node_repl", "other", "NODE_REPL", ""]
    let captures = types.map { type in
        ControllerActionCaptureSelection.returnsAppSnapshot(ownedDesktopSender(base, clientType: type))
    }
    guard captures == [true, false, true, true, true] else { exit(3) }
    print(jsonString(["capture": captures, "fixture_scope": "sender metadata only"]))
    exit(0)
}
if CommandLine.arguments == [CommandLine.arguments[0], "--owned-coordinate-settings"] {
    let settings = NativeAppSnapshotImage.Settings.current()
    let frame = CGRect(x: -200, y: 180, width: 1100.25, height: 820.75)
    let values: [JSON] = [1.0, 1.5, 2.0].map { scale in
        let plan = ControllerScreenshotSizing.read(frame: frame, scale: scale,
            legacy: settings.legacySizing, normalizeToPoints: settings.normalizeToPoints)
        return ["scale": scale, "width": plan.size.width, "height": plan.size.height, "pointScale": plan.pointScale]
    }
    print(jsonString(["legacy": settings.legacySizing, "normalizeToPoints": settings.normalizeToPoints, "geometry": values]))
    exit(0)
}
let ownedDesktopBundle = ProcessInfo.processInfo.environment["CUA_REVIEW_DESKTOP_BUNDLE"] ?? ""
// Tests give each run's fixture a unique ".run-..." suffix, so stale copies of
// earlier fixtures never make the bundle identifier ambiguous.
let ownedDesktopBundleBase = ownedDesktopBundle.components(separatedBy: ".run-").first ?? ""
// Requests name the fixture by its canonical path: Launch Services ignores apps
// in temporary folders, so a bundle identifier would not resolve.
let ownedDesktopApp = ProcessInfo.processInfo.environment["CUA_REVIEW_DESKTOP_APP"] ?? ""
let ownedDesktopMode = ProcessInfo.processInfo.environment["CUA_REVIEW_DESKTOP_MODE"] ?? "standard"
let ownedDesktopCoordinates = ["points", "legacy"].contains(ownedDesktopMode)
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--owned-desktop-socket",
      CommandLine.arguments[2].hasPrefix("/"),
      let configuredRun = ProcessInfo.processInfo.environment["CUA_REVIEW_RUN"],
      ["standard", "press", "url-policy", "points", "legacy"].contains(ownedDesktopMode),
      ownedDesktopCoordinates == (ownedDesktopBundleBase == "test.acua.coordinate-fixture"),
      ["test.acua.native-tree-integration-fixture", "test.acua.owned-hosted-panel",
       "test.acua.owned-deep-hierarchy", "test.acua.owned-web-form",
       "test.acua.coordinate-fixture"].contains(ownedDesktopBundleBase),
      ownedDesktopApp.hasPrefix("/"), Bundle(path: ownedDesktopApp)?.bundleIdentifier == ownedDesktopBundle,
      ProcessInfo.processInfo.environment[SenderAuthorization.developmentVariable] == "1"
else { exit(64) }
let ownedDesktopRun = URL(fileURLWithPath: configuredRun).resolvingSymlinksInPath()
let ownedDesktopSocket = CommandLine.arguments[2]
let ownedDesktopSocketDirectory = URL(fileURLWithPath: ownedDesktopSocket).deletingLastPathComponent().resolvingSymlinksInPath()
guard ownedDesktopRun.deletingLastPathComponent().path == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path,
      ownedDesktopRun.lastPathComponent.hasPrefix("cua-rv-"),
      ownedDesktopSocketDirectory.path.hasPrefix(ownedDesktopRun.path + "/t/"),
      URL(fileURLWithPath: ownedDesktopApp).resolvingSymlinksInPath().path.hasPrefix(ownedDesktopRun.path + "/t/")
else { exit(64) }
guard ScreenLockState.read().interactionAvailable else { exit(69) }
guard Permissions.accessibilityGranted(), Permissions.screenRecordingGranted() else { exit(77) }

func ownedDesktopSender(_ base: SenderRequestContext, clientType: String?) -> SenderRequestContext {
    var context = base
    context.clientMetadata.clientType = SenderClientMetadata.ClientType.parse(clientType)
    return context
}

func requireOwnedDesktopTarget(_ body: Any?, requestType: String) throws {
    guard let route = DirectRequestType(rawValue: requestType),
          [.appGetAppSnapshot, .appPerformAction, .appModify].contains(route),
          str(asDict(body)?["app"]) == ownedDesktopApp else {
        throw ServiceError(.appNotAllowed, "Desktop fixture request is outside its owned target")
    }
    guard ScreenLockState.read().interactionAvailable else {
        throw ServiceError(.screenLocked, "Screen is locked")
    }
    guard Permissions.accessibilityGranted(), Permissions.screenRecordingGranted() else {
        throw ServiceError(.permissionsNotGranted, "Desktop fixture permissions are unavailable")
    }
    // A fixture from the previous step can still be exiting while the next one
    // runs under the same bundle identifier; only live processes count.
    let targets = NSRunningApplication.runningApplications(withBundleIdentifier: ownedDesktopBundle).filter { !$0.isTerminated }
    guard !targets.isEmpty, targets.allSatisfy({
        $0.bundleURL?.resolvingSymlinksInPath().path.hasPrefix(ownedDesktopRun.path + "/t/") == true
    }) else { throw ServiceError(.appNotAllowed, "Desktop fixture application is outside the review run") }
}
'''

NATIVE_ROUTE = '''
            case "ownedFixtureNativeRequest":
                guard let fixturePeer, let senderContext else {
                    throw ServiceError(.senderProcessNotAuthenticated, "Missing admitted peer")
                }
                let params = asDict(message["params"]) ?? [:]
                let requestType = str(params["requestType"]) ?? ""
                let body = params["request"]
                try requireOwnedDesktopTarget(body, requestType: requestType)
                do {
                    let bytes = try handleXPC(peer: fixturePeer, type: requestType,
                        request: JSONSerialization.data(withJSONObject: body ?? NSNull()), metadata: nil, files: [],
                        senderContext: ownedDesktopSender(senderContext, clientType: str(params["clientType"])), cancelled: cancelled)
                    return ["id": id, "jsonrpc": "2.0", "result": try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])]
                } catch {
                    let native = ComputerUseXPC.requestError(error)
                    return ["id": id, "jsonrpc": "2.0", "error": ["code": native.code, "message": native.localizedDescription]]
                }
'''


def prepare_main(source):
    source = replace_once(source, "import OSLog\n", "import OSLog\n" + ENTRY)
    source = replace_once(source, "wireData: Data? = nil,\n                       serializationFailed:",
                          "wireData: Data? = nil, fixturePeer: PeerAuditCredentials? = nil,\n                       serializationFailed:")
    # handle() opens its do block right after reading the method, ahead of the
    # method switch; the fixture guard goes first in that block.
    method_read = 'guard let method = str(message["method"]) else { return errorResponse(id, .couldNotGetRequestTypeName, "Missing method") }\n        do {\n'
    source = replace_once(source, method_read, method_read + """            guard files.isEmpty, method == "ping" || (ownedDesktopCoordinates ? method == "request" : method == "ownedFixtureNativeRequest") else {
                throw ServiceError(.unhandledEvent, "Method is not available in the desktop fixture")
            }
""")
    route = '            case "request":\n                let params = asDict(message["params"]) ?? [:]'
    source = replace_once(source, route, NATIVE_ROUTE + route)
    socket_body = "                    return try ComputerUseTelemetryContext.withAgentTurnMetadata(metadata) {"
    source = replace_once(source, socket_body,
                          "                    try requireOwnedDesktopTarget(body, requestType: requestType)\n" + socket_body)
    source = replace_once(source, "    private let peerPID: Int32?\n",
                          "    private let peerPID: Int32?\n    private let fixturePeer: PeerAuditCredentials\n")
    source = replace_once(source, "        peerPID = credentials.pid\n", "        peerPID = credentials.pid\n        fixturePeer = credentials\n")
    source = replace_once(source, "files: files, wireData: data,\n                       serializationFailed:",
                          "files: files, wireData: data, fixturePeer: fixturePeer,\n                       serializationFailed:")
    source = replace_once(source, "prepareAuthenticatedRequest(selection.preparesTurn, selection.allowsAutoUnlock)",
                          "prepareAuthenticatedRequest(selection.preparesTurn, false)")
    return replace_once(source, "MainActor.assumeIsolated { run() }", '''MainActor.assumeIsolated {
    let server = Thread { serveForever(path: ownedDesktopSocket) }
    server.name = "cua.owned.desktop"
    server.start()
    NSApplication.shared.run()
}
exit(4)''')


def prepare_ax(source):
    anchor = "            let status = AXUIElementPerformAction(key.element, action as CFString)"
    return replace_once(source, anchor, '''            var status = AXUIElementPerformAction(key.element, action as CFString)
            if status == .success, action == kAXPressAction as String,
               ProcessInfo.processInfo.environment["CUA_REVIEW_DESKTOP_MODE"] == "press" {
                var help: CFTypeRef?
                if AXUIElementCopyAttributeValue(key.element, kAXHelpAttribute as CFString, &help) == .success {
                    let statuses: [String: AXError] = ["cannotComplete": .cannotComplete,
                        "attributeUnsupported": .attributeUnsupported, "failure": .failure, "actionUnsupported": .actionUnsupported]
                    if let fault = help as? String, let controlled = statuses[fault] { status = controlled }
                }
            }''')


def prepare_url_policy(source):
    return replace_once(source, "            blockedURL: { controller, capture in\n", '''            blockedURL: { controller, capture in
                if ProcessInfo.processInfo.environment["CUA_REVIEW_DESKTOP_MODE"] == "url-policy" {
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor in continuation.resume(returning: nil) }
                    }
                }
''')


def prepare_sizing(source):
    return replace_once(source, "        static func current() -> Self {\n", '''        static func current() -> Self {
            let mode = ProcessInfo.processInfo.environment["CUA_REVIEW_DESKTOP_MODE"]
            if mode == "points" || mode == "legacy" {
                return .init(legacySizing: true, normalizeToPoints: mode == "points", encoding: .jpeg(0.8))
            }
''')


def build(manifest_path, project, output):
    transforms = {"main.swift": prepare_main, "SocketJSONRPC.swift": native_socket_route,
                  "ControllerNativeElementIO.swift": prepare_ax,
                  "ControllerNativeAppSnapshotRequest.swift": prepare_url_policy, "NativeAppSnapshotImage.swift": prepare_sizing}
    build_fixture(manifest_path, project, output, transforms, "test.acua.review-desktop-fixture",
                  "owned desktop socket only")
