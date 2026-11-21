import CoreGraphics
import Darwin
import Foundation

final class RemoteHostedPIPWindowServerObserver {
    enum Event: UInt32, Sendable {
        case terminated = 804
        case resized = 807
        case orderChanged = 808
        case geometryChanged = 809
        case workspaceAddedWindow = 1325
    }

    private struct Subscription {
        let windows: Set<CGWindowID>?
        let events: Set<Event>
        let onEvent: @Sendable (CGWindowID, Event) -> Void
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var nextToken: UInt = 1
        private var subscriptions: [UInt: Subscription] = [:]

        func insert(_ subscription: Subscription) -> UInt {
            lock.withLock {
                let token = nextToken
                nextToken += 1
                subscriptions[token] = subscription
                return token
            }
        }

        func remove(_ token: UInt) {
            _ = lock.withLock { subscriptions.removeValue(forKey: token) }
        }

        func deliver(token: UInt, window: CGWindowID, event: Event) {
            let subscription = lock.withLock { subscriptions[token] }
            if let subscription, subscription.events.contains(event),
               subscription.windows?.contains(window) != false { subscription.onEvent(window, event) }
        }
    }

    private typealias Callback = @convention(c) (UInt32, UnsafeRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias ConnectionID = @convention(c) () -> Int32
    private typealias Registration = @convention(c) (Int32, Callback, UInt32, UnsafeMutableRawPointer?) -> Int32
    private struct API {
        let connectionID: ConnectionID
        let register: Registration
        let remove: Registration
    }

    private static let api: API? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        else { return nil }
        func resolve(_ name: String) -> UnsafeMutableRawPointer? {
            dlsym(library, name) ?? dlsym(library, "_" + name)
        }
        guard let connectionID = resolve("CGSMainConnectionID"),
              let register = resolve("CGSRegisterConnectionNotifyProc"),
              let remove = resolve("CGSRemoveConnectionNotifyProc") else { return nil }
        return API(connectionID: unsafeBitCast(connectionID, to: ConnectionID.self),
                   register: unsafeBitCast(register, to: Registration.self),
                   remove: unsafeBitCast(remove, to: Registration.self))
    }()

    private static let registry = Registry()
    private static let requestLock = NSLock()
    private static let callback: Callback = { event, data, length, context in
        guard let event = Event(rawValue: event), let context, let data, length >= MemoryLayout<CGWindowID>.size else { return }
        var offset = 0
        if event == .workspaceAddedWindow, length != MemoryLayout<CGWindowID>.size {
            // Current WindowServer sends two workspace words before the window ID.
            offset = 2 * MemoryLayout<UInt32>.size
            guard length >= offset + MemoryLayout<CGWindowID>.size else { return }
        }
        RemoteHostedPIPWindowServerObserver.registry.deliver(token: UInt(bitPattern: context),
            window: data.loadUnaligned(fromByteOffset: offset, as: CGWindowID.self), event: event)
    }

    private let api: API
    private let connection: Int32
    private let token: UInt
    private let events: Set<Event>
    private var requestLease: WindowServerNotificationRequests.Lease?

    init?(windowIDs: Set<CGWindowID>?, events: Set<Event> = [.terminated, .resized, .geometryChanged],
          onEvent: @escaping @Sendable (CGWindowID, Event) -> Void) {
        guard let api = Self.api, windowIDs?.isEmpty != true, !events.isEmpty else { return nil }
        let connection = api.connectionID()
        guard connection != 0 else { return nil }
        // WindowServer returns the context value unchanged. A registry token
        // allows a late callback to be dropped without dereferencing an object.
        var requestLease: WindowServerNotificationRequests.Lease?
        let token: UInt? = Self.requestLock.withLock {
            let token = Self.registry.insert(Subscription(windows: windowIDs, events: events, onEvent: onEvent))
            let context = UnsafeMutableRawPointer(bitPattern: token)
            var installed: [Event] = []
            for event in events.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard api.register(connection, Self.callback, event.rawValue, context) == 0 else { break }
                installed.append(event)
            }
            guard installed.count == events.count else {
                Self.unregister(api: api, connection: connection, token: token, events: installed)
                return nil
            }
            if let windowIDs {
                requestLease=WindowServerNotificationRequests.shared.acquire(connection:connection,windows:Array(windowIDs),requireSuccess:true)
                guard requestLease != nil else {
                    Self.unregister(api:api,connection:connection,token:token,events:installed)
                    return nil
                }
            }
            return token
        }
        guard let token else { return nil }
        self.api = api
        self.connection = connection
        self.token = token
        self.events = events
        self.requestLease = requestLease
    }

    deinit {
        Self.requestLock.withLock {
            Self.unregister(api: api, connection: connection, token: token, events: Array(events))
            requestLease = nil
        }
    }

    private static func unregister(api: API, connection: Int32, token: UInt, events: [Event]) {
        registry.remove(token)
        let context = UnsafeMutableRawPointer(bitPattern: token)
        for event in events { _ = api.remove(connection, callback, event.rawValue, context) }
    }
}
