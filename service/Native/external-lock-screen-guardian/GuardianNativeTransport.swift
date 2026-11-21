import Foundation

@_silgen_name("cua_guardian_rendezvous_create") private func createRendezvous(_ name:UnsafeRawPointer,_ error:UnsafeMutablePointer<UnsafeMutableRawPointer?>)->UnsafeMutableRawPointer?
@_silgen_name("cua_guardian_rendezvous_port") private func rendezvousPort(_ object:UnsafeRawPointer)->UInt32
@_silgen_name("cua_guardian_rendezvous_invalidate") private func invalidateRendezvous(_ object:UnsafeRawPointer)
@_silgen_name("cua_guardian_receive_endpoint") private func receiveEndpoint(_ port:UInt32,_ error:UnsafeMutablePointer<UnsafeMutableRawPointer?>)->UnsafeMutableRawPointer?
@_silgen_name("cua_guardian_send_endpoint") private func sendEndpoint(_ port:UInt32,_ endpoint:UnsafeRawPointer,_ error:UnsafeMutablePointer<UnsafeMutableRawPointer?>)->Int32
@_silgen_name("cua_guardian_lookup_port") private func lookupPort(_ name:UnsafeRawPointer,_ retainedPort:UnsafeMutablePointer<UnsafeMutableRawPointer?>)->UInt32

final class GuardianNativeEndpoint:@unchecked Sendable {
    let value:NSXPCListenerEndpoint
    init(_ value:NSXPCListenerEndpoint){self.value=value}
}
@MainActor final class GuardianNativeRendezvous:ExternalGuardianRendezvous {
    private let value:AnyObject
    init(name:String)throws {
        let name=name as NSString;var error:UnsafeMutableRawPointer?
        let pointer=withExtendedLifetime(name){createRendezvous(Unmanaged.passUnretained(name).toOpaque(),&error)}
        let failure=error.map{Unmanaged<NSError>.fromOpaque($0).takeRetainedValue()}
        guard let pointer else{throw failure ?? NSError(domain:"SAIMachBootstrapRendezvous",code:1)}
        value=Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
    }
    var receivePort:UInt32{rendezvousPort(Unmanaged.passUnretained(value).toOpaque())}
    func invalidate(){invalidateRendezvous(Unmanaged.passUnretained(value).toOpaque())}
}
enum GuardianNativeEndpointTransport {
    nonisolated static func receive(port:UInt32)throws->GuardianNativeEndpoint? {
        var error:UnsafeMutableRawPointer?
        let pointer=receiveEndpoint(port,&error)
        let failure=error.map{Unmanaged<NSError>.fromOpaque($0).takeRetainedValue()}
        guard let pointer else{if let failure{throw failure};return nil}
        return .init(Unmanaged<NSXPCListenerEndpoint>.fromOpaque(pointer).takeRetainedValue())
    }
    nonisolated static func send(endpoint:NSXPCListenerEndpoint,name:String)throws {
        let name=name as NSString;var owner:UnsafeMutableRawPointer?
        let port=withExtendedLifetime(name){lookupPort(Unmanaged.passUnretained(name).toOpaque(),&owner)}
        let retained=owner.map{Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue()}
        var error:UnsafeMutableRawPointer?
        let result=withExtendedLifetime(retained){withExtendedLifetime(endpoint){sendEndpoint(port,Unmanaged.passUnretained(endpoint).toOpaque(),&error)}}
        let failure=error.map{Unmanaged<NSError>.fromOpaque($0).takeRetainedValue()}
        if result==0{throw failure ?? NSError(domain:"SAIXPCEndpointTransport",code:2)}
    }
}
