import AppKit
import Combine
import Foundation

struct RemoteHostedPIPContentHostProcess: Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let displayName: String?

    init(processIdentifier: Int32, bundleIdentifier: String?, displayName: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    init(processIdentifier: Int32) {
        let application = NSRunningApplication(processIdentifier: processIdentifier)
        self.init(processIdentifier: processIdentifier,
            bundleIdentifier: application?.bundleIdentifier ?? application?.bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier },
            displayName: application?.localizedName ?? application?.executableURL?.lastPathComponent)
    }

    var connectionLabel: String { bundleIdentifier ?? displayName ?? "PID \(processIdentifier)" }
    var diagnosticLabel: String { [displayName, bundleIdentifier, "PID \(processIdentifier)"].compactMap { $0 }.joined(separator: ", ") }
}

enum RemoteHostedPIPContentConnectionStatus: Equatable {
    case stopped, waitingForHost, awaitingConnection, connected, interrupted
}

struct RemoteHostedPIPContentConnectionError: Equatable {
    let domain: String
    let code: Int
    let message: String
}

struct RemoteHostedPIPContentConnectionEvent: Equatable, Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let details: String?
    let error: RemoteHostedPIPContentConnectionError?
}

struct RemoteHostedPIPContentConnectionDiagnostics: Equatable {
    var status: RemoteHostedPIPContentConnectionStatus = .stopped
    var attemptCount = 0
    var lastAttemptDate: Date?
    var nextRetryDate: Date?
    var connectedDate: Date?
    var hostProcess: RemoteHostedPIPContentHostProcess?
    var events: [RemoteHostedPIPContentConnectionEvent] = []

    mutating func record(_ message: String, details: String? = nil, error: RemoteHostedPIPContentConnectionError? = nil) {
        events.insert(.init(message: message, details: details, error: error), at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }
}

private struct RemoteHostedPIPContentConnectionDebugState {
    let hostApplication: NSRunningApplication?
    var completedHandshake = false
    var wasInterrupted = false
    var requestedInvalidationReason: String?
}

// The publisher supplies its real producer handlers and stream effects. This component
// owns only the native listener, connection lifetime and diagnostic state.
@MainActor
protocol RemoteHostedPIPConnectionOwner: RemoteHostedPIPContentProducerXPCProtocol {
    func resetRemoteHostedStreams()
    func enqueueRemoteHostedStreamsAndCursorReplay()
    func clearRemoteHostedPetLocation()
}

private final class RemoteHostedPIPConnectionListener: NSObject, NSXPCListenerDelegate {
    weak var exportedObject: (any RemoteHostedPIPConnectionOwner)?
    var didAccept: ((NSXPCConnection) -> Void)?
    var didInvalidate: ((NSXPCConnection) -> Void)?
    var didInterrupt: ((NSXPCConnection) -> Void)?

    init(exportedObject: any RemoteHostedPIPConnectionOwner) { self.exportedObject = exportedObject }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let exportedObject else { return false }
        connection.exportedInterface = RemoteHostedPIPXPC.producerInterface()
        connection.exportedObject = exportedObject
        connection.remoteObjectInterface = RemoteHostedPIPXPC.hostInterface()
        connection.invalidationHandler = { [weak self, weak connection] in
            if let connection { self?.didInvalidate?(connection) }
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            if let connection { self?.didInterrupt?(connection) }
        }
        connection.activate()
        didAccept?(connection)
        return true
    }
}

@MainActor
final class RemoteHostedPIPConnection: NSObject, ObservableObject {
    @Published private(set) var connectionDiagnostics = RemoteHostedPIPContentConnectionDiagnostics()
    private(set) var connection: NSXPCConnection?
    private var debugState: RemoteHostedPIPContentConnectionDebugState?
    private let listener: NSXPCListener
    private let listenerDelegate: RemoteHostedPIPConnectionListener
    private weak var owner: (any RemoteHostedPIPConnectionOwner)?

    init(owner: any RemoteHostedPIPConnectionOwner) {
        self.owner = owner
        listener = .anonymous()
        listenerDelegate = RemoteHostedPIPConnectionListener(exportedObject: owner)
        super.init()
        listenerDelegate.didAccept = { [weak self] connection in
            Task { @MainActor [weak self] in self?.adopt(connection) }
        }
        listenerDelegate.didInvalidate = { [weak self] connection in
            Task { @MainActor [weak self] in self?.didInvalidate(connection) }
        }
        listenerDelegate.didInterrupt = { [weak self] connection in
            Task { @MainActor [weak self] in self?.didInterrupt(connection) }
        }
        listener.delegate = listenerDelegate
        listener.activate()
    }

    deinit { listener.invalidate() }

