import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothCapture
import PixelBoothCore
import PixelBoothMetadata

public enum SinglePhotoCaptureError: Error, LocalizedError, Equatable, Sendable {
  case invalidTimeout
  case busy
  case noCamera
  case noSupportedMode
  case timedOut(seconds: Int)
  case rejectedFrame(String)
  case streamStopped(String)

  public var errorDescription: String? {
    switch self {
    case .invalidTimeout:
      return
        "Capture timeout must be an integer from 1 through \(SinglePhotoCapture.maximumTimeoutSeconds) seconds."
    case .busy:
      return "A photograph is already being captured."
    case .noCamera:
      return "No external USB camera or built-in camera is available."
    case .noSupportedMode:
      return "The selected camera group has no mode the archival pipeline can preserve."
    case .timedOut(let seconds):
      return "No acceptable photograph was acquired within \(seconds) seconds."
    case .rejectedFrame(let message):
      return "The camera delivered an unsupported or mismatched frame: \(message)"
    case .streamStopped(let message):
      return "Camera delivery stopped: \(message)"
    }
  }
}

/// Pure automatic-selection policy, independent of permissions and hardware.
public enum SinglePhotoSelection {
  public struct Selection: Sendable, Equatable {
    public var camera: CameraDevice
    public var mode: CameraMode
  }

  public static func eligibleCameras(_ cameras: [CameraDevice]) -> [CameraDevice] {
    let connected = cameras.filter(\.deviceConnected)
    let usb = connected.filter(\.isExternalUSB)
    return usb.isEmpty ? connected.filter { $0.kind == .builtIn } : usb
  }

  public static func supports(_ mode: CameraMode) -> Bool {
    guard mode.dimensionsWidth > 0, mode.dimensionsHeight > 0,
      !mode.dimensionsWidth.multipliedReportingOverflow(by: mode.dimensionsHeight).overflow,
      mode.bitsPerChannel.map({ [8, 10, 12].contains($0) }) ?? true,
      CaptureFormatFacts.isConsistent(mode.asCaptureFormat)
    else { return false }
    return PixelFormatFourCC.hasNativePlaneAdapter(mode.pixelFormat)
      || PixelFormatFourCC.isJPEG(mode.pixelFormat) || mode.pixelFormat == PixelFormatFourCC.avc1
  }

  /// Keep authoritative CMIO capabilities for exact representations and add
  /// AVFoundation-only representations. Equal dimensions/FourCC alone do not
  /// establish that two native format descriptions are interchangeable.
  public static func mergeModes(
    cmio: [CameraMode],
    advertised: [(mode: CameraMode, exactFormatIdentity: String)]
  ) -> [CameraMode] {
    cmio
      + advertised.filter { candidate in
        !cmio.contains {
          $0.deviceID == candidate.mode.deviceID && $0.formatID == candidate.exactFormatIdentity
            && $0.minFrameRate == candidate.mode.minFrameRate
            && $0.maxFrameRate == candidate.mode.maxFrameRate
        }
      }.map(\.mode)
  }

  public static func select(
    cameras: [CameraDevice], modesByDevice: [String: [CameraMode]]
  ) throws -> Selection {
    let eligible = eligibleCameras(cameras)
    guard !eligible.isEmpty else { throw SinglePhotoCaptureError.noCamera }
    let candidates = eligible.flatMap { camera in
      (modesByDevice[camera.uniqueID] ?? []).filter {
        $0.deviceID == camera.uniqueID && supports($0)
      }.map { Selection(camera: camera, mode: $0) }
    }
    guard
      let selected = candidates.max(by: {
        ModeSelector.compare($0.mode, $1.mode, rankRGBAsFullColor: true) == .orderedAscending
      })
    else { throw SinglePhotoCaptureError.noSupportedMode }
    return selected
  }
}

/// A deadline race deliberately does not await a cancelled platform call.
/// Camera drivers can stall inside synchronous configuration APIs; cancellation
/// invalidates their configuration token and schedules independent cleanup.
public enum CaptureAcquisitionDeadline {
  public static func run<Value: Sendable>(
    timeoutSeconds: Int,
    onAbort: @escaping @Sendable () -> Void = {},
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    guard (1...SinglePhotoCapture.maximumTimeoutSeconds).contains(timeoutSeconds) else {
      throw SinglePhotoCaptureError.invalidTimeout
    }
    let race = AcquisitionRace<Value>(onAbort: onAbort)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await race.run(timeoutSeconds: timeoutSeconds, operation: operation)
    } onCancel: {
      Task { await race.cancel() }
    }
  }
}

