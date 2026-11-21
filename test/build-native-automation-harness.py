from pathlib import Path
import subprocess,shlex,json,argparse,tempfile,os
parser=argparse.ArgumentParser()
parser.add_argument('--output',required=True)
parser.add_argument('--swiftflags',default='-O')
parser.add_argument('--url-policy-probe',action='store_true')
parser.add_argument('--ax-press-error-probe',action='store_true')
parser.add_argument('--codec-boundary-probe',action='store_true')
parser.add_argument('--native-settings-probe',action='store_true')
parser.add_argument('--review-desktop',action='store_true')
options=parser.parse_args()
root=Path(__file__).resolve().parent.parent
s=root/'service'
output=Path(options.output).resolve();output.parent.mkdir(parents=True,exist_ok=True)
if options.review_desktop:
    from review_desktop_harness import build
    build(os.environ["CUA_REVIEW_BUILD_MANIFEST"], root, output)
    raise SystemExit(0)
if options.codec_boundary_probe and (review_manifest := os.environ.get("CUA_REVIEW_BUILD_MANIFEST")):
    from review_codec_harness import build
    build(review_manifest, root, output)
    raise SystemExit(0)
h=Path(tempfile.mkdtemp(prefix='cua-native-automation-build-'))
t=(s/'main.swift').read_text()
anchor='''            case "request":
                let params = asDict(message["params"]) ?? [:]'''
route='''            case "ownedFixtureNativeRequest":
                let params = asDict(message["params"]) ?? [:]
                let type = str(params["requestType"]) ?? ""
                let body = try JSONSerialization.data(withJSONObject: params["request"] ?? NSNull())
                let peer = PeerAuditCredentials(pid: peerPID ?? getpid(), uid: geteuid(), auditToken: Data())
                let result = try handleXPC(peer: peer, type: type, request: body, metadata: nil, files: [],
                                           returnActionAppSnapshot: str(params["clientType"]) != "node_repl", cancelled: cancelled)
                return ["id": id, "jsonrpc": "2.0", "result": try JSONSerialization.jsonObject(with: result)]
'''
assert t.count(anchor)==1
if options.codec_boundary_probe:
    response='try SocketResponseBody.normalize(result, for: requestType)'
    assert t.count(response)==1
    t=t.replace(response, '(str(params["ownedRawResponse"]) != nil ? try SocketResponseBody.normalizeData(Data(str(params["ownedRawResponse"])!.utf8), for: requestType) : (asDict(result)?["codecValidated"] as? Bool == true ? result : '+response+'))')
    # Throw known service errors through the real shared socket catch.
    failure_anchor = '                let params = asDict(message["params"]) ?? [:]\n'
    assert route.count(failure_anchor) == 1
    route = route.replace(failure_anchor, failure_anchor + '                if let failure = params["ownedFailureCase"] as? Int {\n                    let failures: [Error] = [AudioRecorder.Failure.invalidDuration,\n                        AudioRecorder.Failure.noActiveRecording, AudioRecorder.Failure.noDisplay,\n                        AudioRecorder.Failure.recordingAlreadyActive, AudioRecorder.Failure.recordingNotOwned,\n                        NSError(domain: "OwnedErrorDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "owned explicit message"]),\n                        CocoaError(.fileReadNoSuchFile), CancellationError(),\n                        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "owned corrupt body")),\n                        MouseTargeting.Failure.noWindowsAvailable,\n                        MouseTargeting.Failure.windowNotFoundAtPosition(CGPoint(x: 860, y: 130)),\n                        MouseTargeting.Failure.windowNotFoundAtPosition(CGPoint(x: -10.25, y: 0.5)),\n                        MouseTargeting.Failure.windowNotFoundAtPosition(CGPoint(x: CGFloat.infinity, y: CGFloat.infinity))]\n                    guard failures.indices.contains(failure) else { throw ServiceError(.unknownError, "Invalid owned failure index") }\n                    throw failures[failure]\n                }\n')
    failure_throw = '                    throw failures[failure]'
    assert route.count(failure_throw) == 1
    route = route.replace(failure_throw, '''                    if params["ownedNativeErrorEnvelope"] as? Bool == true {
                        let native = ComputerUseXPC.requestError(failures[failure])
                        return ["id": id, "jsonrpc": "2.0", "error": ["code": native.code, "message": native.localizedDescription]]
                    }
''' + failure_throw)
    body='                let body = try JSONSerialization.data(withJSONObject: params["request"] ?? NSNull())'
    assert route.count(body)==1
    route=route.replace(body,'''                let body: Data
                if let raw = str(params["nativeRequestData"]), let decoded = Data(base64Encoded: raw) { body = decoded }
                else { body = try JSONSerialization.data(withJSONObject: params["request"] ?? NSNull()) }''')
    call='''                let result = try handleXPC(peer: peer, type: type, request: body, metadata: nil, files: [],
                                           returnActionAppSnapshot: str(params["clientType"]) != "node_repl", cancelled: cancelled)'''
    assert route.count(call)==1
    route=route.replace(call,'''                let result: Data
                do {
                    result = try handleXPC(peer: peer, type: type, request: body, metadata: nil, files: [],
                                           returnActionAppSnapshot: false, cancelled: cancelled)
                } catch {
                    let native = ComputerUseXPC.requestError(error)
                    return ["id": id, "jsonrpc": "2.0", "error": ["code": native.code, "message": native.localizedDescription]]
                }''')
    boundary='        let request = asDict(body) ?? [:]'
    assert t.count(boundary)==1
    # Exercise the real typed request boundary and deadline handling, then stop
    # before any delegated owner, permission prompt or action can execute.
    t=t.replace(boundary,'        return ["codecValidated": true]\n'+boundary)
