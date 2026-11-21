import Darwin
import Foundation
import ObjectiveC
import QuartzCore
import XPC
import os

// Private CAContext selectors and signatures, verified against the installed
// QuartzCore runtime. The factory uses empty options.
final class RemoteHostedPIPLayerContext {
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias CreateContext = @convention(c) (AnyClass, Selector, UInt32, NSDictionary) -> Unmanaged<AnyObject>?
    private typealias GetID = @convention(c) (AnyObject, Selector) -> UInt32
    private typealias SetLayer = @convention(c) (AnyObject, Selector, CALayer?) -> Void
    private typealias SetFence = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private static let image = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL)
    private static let mainConnection: MainConnection? = image.flatMap { dlsym($0, "CGSMainConnectionID") }.map { unsafeBitCast($0, to: MainConnection.self) }
    private let context: NSObject
    let rootLayer: CALayer

    private init(context: NSObject, rootLayer: CALayer) { self.context = context; self.rootLayer = rootLayer }

    static func create() -> RemoteHostedPIPLayerContext? {
        create(contextClass: NSClassFromString("CAContext"), connection: mainConnection)
    }

    // Dependency entry point permits testing the capability guards.
    // Production creation always uses CAContext and CGSMainConnectionID above.
    static func create(contextClass: AnyClass?, connection: (() -> UInt32)?) -> RemoteHostedPIPLayerContext? {
        let selector = NSSelectorFromString("contextWithCGSConnection:options:")
        guard let contextClass, let connection, let method = class_getClassMethod(contextClass, selector) else { return nil }
        let create = unsafeBitCast(method_getImplementation(method), to: CreateContext.self)
        guard let context = create(contextClass, selector, connection(), [:]).map({ $0.takeUnretainedValue() }) as? NSObject,
              context.responds(to: NSSelectorFromString("contextId")),
              context.responds(to: NSSelectorFromString("setLayer:")) else { return nil }
        let layer = CALayer()
        let set = unsafeBitCast(context.method(for: NSSelectorFromString("setLayer:")), to: SetLayer.self)
        set(context, NSSelectorFromString("setLayer:"), layer)
        return .init(context: context, rootLayer: layer)
    }

    var contextID: UInt32 {
        let selector = NSSelectorFromString("contextId")
        return unsafeBitCast(context.method(for: selector), to: GetID.self)(context, selector)
    }

    func createFencePort() -> mach_port_t {
        let selector = NSSelectorFromString("createFencePort")
        guard context.responds(to: selector), context.responds(to: NSSelectorFromString("setFencePort:")) else { return 0 }
        return unsafeBitCast(context.method(for: selector), to: GetID.self)(context, selector)
    }

    func setFencePort(_ port: mach_port_t) {
        let selector = NSSelectorFromString("setFencePort:")
        unsafeBitCast(context.method(for: selector), to: SetFence.self)(context, selector, port)
    }

    func invalidate() {
        let selector = NSSelectorFromString("setLayer:")
        unsafeBitCast(context.method(for: selector), to: SetLayer.self)(context, selector, nil)
    }
}

final class RemoteHostedPIPContentFence {
    private let ownedPort:OSAllocatedUnfairLock<mach_port_t>
    var port:mach_port_t { ownedPort.withLock {$0} }
    fileprivate init(ownedPort:mach_port_t) { self.ownedPort = .init(initialState:ownedPort) }
    func release() {
        let port=ownedPort.withLock { value in let old=value;value=0;return old }
        if port != 0 { mach_port_deallocate(mach_task_self_,port) }
    }
    func payload() -> RemoteHostedPIPFencePayload {
        let dictionary = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_mach_send(dictionary, "fence", port)
        return dictionary as! RemoteHostedPIPFencePayload
    }
    deinit { release() }
}

final class RemoteHostedPIPContentProducer {
    private enum Error: Swift.Error, CustomNSError {
        case couldNotCreateContext
        static var errorDomain: String {
            let name = String(reflecting: Self.self)
            return "ComputerUse" + name[name.range(of: ".RemoteHostedPIPContentProducer.")!.lowerBound...]
        }
        var errorCode: Int { 0 }
        var errorUserInfo: [String: Any] { [:] }
    }

    let rootLayer: CALayer
    private let context: RemoteHostedPIPLayerContext
    convenience init() throws { try self.init(contextFactory: RemoteHostedPIPLayerContext.create) }
    init(contextFactory: () -> RemoteHostedPIPLayerContext?) throws {
        guard let context = contextFactory() else { throw Error.couldNotCreateContext }
        self.context = context; rootLayer = context.rootLayer
    }
    var contextID: UInt32 { context.contextID }
    func createFence() -> RemoteHostedPIPContentFence? {
        let port = context.createFencePort()
        return port == 0 ? nil : .init(ownedPort: port)
    }
    func setFence(_ fence: RemoteHostedPIPContentFence) { context.setFencePort(fence.port) }
    func invalidate() { context.invalidate() }
}
