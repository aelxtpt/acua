import Foundation
import XPC

typealias ClientFileArray = NSObject & OS_xpc_object

@objc(SAIComputerUseForegroundObserver)
protocol ClientForegroundObserver {
    @objc(receiveForegroundContext:)
    func receiveForegroundContext(_ data: Data)
}

@objc(SAIComputerUseIPCXPCProtocol)
protocol ClientIPCProtocol {
    @objc(sendRequestWithTypeName:requestData:agentMetadataData:fileDescriptors:withReply:)
    func sendRequest(typeName: String, requestData: Data?, agentMetadataData: Data?, fileDescriptors: ClientFileArray,
                     reply: @escaping (Data?, NSError?) -> Void)
    @objc(subscribeToForegroundContextWithID:observer:withReply:)
    func subscribeToForegroundContext(id: NSUUID, observer: ClientForegroundObserver, reply: @escaping (NSError?) -> Void)
    @objc(unsubscribeFromForegroundContextWithID:)
    func unsubscribeFromForegroundContext(id: NSUUID)
}

enum ClientIPCInterface {
    static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: ClientIPCProtocol.self)
        interface.setXPCType(XPC_TYPE_ARRAY,
            for: #selector(ClientIPCProtocol.sendRequest(typeName:requestData:agentMetadataData:fileDescriptors:reply:)),
            argumentIndex: 3, ofReply: false)
        interface.setInterface(NSXPCInterface(with: ClientForegroundObserver.self),
            for: #selector(ClientIPCProtocol.subscribeToForegroundContext(id:observer:reply:)),
            argumentIndex: 1, ofReply: false)
        return interface
    }
}