(h/'main.swift').write_text(t.replace(anchor,route+anchor))
# `make -n` still expands TOML_FLAGS, which builds the cached TOML module the
# printed recipe links.
recipes=subprocess.check_output(['make','-n','component-fixture-build','SWIFTFLAGS='+options.swiftflags],cwd=s,text=True).splitlines()
commands=[shlex.split(line) for line in recipes if line.startswith('swiftc ')]
assert len(commands)==1
args=commands[0]
assert args.count('main.swift')==1 and args.count('-o')==1
args[args.index('main.swift')]=str(h/'main.swift')
args[args.index('-o')+1]=str(output)
# Keep the fixture-only route in temporary sources. The production socket
# parser now rejects unknown methods before reaching the dynamic dispatcher.
rpc=(s/'SocketJSONRPC.swift').read_text()
rpc_anchor='case "request": kind = .request'
assert rpc.count(rpc_anchor)==1 and args.count('SocketJSONRPC.swift')==1
(h/'SocketJSONRPC.swift').write_text(rpc.replace(rpc_anchor,
    'case "request", "ownedFixtureNativeRequest": kind = .request'))
args[args.index('SocketJSONRPC.swift')]=str(h/'SocketJSONRPC.swift')
if options.url_policy_probe:
    args[args.index('ActionAppSnapshotURLPolicy.swift')]=str(root/'test/URLPolicyThreadProbe.swift')
if options.native_settings_probe:
    image=(s/'NativeAppSnapshotImage.swift').read_text()
    anchor='        static func current() -> Self {'
    assert image.count(anchor)==1
    image=image.replace(anchor, anchor+'''
            if let mode = ProcessInfo.processInfo.environment["CUA_OWNED_IMAGE_SIZING"] {
                return Self(legacySizing: mode != "native", normalizeToPoints: mode != "legacy",
                            encoding: .jpeg(0.8))
            }
''')
    (h/'NativeAppSnapshotImage.swift').write_text(image)
    args[args.index('NativeAppSnapshotImage.swift')]=str(h/'NativeAppSnapshotImage.swift')
if options.ax_press_error_probe:
    # Preserve the real AX action and its owned fixture side effects, then
    # control the reported API error. AppKit can report AX success even when
    # accessibilityPerformPress() returns false, so that alone is no fault seam.
    actions=(s/'Actions.swift').read_text()
    calls=[('err','target.element','accessibilityAction'),('err','el','action'),('error','el','action')]
    for variable,element,action in calls:
        call=f'let {variable} = AXUIElementPerformAction({element}, {action} as CFString)'
        assert actions.count(call)==1
        replacement=f'''let observedAXStatus = AXUIElementPerformAction({element}, {action} as CFString)
                let probeStatus = AX.string({element}, kAXHelpAttribute as String) ?? ""
                let controlledStatuses: [String: AXError] = ["cannotComplete": .cannotComplete,
                    "attributeUnsupported": .attributeUnsupported, "failure": .failure, "actionUnsupported": .actionUnsupported]
                let {variable}: AXError = observedAXStatus == .success ? (controlledStatuses[probeStatus] ?? .failure) : observedAXStatus'''
        actions=actions.replace(call,replacement)
    (h/'Actions.swift').write_text(actions)
    args[args.index('Actions.swift')]=str(h/'Actions.swift')
(h/'build-command.json').write_text(json.dumps({'argv':args,'cwd':str(s),'test_only_route':True,
    'codec_boundary_probe':options.codec_boundary_probe},indent=2)+'\n')
subprocess.run(args,cwd=s,check=True)
subprocess.run(['codesign','--force','--sign','-','--identifier','test.acua.native-tree-harness',str(output)],check=True)
print('NATIVE INTEGRATION HARNESS BUILT')
