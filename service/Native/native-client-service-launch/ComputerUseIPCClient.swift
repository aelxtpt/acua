import AppKit

// NSRunningApplication is retained across the request.
// Its read-only process identifier may be queried from any thread.
struct ResolvedComputerUseService: @unchecked Sendable {
    let application: NSRunningApplication
    var processIdentifier: pid_t { application.processIdentifier }
}

enum ComputerUseIPCClient {
    private static func service() async throws -> ResolvedComputerUseService {
        let identifier = await MainActor.run {
            Bundle.main.object(forInfoDictionaryKey: "CUAServiceBundleIdentifier") as? String
                ?? CodexRunningService.ownBundleIdentifier
        }
        return try await resolve(identifier)
    }

    @MainActor private static func resolve(_ identifier: String) async throws -> ResolvedComputerUseService {
        guard let application = try await CodexRunningService.resolve(serviceBundleIdentifier: identifier, launchIfNeeded: true) else {
            throw Error.couldNotFindServiceApp
        }
        return ResolvedComputerUseService(application: application)
    }

    static func sendRequest<Request: ComputerUseIPCRequest>(_ request: Request, files: [FileHandle] = []) async throws -> Request.Response {
        let service = try await service()
        defer { withExtendedLifetime(service) {} }
        return try await ComputerUseIPCXPCTransport.sendRequest(request, files: files, pid: service.processIdentifier)
    }

    static func foregroundUpdates() async throws -> ClientForegroundStream {
        let service = try await service()
        defer { withExtendedLifetime(service) {} }
        return try await ComputerUseIPCXPCTransport.foregroundUpdates(pid: service.processIdentifier)
    }
}
