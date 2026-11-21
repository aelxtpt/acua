import Foundation

struct ComputerUseIPCForegroundContext: Codable, Equatable, Sendable {
    let processIdentifier: Int32
    let windowID: UInt32?
    let appName: String
    let bundleIdentifier: String
    let windowTitle: String?
}

struct ComputerUseIPCForegroundUpdate: Codable, Equatable, Sendable {
    let observedAt: Date
    let context: ComputerUseIPCForegroundContext?
}
