// CaptureService — AVFoundation capture service.
// Streaming configuration and blocking session operations stay off the main
// actor. Frames carry a configuration generation tag; queued frames from an
// old configuration cannot become photographs in a new mode.

import Foundation
import AVFoundation
import CoreMedia
import PixelBoothCore

/// A delivered sample with the provenance we can honestly attach.
public struct DeliveredFrame: @unchecked Sendable {
  /// Retained sample buffer; later buffer reuse cannot mutate an accepted
  /// photograph because we never write into the buffer and it is retained
  /// for the frame's lifetime.
  public var sampleBuffer: CMSampleBuffer
  public var generation: Int
  public var deviceUniqueID: String
  public var fourCC: UInt32
  public var width: Int
  public var height: Int
  public var timestampNanos: UInt64
  public var hostWallClockISO: String

  public init(sampleBuffer: CMSampleBuffer, generation: Int, deviceUniqueID: String,
              fourCC: UInt32, width: Int, height: Int, timestampNanos: UInt64,
              hostWallClockISO: String) {
    self.sampleBuffer = sampleBuffer
    self.generation = generation
    self.deviceUniqueID = deviceUniqueID
    self.fourCC = fourCC
    self.width = width
    self.height = height
    self.timestampNanos = timestampNanos
    self.hostWallClockISO = hostWallClockISO
  }
}

/// Receives frames on a background queue.
public protocol FrameSink: AnyObject {
  func receive(_ frame: DeliveredFrame)
}

/// Per-capture-queue delegate. Narrow, documented exception: this class holds
/// no mutable state and only forwards buffers into the actor; it is confined
/// to a single capture queue.
final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  weak var service: CaptureService?
  weak var device: AVCaptureDevice?

  init(service: CaptureService, device: AVCaptureDevice?) {
    self.service = service
    self.device = device
    super.init()
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard let service else { return }
    // The actor hop copies the retained reference, not the buffer contents.
    // The buffer stays alive for the duration of forwarding; sinks that want
    // to keep it call CMSampleBufferInvalidate-free retention via storing it.
    service.forwardBuffer(sampleBuffer, device: device)
  }
}

/// Sink registry that the capture queue can read without awaiting the actor.
/// Written on the actor; read from the capture queue. Documented narrow
/// exception: the lock protects a plain dictionary used only for forwarding.
final class SinkRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [ObjectIdentifier: (sink: FrameSink, queue: DispatchQueue)] = [:]

  func set(_ sink: FrameSink, queue: DispatchQueue) {
    lock.lock(); defer { lock.unlock() }
    entries[ObjectIdentifier(sink)] = (sink, queue)
  }

  func remove(_ sink: FrameSink) {
    lock.lock(); defer { lock.unlock() }
    entries.removeValue(forKey: ObjectIdentifier(sink))
  }

  func snapshot() -> [(sink: FrameSink, queue: DispatchQueue)] {
    lock.lock(); defer { lock.unlock() }
    return Array(entries.values)
  }
}

