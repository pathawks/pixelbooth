// H.264 input is decoded continuously in delivery order. The compressed
// camera samples are retained only as short-lived decoder input/metadata;
// only reconstructed pixel samples enter CapturedCapture and lossless AVIF.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothAdapters
import PixelBoothCapture
import PixelBoothCore
import VideoToolbox

public final class H264VideoToolboxStreamDecoder: @unchecked Sendable {
  public enum DecodeError: Error, LocalizedError, Sendable {
    case wrongCodec
    case formatUnavailable
    case sessionCreation(OSStatus)
    case decode(OSStatus)
    case outputUnavailable
    case unsupportedOutput(UInt32)
    case invalidDimensions

    public var errorDescription: String? {
      switch self {
      case .wrongCodec: return "The delivered sample is not an H.264 image."
      case .formatUnavailable: return "The H.264 sample has no decoder format description."
      case .sessionCreation(let status):
        return "VideoToolbox could not create an H.264 decoder (\(status))."
      case .decode(let status): return "VideoToolbox could not decode this frame (\(status))."
      case .outputUnavailable: return "VideoToolbox produced no reconstructed image."
      case .unsupportedOutput(let fourCC):
        return
          "VideoToolbox delivered unsupported pixel format \(CaptureFormat.fourCCString(fourCC))."
      case .invalidDimensions: return "VideoToolbox returned invalid image dimensions."
      }
    }
  }

