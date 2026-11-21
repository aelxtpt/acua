import AppKit
import ApplicationServices
import Foundation
import os

/// Examine the returned title object without checking the raw AX status.
/// A native response object survives even if its status is an error.
struct ControllerNativeSettleTitleReader: Sendable {
    typealias Key = SettingsNativeAXElement
    struct Result: Sendable { let status: Int32; let value: ControllerNativeAXValue? }
    let lookup: ControllerNativeElementIO.Lookup
    let ordinaryPID: @Sendable (Key) -> Int32?
    let raw: @Sendable (Key) -> Result
    func title(_ key: Key) -> String? {
        if let provider = lookup(key) { return try? provider.read("AXTitle")?.raw as? String }
        let work: @Sendable () -> String? = { raw(key).value?.raw as? String }
        if ordinaryPID(key) == getpid(), !Thread.isMainThread { return DispatchQueue.main.sync(execute: work) }
        return work()
    }
    static func native(resources: ControllerNativeResources) -> Self {
        .init(lookup: resources.io.lookup, ordinaryPID: { key in
            var pid: pid_t = -1
            return AXUIElementGetPid(key.element, &pid) == .success ? pid : nil
        }, raw: { key in
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(key.element, "AXTitle" as CFString, &value)
            return .init(status: status.rawValue, value: value.map { .init(raw: $0) })
        })
    }
}

enum ControllerNativeSettleActivitySampling {
    static func age<Key>(_ activity: ControllerUISettleActivity<Key>) async -> Double {
        // Sample this lock on a generic executor. A callback
        // can hold it while synchronously reading a self-process title on
        // main. Keep main free while waiting for that callback to finish.
        await Task.detached(priority: Task.currentPriority) {
            activity.quietAge(now: CFAbsoluteTimeGetCurrent)
        }.value
    }
}

@MainActor protocol ControllerNativeSettleObservation: AnyObject {
    func quietAge(now: () -> Double) async -> Double
    func stop()
}
@MainActor final class ControllerNativeAXSettleObservation: ControllerNativeSettleObservation {
    private let activity: ControllerUISettleActivity<SettingsNativeAXElement>
    private let observer: EventStreamNativeAXObserver
    init(application: ControllerNativeElementContext.Node, notifications: [String], resources: ControllerNativeResources) throws {
        let activity = ControllerUISettleActivity<SettingsNativeAXElement>(now: CFAbsoluteTimeGetCurrent())
        self.activity = activity
        let reader = ControllerNativeSettleTitleReader.native(resources: resources)
        let pid = try ControllerAXEnablementNative.pid(application.element, lookup: { resources.io.lookup($0)?.ordinaryPID })
        let callback: @Sendable (AXUIElement, String) -> Void = { element, name in
            let key = SettingsNativeAXElement(element: element)
            _ = activity.receive(name, key: key, title: { reader.title(key) }, now: CFAbsoluteTimeGetCurrent)
        }
        observer = try EventStreamNativeAXObserver(pid: pid, handler: callback)
        do {
            for name in notifications { try observer.register(name, for: application.element.element, ignoring: .cannotComplete) }
            observer.start()
        } catch { observer.stop(); throw error }
    }
    func quietAge(now: () -> Double) async -> Double { await ControllerNativeSettleActivitySampling.age(activity) }
    func stop() { observer.stop() }
}

@MainActor struct ControllerNativeUISettleEnvironment {
    typealias Node = ControllerNativeElementContext.Node
    let now: () -> Double
    let cancelled: () -> Bool
    let sleep: (Double) async throws -> Void
    let webShaped: (Node) -> Bool
    let observe: (Node, [String]) throws -> any ControllerNativeSettleObservation
    let monitor: (Node) -> EventStreamTreeInvalidationMonitor
    let transaction: (Node) -> EventStreamNativeTreeTransaction
    let log: (ControllerUISettleLog, Double?) -> Void
    static func native(resources: ControllerNativeResources) -> Self {
        .init(now: CFAbsoluteTimeGetCurrent, cancelled: { Task.isCancelled }, sleep: { try await ContinuousClock().sleep(for: .seconds($0)) },
            webShaped: { node in
                guard let pid = try? ControllerAXEnablementNative.pid(node.element, lookup: { resources.io.lookup($0)?.ordinaryPID }),
                      let url = NSRunningApplication(processIdentifier: pid)?.bundleURL, let bundle = Bundle(url: url) else { return false }
                return EventStreamBundleShape.isWebShaped(read: bundle.object(forInfoDictionaryKey:))
            }, observe: { try ControllerNativeAXSettleObservation(application: $0, notifications: $1, resources: resources) },
            monitor: { node in
                .init(application: node.element.element, io: .init(processIdentifier: { _ in
                    try ControllerAXEnablementNative.pid(node.element, lookup: { resources.io.lookup($0)?.ordinaryPID })
                }, observer: { try EventStreamNativeAXObserver(pid: $0, handler: $1) }))
            }, transaction: { ControllerNativeSettleCapture(resources: resources).transaction($0) }, log: { event, value in
                Logger(subsystem: "local.cua", category: "UISettle").info("log[\(event.rawValue, privacy: .public)] \(value ?? 0)")
            })
    }
}
@MainActor struct ControllerNativeUISettle: ControllerUISettleBackend {
    typealias Window = ControllerNativeElementContext.Node
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias Observation = any ControllerNativeSettleObservation
    let application: Window
    let resources: ControllerNativeResources
    let environment: ControllerNativeUISettleEnvironment
    var isCancelled: Bool { environment.cancelled() }
    func isWebShaped() -> Bool { environment.webShaped(application) }
    func now() -> Double { environment.now() }
    func observe(_ notifications: [String]) throws -> Observation { try environment.observe(application, notifications) }
    func stop(_ observation: Observation) { observation.stop() }
    func quietAge(_ observation: Observation) async -> Double { await observation.quietAge(now: environment.now) }
    func sleep(_ seconds: Double) async throws { try await environment.sleep(seconds) }
    func focusedWindow() -> Window? { resources.context.context.focusedWindow(application) }
    func mainWindow() -> Window? { resources.context.context.mainWindow(application) }
    func windows() -> [Window] { resources.context.context.windows(application) }
    func inspect(_ window: Window) async throws -> (busy: Bool, cache: Cache) {
        let monitor = environment.monitor(application)
        let transaction = environment.transaction(window)
        return ControllerNativeSettleCapture(resources: resources).inspect(application: application, window: window,
            transaction: transaction, monitor: monitor, webShaped: { environment.webShaped(application) })
    }
    func log(_ event: ControllerUISettleLog, value: Double?) { environment.log(event, value) }
}
extension ControllerNativeClickRuntime {
    static func native(resources: ControllerNativeResources, settleEnvironment: ControllerNativeUISettleEnvironment? = nil) -> Self {
        let environment = settleEnvironment ?? .native(resources: resources)
        return .nativeClick(resources: resources, settle: { application, delay, notificationDelay, scroll in
            try await ControllerUISettle(backend: ControllerNativeUISettle(application: application, resources: resources, environment: environment))
                .wait(.init(delay: delay, notificationDelay: notificationDelay, includingScrollEvents: scroll))
        })
    }
}
