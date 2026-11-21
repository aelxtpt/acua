import Foundation
import ScreenCaptureKit

struct PIPCapturedSample: @unchecked Sendable { let sample: CMSampleBuffer }

/// The native CaptureStream wrapper. Unlike the former AsyncStream adapter,
/// this retains every valid sample through the renderer's main-queue dispatch.
final class PIPCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private static let queue = DispatchQueue(label: (Bundle.main.bundleIdentifier ?? "unknown") + ".CaptureStream")
    private var stream: SCStream!
    private let outputType: SCStreamOutputType
    private let callbacks: PIPCaptureCallbacks<PIPCapturedSample>

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, outputType: SCStreamOutputType = .screen,
         sampleHandler: @escaping @Sendable (PIPCapturedSample) -> Void,
         errorHandler: @escaping @Sendable (any Error) -> Void) {
        self.outputType = outputType
        callbacks = .init(outputType: outputType.rawValue, isValid: { $0.sample.isValid },
                          sampleHandler: sampleHandler, errorHandler: errorHandler)
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    }
    func start() async throws {
        try stream.addStreamOutput(self, type: outputType, sampleHandlerQueue: Self.queue)
        try await stream.startCapture()
    }
    func stop() async throws { try await stream.stopCapture() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        callbacks.receive(.init(sample: sample), type: type.rawValue)
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { callbacks.failed(error) }
}