  /// One reconstructed image with the compressed input sample that owns its
  /// presentation timestamp. Buffer and sample references remain immutable.
  public struct DecodedOutput: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let sourceFrame: DeliveredFrame
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
  }

  private struct OutputEvent {
    var status: OSStatus
    var pixelBuffer: CVPixelBuffer?
    var presentationTimeStamp: CMTime
    var duration: CMTime
  }

  private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [OutputEvent] = []

    func reset() {
      lock.lock()
      events.removeAll(keepingCapacity: true)
      lock.unlock()
    }

    func append(_ event: OutputEvent) {
      lock.lock()
      events.append(event)
      lock.unlock()
    }

    func takeEvents() -> [OutputEvent] {
      lock.lock()
      defer { lock.unlock() }
      let result = events
      events.removeAll(keepingCapacity: true)
      return result
    }
  }

  /// This callback is intentionally capture-free; its reference context points
  /// to `outputBox`, which lives as long as the decoder session.
  private static let outputCallback: VTDecompressionOutputCallback = {
    refCon, _, status, _, imageBuffer, presentationTimeStamp, duration in
    guard let refCon else { return }
    Unmanaged<OutputBox>.fromOpaque(refCon).takeUnretainedValue().append(
      OutputEvent(
        status: status, pixelBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp, duration: duration))
  }

  // All mutable decoder state is confined to the caller's serial processing
  // queue. FrameIngest creates one decoder per window and resets it between
  // device/generation changes.
  private let outputBox = OutputBox()
  private var session: VTDecompressionSession?
  private var formatDescription: CMFormatDescription?
  private var pendingFrames: [UInt64: DeliveredFrame] = [:]
  private var pendingOrder: [UInt64] = []
  private let maximumPendingFrames = 48

  public init() {}

  deinit { invalidate() }

  public func invalidate() {
    if let session {
      VTDecompressionSessionInvalidate(session)
      self.session = nil
    }
    formatDescription = nil
    pendingFrames.removeAll(keepingCapacity: false)
    pendingOrder.removeAll(keepingCapacity: false)
    outputBox.reset()
  }

  /// Accept one compressed source sample. Call serially in source decode order;
  /// VideoToolbox can return zero, one, or several display-order images as its
  /// reference/reorder queue advances.
  public func decode(_ frame: DeliveredFrame) throws -> [DecodedOutput] {
    guard
      frame.sourceFourCC == PixelFormatFourCC.avc1
        || frame.fourCC == PixelFormatFourCC.avc1
    else { throw DecodeError.wrongCodec }
    guard CMSampleBufferDataIsReady(frame.sampleBuffer),
      let format = CMSampleBufferGetFormatDescription(frame.sampleBuffer)
    else { throw DecodeError.formatUnavailable }
    guard CMFormatDescriptionGetMediaSubType(format) == PixelFormatFourCC.avc1 else {
      throw DecodeError.wrongCodec
    }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    guard dimensions.width > 0, dimensions.height > 0 else {
      throw DecodeError.invalidDimensions
    }
    try ensureSession(format: format)

    let frameKey = frame.timestampNanos > 0 ? frame.timestampNanos : frame.hostMonotonicNanos
    pendingFrames[frameKey] = frame
    pendingOrder.append(frameKey)
    outputBox.reset()

    guard let session else { throw DecodeError.outputUnavailable }
    var infoFlags = VTDecodeInfoFlags()
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: frame.sampleBuffer,
      flags: VTDecodeFrameFlags(rawValue: 0),
      frameRefcon: nil, infoFlagsOut: &infoFlags)
    guard status == noErr else {
      pendingFrames.removeValue(forKey: frameKey)
      pendingOrder.removeAll { $0 == frameKey }
      throw DecodeError.decode(status)
    }
    var decoded: [DecodedOutput] = []
    for event in outputBox.takeEvents() {
      guard event.status == noErr else { throw DecodeError.decode(event.status) }
      guard let pixelBuffer = event.pixelBuffer else { throw DecodeError.outputUnavailable }
      guard CVPixelBufferGetWidth(pixelBuffer) == Int(dimensions.width),
        CVPixelBufferGetHeight(pixelBuffer) == Int(dimensions.height)
      else { throw DecodeError.invalidDimensions }
      let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
      guard FrameExtraction.supportedPixelFormats.contains(pixelFormat) else {
        throw DecodeError.unsupportedOutput(pixelFormat)
      }

      let sourceKey = sourceKey(for: event.presentationTimeStamp)
      guard let sourceKey, let sourceFrame = pendingFrames.removeValue(forKey: sourceKey) else {
        throw DecodeError.outputUnavailable
      }
      pendingOrder.removeAll { $0 == sourceKey }
      decoded.append(
        DecodedOutput(
          pixelBuffer: pixelBuffer, sourceFrame: sourceFrame,
          presentationTimeStamp: event.presentationTimeStamp, duration: event.duration))
    }

    guard pendingFrames.count <= maximumPendingFrames else {
      invalidate()
      throw DecodeError.outputUnavailable
    }
    return decoded
  }

  private func ensureSession(format: CMFormatDescription) throws {
    if let active = formatDescription, CFEqual(active, format), session != nil { return }
    invalidate()
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: Self.outputCallback,
      decompressionOutputRefCon: Unmanaged.passUnretained(outputBox).toOpaque())
    let outputAttributes: CFDictionary =
      [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ] as CFDictionary
    var createdSession: VTDecompressionSession?
    var status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: format,
      decoderSpecification: nil,
      imageBufferAttributes: outputAttributes,
      outputCallback: &callback,
      decompressionSessionOut: &createdSession)
    if status != noErr {
      // Some macOS virtualized/test hosts expose a VideoToolbox decoder
      // component that fails during session creation. Retry with hardware
      // acceleration explicitly disabled so the supported software decoder
      // can preserve the same decoded samples.
      let softwareOnly =
        NSDictionary(
          object: kCFBooleanFalse as Any,
          forKey: kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as NSString)
        as CFDictionary
      status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: format,
        decoderSpecification: softwareOnly,
        imageBufferAttributes: outputAttributes,
        outputCallback: &callback,
        decompressionSessionOut: &createdSession)
    }
    guard status == noErr, let createdSession else { throw DecodeError.sessionCreation(status) }
    session = createdSession
    formatDescription = format
  }

  private func sourceKey(for presentationTime: CMTime) -> UInt64? {
    guard presentationTime.isNumeric else { return nil }
    return pendingOrder.first { key in
      guard let frame = pendingFrames[key] else { return false }
      let sample = frame.sourceSampleBuffer ?? frame.sampleBuffer
      let sourceTime = CMSampleBufferGetPresentationTimeStamp(sample)
      return sourceTime.isNumeric && CMTimeCompare(sourceTime, presentationTime) == 0
    }
  }

  private static func timestampNanos(_ time: CMTime) -> UInt64? {
    guard time.isNumeric else { return nil }
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, seconds >= 0 else { return nil }
    return UInt64(seconds * 1_000_000_000)
  }
}
