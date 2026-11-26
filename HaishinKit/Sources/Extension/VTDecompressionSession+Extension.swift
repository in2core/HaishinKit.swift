import Foundation
import VideoToolbox

extension VTDecompressionSession: VTSessionConvertible {
    static let defaultDecodeFlags: VTDecodeFrameFlags = [
        ._EnableAsynchronousDecompression,
        ._EnableTemporalProcessing
    ]

    @inline(__always)
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: AsyncStream<CMSampleBuffer>.Continuation?) throws {
        var flagsOut: VTDecodeInfoFlags = []
        var _: VTEncodeInfoFlags = []
        let sourceFormat = sampleBuffer.formatDescription
        let status = VTDecompressionSessionDecodeFrame(
            self,
            sampleBuffer: sampleBuffer,
            flags: Self.defaultDecodeFlags,
            infoFlagsOut: &flagsOut,
            outputHandler: { status, _, imageBuffer, presentationTimeStamp, duration in
                guard let imageBuffer else {
                    return
                }
                var status = noErr
                var outputFormat: CMFormatDescription?
                status = CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: imageBuffer,
                    formatDescriptionOut: &outputFormat
                )
                guard let outputFormat, status == noErr else {
                    return
                }
                var timingInfo = CMSampleTimingInfo(
                    duration: duration,
                    presentationTimeStamp: presentationTimeStamp,
                    decodeTimeStamp: .invalid
                )
                var sampleBuffer: CMSampleBuffer?
                status = CMSampleBufferCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: imageBuffer,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: outputFormat,
                    sampleTiming: &timingInfo,
                    sampleBufferOut: &sampleBuffer
                )
                if let sampleBuffer {
                    if let sourceFormat {
                        CMSetAttachment(sampleBuffer, key: "org.haishinkit.sourceVideoFormatDescription" as CFString,
                                        value: sourceFormat, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
                    }
                    continuation?.yield(sampleBuffer)
                }
            }
        )
        if status != noErr {
            throw VTSessionError.failedToConvert(status: status)
        }
    }

    func invalidate() {
        VTDecompressionSessionInvalidate(self)
    }
}
