import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Baseline 3.1, ~2.5 Mbps, 1 s GOP: what the dash decoders accept (see the reference notes §5).
/// Output is Annex-B with SPS/PPS prepended to every keyframe so the dash can start mid-stream.
public final class H264Encoder {
    public let width: Int
    public let height: Int
    private var session: VTCompressionSession?
    public var onAccessUnit: ((Data, Bool) -> Void)?
    private var forceKey = true

    public init(width: Int, height: Int, fps: Int = 30, bitrate: Int = 2_500_000) throws {
        self.width = width
        self.height = height
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw EasyConnError.encoder("create: \(st)") }
        session = s
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(s, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_3_1)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    public func invalidate() {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
    }

    /// Next frame will be an IDR (with SPS/PPS).
    public func requestKeyFrame() { forceKey = true }

    /// Returns the VideoToolbox status; non-zero after iOS takes the hardware encoder back (screen lock).
    @discardableResult
    public func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) -> OSStatus {
        guard let session else { return kVTInvalidSessionErr }
        var props: CFDictionary?
        if forceKey {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKey = false
        }
        return VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            if let (au, key) = Self.annexB(sample) { self.onAccessUnit?(au, key) }
        }
    }

    static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        var nalHeaderLen: Int32 = 4
        if isKey {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: &nalHeaderLen)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    out.append(contentsOf: start)
                    out.append(ptr, count: size)
                }
            }
        }
        var length = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &base) == noErr, let base else { return nil }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self), count: length)
        var i = 0
        let n = Int(nalHeaderLen)
        while i + n <= length {
            var nalLen = 0
            for k in 0..<n { nalLen = nalLen << 8 | Int(bytes[i + k]) }
            i += n
            guard nalLen > 0, i + nalLen <= length else { break }
            // Drop SEI (type 6): VideoToolbox adds one, MediaCodec — the encoder the dashes were tested with — does not.
            if bytes[i] & 0x1f == 6 { i += nalLen; continue }
            out.append(contentsOf: start)
            out.append(UnsafeBufferPointer(rebasing: bytes[i..<i + nalLen]))
            i += nalLen
        }
        return (out, isKey)
    }
}
