import Foundation
import Darwin

@main enum SenderPeerNative {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, let expectedPID = Int32(args[2]) else {
            fatalError("Pass a temporary fixture socket and the expected PID")
        }
        let socketDirectory = URL(fileURLWithPath: args[1]).deletingLastPathComponent().resolvingSymlinksInPath()
        let temporaryRoots = [URL(fileURLWithPath: NSTemporaryDirectory()), URL(fileURLWithPath: "/tmp")]
        guard temporaryRoots.contains(where: { root in
            let path = root.resolvingSymlinksInPath().path
            return socketDirectory.path == path || socketDirectory.path.hasPrefix(path + "/")
        }) else { fatalError("Only temporary fixture sockets") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fatalError("socket") }
        defer { close(fd); unlink(args[1]) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(args[1].utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fatalError("path") }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { buffer in
                for (i, byte) in bytes.enumerated() { buffer[i] = byte }; buffer[bytes.count] = 0
            }
        }
        let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard status == 0, listen(fd, 1) == 0 else { fatalError("bind/listen") }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { fatalError("accept") }
        defer { close(client) }
        guard let credentials = PeerAuditCredentials.read(fd: client) else { fatalError("kernel audit credentials unavailable") }
        let result: [String: Any] = ["pidMatchesActualPeer": credentials.pid == expectedPID,
            "uidMatchesService": credentials.uid == geteuid(), "auditTokenBytes": credentials.auditToken.count,
            "peerSigningTeamAvailable": SigningTeam.peer(auditToken: credentials.auditToken) != nil,
            "ownSigningTeamAvailable": SigningTeam.own() != nil]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
