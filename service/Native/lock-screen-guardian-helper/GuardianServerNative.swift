import Foundation

@_silgen_name("cua_guardian_copy_send_right") private func nativeCopySendRight(_ name: UnsafeRawPointer, _ error: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UInt32
@_silgen_name("cua_guardian_deallocate_send_right") private func nativeDeallocateSendRight(_ port: UInt32)
@_silgen_name("cua_guardian_send_endpoint") private func nativeSendEndpoint(_ port: UInt32, _ endpoint: UnsafeRawPointer, _ error: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32

final class GuardianServerNativeEnvironment: GuardianServerEnvironment, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let diagnostic: @Sendable ((any Error)?) -> Void
    init(diagnostic: @escaping @Sendable ((any Error)?) -> Void = { _ in }) { self.diagnostic = diagnostic }
    func attach(_ session: CUALockScreenGuardianXPCSession) { listener.delegate = session }
    func activateListener() { listener.activate() }
    func invalidateListener() { listener.invalidate() }
    func copySendRight(name: String) -> (UInt32, NSError?) {
        let name = name as NSString
        var error: UnsafeMutableRawPointer?
        let port = withExtendedLifetime(name) { nativeCopySendRight(Unmanaged.passUnretained(name).toOpaque(), &error) }
        return (port, error.map { Unmanaged<NSError>.fromOpaque($0).takeRetainedValue() })
    }
    func sendEndpoint(port: UInt32) -> (Bool, NSError?) {
        let endpoint = listener.endpoint
        var error: UnsafeMutableRawPointer?
        let result = withExtendedLifetime(endpoint) { nativeSendEndpoint(port, Unmanaged.passUnretained(endpoint).toOpaque(), &error) }
        return (result != 0, error.map { Unmanaged<NSError>.fromOpaque($0).takeRetainedValue() })
    }
    func deallocateSendRight(_ port: UInt32) { nativeDeallocateSendRight(port) }
    func report(_ error: (any Error)?) { diagnostic(error) }
}

private final class GuardianServerNativeConnection: GuardianServerConnection, @unchecked Sendable {
    let value: NSXPCConnection
    init(_ value: NSXPCConnection) { self.value = value }
    func configure(session: CUALockScreenGuardianXPCSession, invalidation: @escaping @Sendable () -> Void,
                   interruption: @escaping @Sendable () -> Void) {
        value.exportedInterface = NSXPCInterface(with: ExternalGuardianRemoteXPCProtocol.self)
        value.exportedObject = session
        value.remoteObjectInterface = NSXPCInterface(with: ExternalGuardianClientXPCProtocol.self)
        value.invalidationHandler = invalidation
        value.interruptionHandler = interruption
    }
    func activate() { value.activate() }
    func invalidate() { value.invalidate() }
    func physicalInput(error: @escaping @Sendable (any Error) -> Void) -> Bool {
        guard let proxy = value.remoteObjectProxyWithErrorHandler(error) as? ExternalGuardianClientXPCProtocol else { return false }
        proxy.detectedPhysicalInput()
        return true
    }
}

extension CUALockScreenGuardianXPCSession: NSXPCListenerDelegate, ExternalGuardianRemoteXPCProtocol {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        accept(GuardianServerNativeConnection(connection))
    }
}
