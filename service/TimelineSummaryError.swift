import Foundation

// Errors of the memory summary pipeline. The execution and timeout cases
// describe a `codex exec` summariser; without one, ACUA reports
// summariesUnavailable.
struct ProcessOutput: Equatable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

enum TimelineSummaryError: Error, CustomStringConvertible {
    case codexExecFailed(String)
    case codexExecTimedOut(ProcessOutput?)
    case invalidChildSummary(String)
    case invalidSummaryDirectory
    case invalidSummarizationModel
    case missingFinalMessage
    case summariesUnavailable

    var description: String {
        switch self {
        case .codexExecFailed(let detail): return "codex exec failed: " + detail
        case .codexExecTimedOut: return "codex exec timed out."
        case .invalidChildSummary(let filename): return "invalid child summary: " + filename
        case .invalidSummaryDirectory: return "invalid summary directory."
        case .invalidSummarizationModel: return "memories.consolidation_model must be a non-empty model name."
        case .missingFinalMessage: return "codex exec did not emit a final agent message."
        case .summariesUnavailable: return "memory summaries are not available in ACUA."
        }
    }
}
