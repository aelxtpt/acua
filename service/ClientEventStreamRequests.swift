import Foundation

struct ComputerUseIPCEventStreamStartRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCEventStreamSessionStatus
}

struct ComputerUseIPCEventStreamStopRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = ComputerUseIPCEventStreamSessionStatus
    let reason: ComputerUseIPCEventStreamEndReason
}