    func recordFailure(_ message: String, error: Swift.Error) {
        let error = error as NSError
        var diagnostics = connectionDiagnostics
        diagnostics.record(message, error: .init(domain: error.domain, code: error.code, message: error.localizedDescription))
        connectionDiagnostics = diagnostics
    }

    func start() {
        var diagnostics = connectionDiagnostics
        diagnostics.status = connection == nil ? .waitingForHost : .connected
        diagnostics.nextRetryDate = nil
        connectionDiagnostics = diagnostics
    }

    func endpointForHostConnection() -> NSXPCListenerEndpoint {
        var diagnostics = connectionDiagnostics
        diagnostics.status = .awaitingConnection
        diagnostics.attemptCount += 1
        diagnostics.lastAttemptDate = Date()
        diagnostics.nextRetryDate = nil
        diagnostics.record("Host requested a private PiP endpoint")
        connectionDiagnostics = diagnostics
        return listener.endpoint
    }

    func retryConnection() {
        var diagnostics = connectionDiagnostics
        diagnostics.record("Manual retry requested")
        connectionDiagnostics = diagnostics
        if let connection {
            debugState?.requestedInvalidationReason = "Publisher requested invalidation for a manual retry."
            connection.invalidate()
        } else { start() }
    }

    // The Objective-C producer must invoke this from its MainActor task, after
    // replying to connectWithReply:. A handshake can precede connection adoption.
    func didCompleteHandshake() {
        debugState?.completedHandshake = true
        var diagnostics = connectionDiagnostics
        diagnostics.record("Host handshake completed")
        connectionDiagnostics = diagnostics
    }

    func adopt(_ incoming: NSXPCConnection) {
        guard connection !== incoming else { return }
        connection?.invalidate()
        connection = incoming
        debugState = .init(hostApplication: NSRunningApplication(processIdentifier: incoming.processIdentifier))
        let process = RemoteHostedPIPContentHostProcess(processIdentifier: incoming.processIdentifier)
        var diagnostics = connectionDiagnostics
        diagnostics.status = .connected
        diagnostics.nextRetryDate = nil
        diagnostics.connectedDate = Date()
        diagnostics.hostProcess = process
        diagnostics.record("Connected to \(process.connectionLabel)")
        connectionDiagnostics = diagnostics
        owner?.resetRemoteHostedStreams()
        owner?.enqueueRemoteHostedStreamsAndCursorReplay()
    }

    func didInterrupt(_ interrupted: NSXPCConnection) {
        guard connection === interrupted else { return }
        debugState?.wasInterrupted = true
        var diagnostics = connectionDiagnostics
        diagnostics.status = .interrupted
        diagnostics.record("XPC connection interrupted")
        connectionDiagnostics = diagnostics
    }

    func didInvalidate(_ invalidated: NSXPCConnection) {
        guard connection === invalidated else { return }
        let details = invalidationDetails()
        connection = nil
        var diagnostics = connectionDiagnostics
        diagnostics.status = .waitingForHost
        diagnostics.connectedDate = nil
        diagnostics.hostProcess = nil
        diagnostics.record("XPC connection invalidated", details: details)
        connectionDiagnostics = diagnostics
        debugState = nil
        owner?.clearRemoteHostedPetLocation()
        owner?.resetRemoteHostedStreams()
    }

    func invalidationDetails() -> String {
        let process = connectionDiagnostics.hostProcess
        let visible = process.flatMap { NSRunningApplication(processIdentifier: $0.processIdentifier) } != nil
        let terminated = debugState?.hostApplication?.isTerminated == true
        let processState = terminated ? "Terminated" : visible ? "Still running" : "No longer visible to NSWorkspace"
        let reason: String
        if let requested = debugState?.requestedInvalidationReason { reason = requested }
        else if debugState?.wasInterrupted == true { reason = "The connection was interrupted before it became invalid." }
        else if processState == "Still running" { reason = "The host process was still running, so it likely closed or replaced the XPC connection." }
        else { reason = "The host process exited or became unavailable." }
        let lifetime = connectionDiagnostics.connectedDate.map {
            max(0, Date().timeIntervalSince($0)).formatted(.number.locale(.autoupdatingCurrent).precision(.fractionLength(3))) + " seconds"
        } ?? "Unknown"
        return ["Observed cause: \(reason)",
            "Host: \(process?.diagnosticLabel ?? "Unknown host")",
            "Host process: \(processState)",
            "Connection lifetime: \(lifetime)",
            "Handshake completed: \(debugState?.completedHandshake == true ? "Yes" : "No")",
            "Prior interruption: \(debugState?.wasInterrupted == true ? "Yes" : "No")",
            "System reason: NSXPCConnection did not provide an underlying invalidation error."].joined(separator: "\n")
    }
}
