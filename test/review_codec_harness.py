"""Build the wire corpus fixture from the selected review's exact service graph."""

import hashlib
import json
import os
from pathlib import Path
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Review source no longer has a unique fixture insertion point: {old[:100]}")
    return source.replace(old, new, 1)


ENTRY = '''
// Fixture entry only. Never fall through to the ordinary service startup.
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--owned-codec-socket",
      let configuredRun = ProcessInfo.processInfo.environment["CUA_REVIEW_RUN"] else { exit(64) }
let ownedCodecDirectory = URL(fileURLWithPath: configuredRun).resolvingSymlinksInPath()
let ownedCodecSocket = URL(fileURLWithPath: CommandLine.arguments[2])
    .deletingLastPathComponent().resolvingSymlinksInPath()
let codecTemporaryRoot = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
guard ownedCodecDirectory.deletingLastPathComponent().path == codecTemporaryRoot.path,
      ownedCodecDirectory.lastPathComponent.hasPrefix("cua-rv-"),
      ownedCodecSocket.path.hasPrefix(ownedCodecDirectory.path + "/t/"),
      ProcessInfo.processInfo.environment[SenderAuthorization.developmentVariable] == "1"
else { exit(64) }
serveForever(path: CommandLine.arguments[2])
exit(4)
'''

NATIVE_ROUTE = '''
            case "ownedFixtureNativeRequest":
                guard let fixturePeer else {
                    throw ServiceError(.senderProcessNotAuthenticated, "Missing admitted peer")
                }
                let params = asDict(message["params"]) ?? [:]
                if let index = params["ownedFailureCase"] as? Int {
                    let failures: [Error] = [
                        AudioRecorder.Failure.invalidDuration, AudioRecorder.Failure.noActiveRecording,
                        AudioRecorder.Failure.noDisplay, AudioRecorder.Failure.recordingAlreadyActive,
                        AudioRecorder.Failure.recordingNotOwned,
                        NSError(domain: "OwnedErrorDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "owned explicit message"]),
                        CocoaError(.fileReadNoSuchFile), CancellationError(),
                        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "owned corrupt body")),
                        MouseTargeting.Failure.noWindowsAvailable,
                        MouseTargeting.Failure.windowNotFoundAtPosition(CGPoint(x: 860, y: 130)),
                        MouseTargeting.Failure.windowNotFoundAtPosition(CGPoint(x: -10.25, y: 0.5)),
                        MouseTargeting.Failure.windowNotFoundAtPosition(CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)),
                    ]
                    guard failures.indices.contains(index) else {
                        throw ServiceError(.unknownError, "Invalid owned failure index")
                    }
                    if params["ownedNativeErrorEnvelope"] as? Bool == true {
                        let native = ComputerUseXPC.requestError(failures[index])
                        return errorResponse(id, CUErrorCode(rawValue: native.code) ?? .unknownError, native.localizedDescription)
                    }
                    throw failures[index]
                }
                let body: Data
                if let raw = str(params["nativeRequestData"]), let bytes = Data(base64Encoded: raw) { body = bytes }
                else { body = try JSONSerialization.data(withJSONObject: params["request"] ?? NSNull(), options: [.fragmentsAllowed]) }
                do {
                    let bytes = try handleXPC(peer: fixturePeer, type: str(params["requestType"]) ?? "",
                        request: body, metadata: nil, files: [], returnActionAppSnapshot: false,
                        senderContext: senderContext, cancelled: cancelled)
                    return ["id": id, "jsonrpc": "2.0", "result": try JSONSerialization.jsonObject(with: bytes)]
                } catch {
                    let native = ComputerUseXPC.requestError(error)
                    return ["id": id, "jsonrpc": "2.0", "error": ["code": native.code, "message": native.localizedDescription]]
                }
'''