private actor AcquisitionRace<Value: Sendable> {
  private let onAbort: @Sendable () -> Void
  private var continuation: CheckedContinuation<Value, any Error>?
  private var work: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var cancelled = false

  init(onAbort: @escaping @Sendable () -> Void) { self.onAbort = onAbort }

  func run(
    timeoutSeconds: Int, operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    guard !cancelled else { throw CancellationError() }
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      work = Task {
        do {
          let result = try await operation()
          finish(.success(result))
        } catch {
          finish(.failure(error))
        }
      }
      timer = Task {
        do {
          try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
          abort(SinglePhotoCaptureError.timedOut(seconds: timeoutSeconds))
        } catch {
          // A completed/cancelled race owns and cancels its timer.
        }
      }
    }
  }

  func cancel() {
    cancelled = true
    abort(CancellationError())
  }

  private func abort(_ error: any Error) {
    onAbort()
    work?.cancel()
    finish(.failure(error))
  }

  private func finish(_ result: Result<Value, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    work = nil
    continuation.resume(with: result)
  }
}

/// One photograph using the same ingestion, acquisition policy, immutable
/// snapshot and metadata path as the GUI. Authorization belongs to the caller.
public actor SinglePhotoCapture {
  public nonisolated static let maximumTimeoutSeconds = Int(Int64.max / 1_000_000_000)
  private var activeTask: Task<CapturedCapture, any Error>?

  public init() {}

  public func capture(
    timeoutSeconds: Int = 10, includeEstimatedDisparity: Bool = false
  ) async throws -> CapturedCapture {
    guard activeTask == nil else { throw SinglePhotoCaptureError.busy }
    let session = SinglePhotoSession(includeEstimatedDisparity: includeEstimatedDisparity)
    let task = Task.detached {
      try await CaptureAcquisitionDeadline.run(
        timeoutSeconds: timeoutSeconds, onAbort: { session.invalidate() }
      ) {
        try await session.acquire()
      }
    }
    activeTask = task
    defer { activeTask = nil }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func cancel() { activeTask?.cancel() }
}

private actor SinglePhotoSession {
  private let service = CaptureService()
  private let cmio = CMIOCaptureService()
  private let discovery = CaptureDiscovery()
  private let ingest = CaptureFrameIngest()
  private let sinkQueue = DispatchQueue(label: "app.pixelbooth.cli.frames", qos: .userInitiated)
  private let includeEstimatedDisparity: Bool
  private nonisolated let token = CaptureConfigurationToken()
  private let generation = 1

  init(includeEstimatedDisparity: Bool) {
    self.includeEstimatedDisparity = includeEstimatedDisparity
    token.publish(1)
  }

  nonisolated func invalidate() {
    token.publish(0)
    Task { await stop() }
  }

  private func checkActive() throws {
    try Task.checkCancellation()
    guard token.isCurrent(generation) else { throw CancellationError() }
  }

  func acquire() async throws -> CapturedCapture {
    do {
      let capture = try await acquireFrame()
      // A driver stop must not extend acquisition or turn an already-retained
      // photograph into a timeout. Cleanup is requested before returning.
      invalidate()
      return capture
    } catch {
      invalidate()
      throw error
    }
  }

  private func acquireFrame() async throws -> CapturedCapture {
    try checkActive()
    let cameras = await discovery.discoverCameras()
    try checkActive()
    var modes: [String: [CameraMode]] = [:]
    for camera in SinglePhotoSelection.eligibleCameras(cameras) {
      let id = camera.uniqueID
      modes[id] = await Task.detached(priority: .userInitiated) {
        let cmio = CMIOCaptureDiscovery.modes(deviceUID: id)
        guard let device = AVCaptureDevice(uniqueID: id) else { return cmio }
        let formats = device.formats
        let advertised = CaptureDiscovery.advertisedModes(for: device, formats: formats)
        return SinglePhotoSelection.mergeModes(
          cmio: cmio,
          advertised: zip(advertised, formats).map { mode, format in
            (mode, CMIOCaptureDiscovery.formatIdentity(format.formatDescription))
          })
      }.value
      try checkActive()
    }
    let selected = try SinglePhotoSelection.select(cameras: cameras, modesByDevice: modes)
    let id = selected.camera.uniqueID
    let requestedRate = selected.mode.maxFrameRate > 0 ? selected.mode.maxFrameRate : nil
    await service.addSink(ingest, queue: sinkQueue)
    await cmio.addSink(ingest, queue: sinkQueue)
    try checkActive()

    let (mode, rate, backend) = try await configure(
      deviceID: id, mode: selected.mode, requestedRate: requestedRate)
    let interval: UInt64 = {
      guard let rate, rate.isFinite, rate > 0,
        1_000_000_000 / rate < Double(UInt64.max)
      else { return 0 }
      return UInt64(1_000_000_000 / rate)
    }()
    await ingest.beginConfiguration(
      deviceID: id, generation: generation, frameIntervalNanos: interval,
      expectedFormat: mode.asCaptureFormat)
    try checkActive()
    if backend == "CoreMediaIO" {
      try await cmio.start(expectedGeneration: generation, operationToken: token)
    } else {
      try await service.start(expectedGeneration: generation, operationToken: token)
    }
    while true {
      try checkActive()
      if let stop = ingest.stoppedStream {
        throw SinglePhotoCaptureError.streamStopped(String(describing: stop.reason))
      }
      if let failure = ingest.lastFailureMessage {
        throw SinglePhotoCaptureError.rejectedFrame(failure)
      }
      if await ingest.currentReadiness() == .ready,
        let frame = await ingest.newestFreshFrame(timeoutNanos: 0)
      {
        let evidence = try AcquisitionPolicy.evaluate(
          deviceUniqueID: frame.deviceUniqueID, generation: frame.generation,
          expectedDeviceID: id, expectedGeneration: generation,
          selected: mode.asCaptureFormat, delivered: deliveredFormat(frame))
        var metadata = await ingest.snapshotMetadata(for: frame)
        metadata.hostLocation = nil
        metadata.includeEstimatedDisparity = includeEstimatedDisparity
        metadata.hostObservedDeviceMake = selected.camera.manufacturer
        metadata.hostObservedDeviceModel = selected.camera.localizedName
        metadata.hostObservedDeviceModelID = selected.camera.modelID
        metadata.usbIdentity = selected.camera.usbIdentity
        metadata.deviceIdentity = DeviceIdentityResolution.resolve(
          manufacturer: selected.camera.manufacturer, model: selected.camera.localizedName,
          usb: selected.camera.usbIdentity)
        metadata.captureBackend = backend
        metadata.captureBackendVersion = ProcessInfo.processInfo.operatingSystemVersionString
        try checkActive()
        return try CapturedCapture(from: frame, metadata: metadata, acquisitionEvidence: evidence)
      }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  private func deliveredFormat(_ frame: DeliveredFrame) -> CaptureFormat {
    if let pixel = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
      return CaptureFormat(
        width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel),
        fourCC: CVPixelBufferGetPixelFormatType(pixel))
    }
    return CaptureFormat(width: frame.width, height: frame.height, fourCC: frame.fourCC)
  }

  private func configure(
    deviceID: String, mode: CameraMode, requestedRate: Double?
  ) async throws -> (CameraMode, Double?, String) {
    // AVFoundation-only entries retain numeric format indices. Sending one
    // through CMIO's geometry/FourCC matcher could substitute a different
    // native description, so only exact CMIO fingerprints use that backend.
    if mode.formatID?.hasPrefix("cmio-") == true {
      do {
        _ = try await cmio.configure(
          deviceUniqueID: deviceID, mode: mode, requestedFrameRate: requestedRate,
          generation: generation, operationToken: token)
        try checkActive()
        return (await cmio.configuredMode ?? mode, await cmio.configuredFrameRate, "CoreMediaIO")
      } catch {
        try checkActive()
      }
    }
    _ = try await service.configure(
      deviceUniqueID: deviceID, mode: mode, requestedFrameRate: requestedRate,
      generation: generation, operationToken: token)
    try checkActive()
    return (mode, await service.configuredFrameRate, "AVFoundation")
  }

  private func stop() async {
    token.publish(0)
    await ingest.invalidateConfiguration()
    await cmio.stop()
    await service.stop()
    await cmio.removeSink(ingest)
    await service.removeSink(ingest)
  }
}
