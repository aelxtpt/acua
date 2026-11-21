import CryptoKit
import Foundation
import MCP

enum CUAMCPDomain: String, CaseIterable, Sendable {
    case automation, eventStream = "event-stream", history = "computer-history", calendar, messages

    var serverName: String {
        switch self {
        case .automation: "Computer Use"
        case .eventStream: "Record & Replay"
        case .history: "Computer History"
        case .calendar: "Calendar"
        case .messages: "Messages"
        }
    }
}

struct CUAMCPToolCatalog: Sendable {
    let domain: CUAMCPDomain
    let tools: [Tool]

    init(domain: CUAMCPDomain, definitions: Data) throws {
        let catalogs = try JSONDecoder().decode([String: [Tool]].self, from: definitions)
        guard let tools = catalogs[domain.rawValue], !tools.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.domain = domain
        self.tools = tools
    }

    var definitionVersion: String {
        get throws {
            struct Input: Encodable { let ipcProtocolVersion: Int?; let tools: [Tool] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            switch domain {
            case .calendar: data = try encoder.encode(tools)
            case .automation, .messages: data = try encoder.encode(Input(ipcProtocolVersion: 2, tools: tools))
            case .eventStream, .history: data = try encoder.encode(Input(ipcProtocolVersion: nil, tools: tools))
            }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
