import Foundation

/// Only the requested output type and sample
/// validity gate delivery. Readiness and frame-status attachments are not gates.
struct PIPCaptureCallbacks<Sample: Sendable>: Sendable {
    let outputType: Int
    let isValid: @Sendable (Sample) -> Bool
    let sampleHandler: @Sendable (Sample) -> Void
    let errorHandler: @Sendable (any Error) -> Void

    func receive(_ sample: Sample, type: Int) {
        guard type == outputType, isValid(sample) else { return }
        sampleHandler(sample)
    }
    func failed(_ error: any Error) { errorHandler(error) }
}
