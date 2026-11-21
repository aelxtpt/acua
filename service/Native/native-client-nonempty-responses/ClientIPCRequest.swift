import Foundation

protocol ComputerUseIPCRequest: Codable {
    associatedtype Response: Codable
}

struct ComputerUseIPCTurnEndedResponse: Codable {}
extension ComputerUseIPCTurnEndedRequest: ComputerUseIPCRequest {
    typealias Response = ComputerUseIPCTurnEndedResponse
}
