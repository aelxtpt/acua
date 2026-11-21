import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct RemoteHostedPIPVideoFrame: Sendable {
    static let codec = "hvc1.1.6.L93.B0"
    let videoData: Data
    let decoderConfiguration: Data?
    let timestamp: UInt64
    let isKeyFrame: Bool
}

final class RemoteHostedPIPVideoEncoder {
    enum Failure: Error {
        case invalidDimensions
        case videoToolbox(OSStatus)
        case missingSample
    }

    let sourceWidth: Int
    let sourceHeight: Int
    let maxPixelDimension: Int
    private let session: VTCompressionSession

    init(source: CVPixelBuffer, maxPixelDimension: Int) throws {
        sourceWidth = CVPixelBufferGetWidth(source)
        sourceHeight = CVPixelBufferGetHeight(source)
        self.maxPixelDimension = maxPixelDimension
        guard sourceWidth > 0, sourceHeight > 0, (2...720).contains(maxPixelDimension) else {
            throw Failure.invalidDimensions
        }
        let scale = min(1, Double(maxPixelDimension) / Double(max(sourceWidth, sourceHeight)))
        let width = Int32(max(2, Int((Double(sourceWidth) * scale).rounded()) & ~1))
        let height = Int32(max(2, Int((Double(sourceHeight) * scale).rounded()) & ~1))
        let specification = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_HEVCWithAlpha, encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw Failure.videoToolbox(status) }
        session = created
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PreserveAlphaChannel, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 4_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TargetQualityForAlpha, value: 0.95 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { VTCompressionSessionInvalidate(session) }

    func encode(_ pixels: CVPixelBuffer,
                completion: @escaping @Sendable (Result<RemoteHostedPIPVideoFrame, Error>) -> Void) throws {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let time = CMTime(value: Int64(clamping: timestamp), timescale: 1_000_000_000)
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time,
                                                     duration: .invalid, frameProperties: nil, infoFlagsOut: nil) {
            status, flags, sample in
            completion(Result {
                guard status == noErr else { throw Failure.videoToolbox(status) }
                guard !flags.contains(.frameDropped), let sample else { throw Failure.missingSample }
                return try Self.packet(from: sample)
            })
        }
        guard status == noErr else { throw Failure.videoToolbox(status) }
    }

    private static func packet(from sample: CMSampleBuffer) throws -> RemoteHostedPIPVideoFrame {
        guard let block = sample.dataBuffer, let format = sample.formatDescription, block.dataLength > 0,
              let timestamp = UInt64(exactly: (sample.presentationTimeStamp.seconds * 1_000_000_000).rounded(.towardZero)) else {
            throw Failure.missingSample
        }
        var data = Data(count: block.dataLength)
        let status = data.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard status == noErr else { throw Failure.videoToolbox(status) }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any]
        return RemoteHostedPIPVideoFrame(videoData: data, decoderConfiguration: isKeyFrame ? atoms?["hvcC"] as? Data : nil,
                                         timestamp: timestamp, isKeyFrame: isKeyFrame)
    }
}