def prepare_main(source):
    source = replace_once(source, "import OSLog\n", "import OSLog\n" + ENTRY)
    source = replace_once(source, "wireData: Data? = nil,\n                       serializationFailed:",
                          "wireData: Data? = nil, fixturePeer: PeerAuditCredentials? = nil,\n                       serializationFailed:")
    source = replace_once(source, '            case "request":\n                let params = asDict(message["params"]) ?? [:]',
                          NATIVE_ROUTE + '            case "request":\n                let params = asDict(message["params"]) ?? [:]')
    source = replace_once(source, "    private let peerPID: Int32?\n", "    private let peerPID: Int32?\n    private let fixturePeer: PeerAuditCredentials\n")
    source = replace_once(source, "        peerPID = credentials.pid\n", "        peerPID = credentials.pid\n        fixturePeer = credentials\n")
    source = replace_once(source, "files: files, wireData: data,\n                       serializationFailed:",
                          "files: files, wireData: data, fixturePeer: fixturePeer,\n                       serializationFailed:")
    boundary = "        let preparation = RequestPreparation(requestType: requestType)"
    source = replace_once(source, boundary, '''        // The corpus stops after the production typed decoder and before policy,
        // application resolution, permission prompts or any operation.
        if CommandLine.arguments[1] == "--owned-codec-socket" {
            _ = try decodeXPCBody?() ?? decodedSocketBody ?? params["request"]
            return ["codecValidated": true]
        }
''' + boundary)
    socket = "                        return try ServiceApplicationUsageCompletion.encode(typeName: requestType,"
    source = replace_once(source, socket, '''                        if CommandLine.arguments[1] == "--owned-codec-socket" {
                            return try NativeResponseEncoding.encode(response ?? NSNull())
                        }
''' + socket)
    native = "                    let encoded = try ServiceApplicationUsageCompletion.encode(typeName: type,"
    source = replace_once(source, native, '''                    if CommandLine.arguments[1] == "--owned-codec-socket" {
                        let encoded = try NativeResponseEncoding.encode(result)
                        try RequestRuntime.check()
                        return encoded
                    }
''' + native)
    return replace_once(source,
        '                return ["id": id, "jsonrpc": "2.0", "result": try SocketResponseBody.normalizeData(result, for: requestType)]',
        '''                let reply: Any
                if let raw = str(params["ownedRawResponse"]) {
                    reply = try SocketResponseBody.normalizeData(Data(raw.utf8), for: requestType)
                } else {
                    reply = try JSONSerialization.jsonObject(with: result)
                }
                return ["id": id, "jsonrpc": "2.0", "result": reply]''')


def build_fixture(manifest_path, project, output, transforms, identifier, startup):
    manifest_path = Path(manifest_path).resolve(strict=True)
    manifest = json.loads(manifest_path.read_text())
    hashes = manifest["source_hashes"]
    if manifest["exit_code"] != 0 or any(
        sha(project / name) != digest
        for name, digest in {**hashes, **manifest["configuration_hashes"]}.items()
    ):
        raise ValueError("Review build inputs no longer match their manifest")
    run = Path(os.environ["CUA_REVIEW_RUN"]).resolve(strict=True)
    if not output.is_relative_to(run / "t"):
        raise ValueError("Codec fixture output must be inside the review run")
    sources = output.parent / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    command = manifest["command"].copy()
    for name, transform in transforms.items():
        indices = [i for i, arg in enumerate(command) if Path(arg).name == name]
        if len(indices) != 1:
            raise ValueError(f"Missing unique {name} in the selected build")
        index = indices[0]
        fixture = sources / name
        fixture.write_text(transform(Path(command[index]).read_text()))
        command[index] = str(fixture)
    command[command.index("-o") + 1] = str(output)
    subprocess.run(command, cwd=project / "service", check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identifier, str(output)], check=True)
    receipt = dict(selected_manifest=str(manifest_path), selected_manifest_sha256=sha(manifest_path),
                   compiled_inputs=len(hashes), fixture_sources={p.name:sha(p) for p in sources.iterdir()},
                   command=command, binary_sha256=sha(output), startup=startup,
                   kernel_peer_credentials_preserved=True, native_mach_xpc_used=False)
    (output.parent / "build-result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Review fixture built from the selected service graph: {startup}", flush=True)


def native_socket_route(source):
    return replace_once(source, 'case "request": kind = .request',
                        'case "request", "ownedFixtureNativeRequest": kind = .request')


def build(manifest_path, project, output):
    build_fixture(manifest_path, project, output, {"main.swift": prepare_main, "SocketJSONRPC.swift": native_socket_route},
                  "test.acua.review-codec-fixture", "owned codec socket only")