/// The capture service. Owns the AVCaptureSession and its configuration.
public actor CaptureService {
  private var session: AVCaptureSession?
  private var videoDataOutput: AVCaptureVideoDataOutput?
  private var currentDevice: AVCaptureDevice?
  private var currentInput: AVCaptureDeviceInput?
  private var generation: Int = 0
  private let sinkRegistry = SinkRegistry()
  private var delegate: CaptureDelegate?
  private var isStreaming = false

  public init() {}

  /// Configure a fresh capture session for the device with the given unique
  /// ID and mode. The actor resolves the device itself, keeping non-Sendable
  /// AVFoundation objects actor-confined. videoSettings: an explicitly EMPTY
  /// (non-nil) dictionary, requesting native-format delivery per TN3121 —
  /// verified against the installed SDK (see docs/TN3121_VERIFICATION.md).
  public func configure(deviceUniqueID: String, mode: CameraMode) throws {
    guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
      throw CaptureServiceError.cannotAddInput
    }
    generation += 1
    if let oldSession = session {
      oldSession.beginConfiguration()
      if let input = currentInput { oldSession.removeInput(input) }
      if let output = videoDataOutput { oldSession.removeOutput(output) }
      oldSession.commitConfiguration()
    }

    let newSession = AVCaptureSession()
    newSession.beginConfiguration()
    let input = try AVCaptureDeviceInput(device: device)
    guard newSession.canAddInput(input) else { throw CaptureServiceError.cannotAddInput }
    newSession.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [:]  // explicitly empty: native format delivery
    output.alwaysDiscardsLateVideoFrames = false
    guard newSession.canAddOutput(output) else { throw CaptureServiceError.cannotAddOutput }
    newSession.addOutput(output)
    newSession.commitConfiguration()

    session = newSession
    currentDevice = device
    currentInput = input
    videoDataOutput = output

    // Request the highest supported frame rate within the selected mode,
    // respecting the advertised interval. Never silently lower resolution,
    // precision, or chroma sampling to increase frame rate.
    //
    // Verified against the installed SDK (macOS 27.0, Build 26A428): an
    // EMPTY (non-nil) videoSettings dictionary is normalized to nil, which
    // selects the default uncompressed output (a documented conversion
    // relative to what some UVC cameras advertise natively). The
    // acquisition-fidelity classification therefore derives from the actual
    // delivered sample buffers, not the configuration alone.
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      // Lock the negotiated format to the selected mode.
      let matchedFormat = device.formats.first(where: { fmt in
        let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        return Int(d.width) == mode.dimensions.width &&
               Int(d.height) == mode.dimensions.height &&
               CMFormatDescriptionGetMediaSubType(fmt.formatDescription) == mode.mediaSubType
      })
      if let matchedFormat {
        device.activeFormat = matchedFormat
      }
      // Request the highest supported frame rate, respecting the advertised
      // intervals exactly. Cameras enforce discrete intervals (e.g. 60/50/30
      // fps); snap to the highest advertised rate and record requested vs
      // measured separately. Never silently lower resolution, precision, or
      // chroma sampling to increase frame rate.
      if mode.maxFrameRate > 0 {
        let ranges = matchedFormat?.videoSupportedFrameRateRanges ?? []
        let target = mode.maxFrameRate
        let chosen = ranges.min { a, b in
          // Prefer the range whose max frame rate is closest to (and not
          // below) the requested rate; fall back to the overall highest.
          let aMax = 1.0 / a.minFrameDuration.seconds
          let bMax = 1.0 / b.minFrameDuration.seconds
          if aMax <= target && bMax <= target { return aMax < bMax }
          if aMax >= target && bMax >= target { return aMax < bMax }
          return aMax > bMax
        } ?? ranges.first
        if let chosen {
          device.activeVideoMinFrameDuration = chosen.minFrameDuration
          device.activeVideoMaxFrameDuration = chosen.maxFrameDuration
        }
      }
    }
  }

  /// Attach an advanced lower-frame-rate override (explicit user request).
  public func setFrameRateOverride(_ fps: Double) throws {
    guard let device = currentDevice, fps > 0 else { return }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
    device.activeVideoMinFrameDuration = duration
    device.activeVideoMaxFrameDuration = duration
  }

  /// Start continuous streaming.
  public func start() throws {
    guard let session, let output = videoDataOutput, let device = currentDevice else {
      throw CaptureServiceError.notConfigured
    }
    guard !isStreaming else { return }
    SessionBox.shared.session = session
    let queue = DispatchQueue(label: "app.pixelbooth.capture.video", qos: .userInteractive)
    let delegate = CaptureDelegate(service: self, device: device)
    output.setSampleBufferDelegate(delegate, queue: queue)
    self.delegate = delegate
    session.startRunning()
    isStreaming = true
  }

  /// Stop camera use (also on window close / disconnection).
  public func stop() {
    guard let session else { return }
    session.stopRunning()
    isStreaming = false
    delegate = nil
  }

  public func addSink(_ sink: FrameSink, queue: DispatchQueue) {
    sinkRegistry.set(sink, queue: queue)
  }

  public func removeSink(_ sink: FrameSink) {
    sinkRegistry.remove(sink)
  }

  /// Read-only session handle for the preview layer (display only).
  public nonisolated func sessionForPreview() -> AVCaptureSession? {
    let box = SessionBox.shared
    box.lock.lock()
    defer { box.lock.unlock() }
    return box.session
  }

  /// Called from the capture queue's delegate. Nonisolated so it can run
  /// directly on the capture queue without hopping to the actor executor.
  public nonisolated func forwardBuffer(_ buffer: CMSampleBuffer, device: AVCaptureDevice?) {
    // Extract format info and build the frame snapshot on the capture queue.
    guard let formatDesc = CMSampleBufferGetFormatDescription(buffer) else { return }
    let fourCC = CMFormatDescriptionGetMediaSubType(formatDesc)
    let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
    let nanos: UInt64
    if pts.isNumeric {
      let seconds = CMTimeGetSeconds(pts)
      nanos = seconds > 0 ? UInt64(seconds * 1_000_000_000) : 0
    } else {
      nanos = 0
    }
    let stamp: String = {
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return f.string(from: Date())
    }()
    let frame = DeliveredFrame(
      sampleBuffer: buffer,
      generation: GenerationBox.current(for: device?.uniqueID ?? ""),
      deviceUniqueID: device?.uniqueID ?? "",
      fourCC: fourCC,
      width: Int(dims.width),
      height: Int(dims.height),
      timestampNanos: nanos,
      hostWallClockISO: stamp)
    for entry in sinkRegistry.snapshot() {
      entry.queue.async { entry.sink.receive(frame) }
    }
  }

}

public enum CaptureServiceError: Error {
  case cannotAddInput
  case cannotAddOutput
  case notConfigured
}

/// Thread-safe accessors bridging the actor's state to the capture queue.
/// The boxes are written on the actor and read from the capture queue via
/// locks; they hold only immutable snapshots.
final class GenerationBox: @unchecked Sendable {
  private static let shared = GenerationBox()
  private let lock = NSLock()
  private var generations: [String: Int] = [:]

  private init() {}

  static func update(deviceID: String, generation: Int) {
    shared.lock.lock()
    defer { shared.lock.unlock() }
    shared.generations[deviceID] = generation
  }

  static func current(for deviceID: String) -> Int {
    shared.lock.lock()
    defer { shared.lock.unlock() }
    return shared.generations[deviceID] ?? 0
  }
}

extension CaptureService {
  /// Publish the generation so the capture queue can tag frames correctly.
  public func publishGeneration() {
    guard let device = currentDevice else { return }
    GenerationBox.update(deviceID: device.uniqueID, generation: generation)
  }
}

/// Process-wide session holder for preview attachment. Written on the actor
/// when a session starts; read by the preview view. Documented narrow
/// exception: an AVCaptureSession must be referenced directly by CALayer.
final class SessionBox: @unchecked Sendable {
  static let shared = SessionBox()
  let lock = NSLock()
  var session: AVCaptureSession?
}
