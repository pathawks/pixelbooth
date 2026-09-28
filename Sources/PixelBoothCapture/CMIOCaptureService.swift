// CMIOCaptureService — CoreMediaIO HAL capture backend.
//
// AVFoundation on macOS 27 pins the CMIO stream format of a device to its
// default the moment an AVCaptureSession runs and never honors activeFormat
// or any session preset (docs/TN3121_VERIFICATION.md, findings 3–4). The
// public CoreMediaIO HAL exposes the device's advertised formats on its
// stream, and the stream format property is settable — so mode selection is
// reachable here. Verified on macOS 27.0 Build 26A428: the built-in camera
// delivered 1552×1552 `420v` natively through CMIO while AVFoundation pinned
// 1920×1080.
//
// Ownership discipline: the actor owns device/stream/format state; frames are
// forwarded to sinks off the actor through the shared SinkRegistry; the
// poller is a narrow, documented @unchecked Sendable exception.

import AVFoundation
import CoreMedia
import CoreMediaIO
import Foundation
import PixelBoothCore
import os

private let cmioLog = Logger(subsystem: "app.pixelbooth", category: "cmio")

/// Queue-altered callback context: signals the poller's semaphore when the
/// CMIO stream inserts a buffer. Owned by the poller; the callback holds the
/// poller weakly so a callback racing teardown is a no-op.
final class CMIOQueueSignalBox: @unchecked Sendable {
  // Narrow documented exception: the lock protects the weak poller reference
  // against detach-time teardown; signaling is a DispatchSemaphore operation.
  private let lock = NSLock()
  private weak var poller: CMIOFramePoller?

  init(poller: CMIOFramePoller) { self.poller = poller }

  func signal() {
    lock.lock()
    let target = poller
    lock.unlock()
    target?.signal()
  }
}

/// Queue-altered callback (C function pointer): signals the poller.
private func cmioQueueAltered(
  _ streamID: CMIOStreamID, _ token: UnsafeMutableRawPointer?,
  _ refCon: UnsafeMutableRawPointer?
) {
  guard let refCon else { return }
  Unmanaged<CMIOQueueSignalBox>.fromOpaque(refCon).takeUnretainedValue().signal()
}

enum CMIOProperty {
  static let mainElement = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
  static let globalScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)
  static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
  static let devicesSelector = CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
  static let deviceUIDSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
  static let runningSomewhereSelector =
    CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
  static let streamsSelector = CMIOObjectPropertySelector(kCMIODevicePropertyStreams)
  static let inputScope = CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput)
  static let formatSelector = CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription)
  static let formatsSelector = CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescriptions)
  static let frameRateRangesSelector = CMIOObjectPropertySelector(
    kCMIOStreamPropertyFrameRateRanges)
  static let frameRateSelector = CMIOObjectPropertySelector(kCMIOStreamPropertyFrameRate)

  static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: selector, mScope: globalScope, mElement: mainElement)
  }

  static func rawDataSize(
    _ objectID: CMIOObjectID,
    _ selector: CMIOObjectPropertySelector
  ) -> UInt32? {
    var addr = address(selector)
    var size: UInt32 = 0
    return CMIOObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == 0 ? size : nil
  }

  static func isSettable(
    _ objectID: CMIOObjectID,
    _ selector: CMIOObjectPropertySelector
  ) -> Bool {
    var addr = address(selector)
    var settable: DarwinBoolean = false
    _ = CMIOObjectIsPropertySettable(objectID, &addr, &settable)
    return settable.boolValue
  }

  /// Read a property whose data is a single CF object reference (get-rule).
  /// The +1 returned by the property read is consumed into a Swift-managed
  /// reference (takeRetainedValue), so the eventual release is balanced.
  static func cfObjectProperty(
    _ objectID: CMIOObjectID,
    _ selector: CMIOObjectPropertySelector
  ) -> CFTypeRef? {
    guard let size = rawDataSize(objectID, selector), size > 0 else { return nil }
    var addr = address(selector)
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size),
      alignment: MemoryLayout<UnsafeRawPointer>.alignment)
    defer { storage.deallocate() }
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(objectID, &addr, 0, nil, size, &used, storage)
    guard status == 0, used > 0 else { return nil }
    let cf = storage.assumingMemoryBound(to: UnsafeRawPointer.self).pointee
    return Unmanaged<CFTypeRef>.fromOpaque(cf).takeRetainedValue()
  }

  static func uint32Property(
    _ objectID: CMIOObjectID,
    _ selector: CMIOObjectPropertySelector
  ) -> UInt32? {
    guard let size = rawDataSize(objectID, selector), size > 0 else { return nil }
    var addr = address(selector)
    var value: UInt32 = 0
    var used: UInt32 = 0
    return CMIOObjectGetPropertyData(objectID, &addr, 0, nil, size, &used, &value) == 0
      ? value : nil
  }

  static func doubleProperty(_ objectID: CMIOObjectID, _ selector: CMIOObjectPropertySelector)
    -> Double?
  {
    guard let size = rawDataSize(objectID, selector), size >= MemoryLayout<Double>.size else {
      return nil
    }
    var addr = address(selector)
    var value = 0.0
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(objectID, &addr, 0, nil, size, &used, &value) == 0,
      used >= MemoryLayout<Double>.size
    else { return nil }
    return value.isFinite && value > 0 ? value : nil
  }

  static func setDoubleProperty(
    _ objectID: CMIOObjectID, _ selector: CMIOObjectPropertySelector, value: Double
  ) -> OSStatus {
    var addr = address(selector)
    var mutableValue = value
    return CMIOObjectSetPropertyData(
      objectID, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &mutableValue)
  }

}

/// CMIO device/stream lookup, mode enumeration, and sharing-state detection.
public enum CMIOCaptureDiscovery {
  public struct Located {
    public var deviceID: CMIODeviceID
    public var streamID: CMIOStreamID
  }

  /// Enumerate CMIO devices and locate the stream of the device whose UID
  /// matches. AVFoundation device uniqueIDs match CMIO device UIDs (verified
  /// for the built-in camera; USB cameras re-verify on hardware).
  public static func locate(deviceUID: String) -> Located? {
    guard
      let size = CMIOProperty.rawDataSize(
        CMIOProperty.systemObject,
        CMIOProperty.devicesSelector)
    else { return nil }
    var ids = Array(
      repeating: CMIODeviceID(),
      count: Int(size) / MemoryLayout<CMIODeviceID>.size)
    var used: UInt32 = 0
    var addr = CMIOProperty.address(CMIOProperty.devicesSelector)
    guard
      CMIOObjectGetPropertyData(
        CMIOProperty.systemObject, &addr, 0, nil,
        size, &used, &ids) == 0
    else { return nil }
    for id in ids.prefix(Int(used) / MemoryLayout<CMIODeviceID>.size) {
      guard let uidCF = CMIOProperty.cfObjectProperty(id, CMIOProperty.deviceUIDSelector),
        let uid = uidCF as? String, uid == deviceUID
      else { continue }
      // Video streams live on the input scope; fall back to global.
      for scope in [CMIOProperty.inputScope, CMIOProperty.globalScope] {
        var sAddr = CMIOObjectPropertyAddress(
          mSelector: CMIOProperty.streamsSelector,
          mScope: scope, mElement: CMIOProperty.mainElement)
        var ssize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(id, &sAddr, 0, nil, &ssize) == 0, ssize > 0 else {
          continue
        }
        var buffer = Array(
          repeating: CMIOStreamID(),
          count: Int(ssize) / MemoryLayout<CMIOStreamID>.size)
        var sused: UInt32 = 0
        guard CMIOObjectGetPropertyData(id, &sAddr, 0, nil, ssize, &sused, &buffer) == 0,
          sused > 0
        else { continue }
        return Located(deviceID: id, streamID: buffer[0])
      }
    }
    return nil
  }

  /// Is the device currently running somewhere (any client, any process)?
  public static func isRunningSomewhere(_ located: Located) -> Bool {
    (CMIOProperty.uint32Property(located.deviceID, CMIOProperty.runningSomewhereSelector) ?? 0) != 0
  }

  public static func isSettable(_ located: Located) -> Bool {
    CMIOProperty.isSettable(located.streamID, CMIOProperty.formatSelector)
  }

  /// The stream's current format description.
  public static func currentFormat(_ located: Located) -> CMFormatDescription? {
    guard let cf = CMIOProperty.cfObjectProperty(located.streamID, CMIOProperty.formatSelector)
    else { return nil }
    return unsafeDowncast(cf, to: CMFormatDescription.self)
  }

  /// All formats the CMIO stream advertises.
  ///
  /// Ownership: the format list is a get-rule CFArrayRef; the +1 is consumed
  /// with takeRetainedValue (Swift releases the array when done). The array's
  /// elements are only borrowed (+0), so they are bridged through NSArray —
  /// which retains each element properly — instead of being materialized as
  /// Swift-managed references directly from raw pointers. Materializing them
  /// with unsafeBitCast/unsafeDowncast makes Swift release objects it never
  /// retained: refcount underflow, the format description freed before use,
  /// and EXC_BAD_ACCESS inside CMIOObjectSetPropertyData (verified crash).
  public static func formats(_ located: Located) -> [CMFormatDescription] {
    guard let size = CMIOProperty.rawDataSize(located.streamID, CMIOProperty.formatsSelector),
      size == UInt32(MemoryLayout<UnsafeRawPointer>.size),
      let listCF = CMIOProperty.cfObjectProperty(located.streamID, CMIOProperty.formatsSelector)
    else { return [] }
    let list = unsafeDowncast(listCF, to: CFArray.self)
    let nsArray = unsafeDowncast(list, to: NSArray.self)
    let descriptions = nsArray as! [CMFormatDescription]
    return descriptions.filter {
      CFGetTypeID($0) == CMFormatDescriptionGetTypeID()
    }
  }

  /// CameraMode list from the CMIO stream's advertised formats, with depth,
  /// chroma, and range filled from the shared FourCC facts table. Frame rates
  /// are queried only for the format the stream is currently delivering (the
  /// qualified per-format query crashes the camera plugin on this OS build —
  /// TN3121 finding 5); all other modes report the rate as unknown.
  public static func modes(deviceUID: String) -> [CameraMode] {
    guard let located = locate(deviceUID: deviceUID) else { return [] }
    let current = currentFormat(located)
    let currentDims = current.map { CMVideoFormatDescriptionGetDimensions($0) }
    let currentFourCC = current.map { CMFormatDescriptionGetMediaSubType($0) }
    return formats(located).map { desc in
      let dims = CMVideoFormatDescriptionGetDimensions(desc)
      let fourCC = CMFormatDescriptionGetMediaSubType(desc)
      let probe = CaptureFormatFacts.applying(
        to: CaptureFormat(
          width: Int(dims.width), height: Int(dims.height), fourCC: fourCC))
      var minRate = 0.0
      var maxRate = 0.0
      // Rates are queried only for the format the stream currently delivers;
      // the qualified per-format read crashes the plugin (finding 5).
      let isCurrent =
        currentDims?.width != nil && Int(dims.width) == Int(currentDims!.width)
        && Int(dims.height) == Int(currentDims!.height) && fourCC == currentFourCC
      if isCurrent, let ranges = frameRateRangesForCurrentFormat(located) {
        minRate = ranges.map { $0.minimum }.min() ?? 0
        maxRate = ranges.map { $0.maximum }.max() ?? 0
      }
      return CameraMode(
        deviceID: deviceUID,
        formatID: nil,
        mediaSubType: fourCC,
        dimensions: (Int(dims.width), Int(dims.height)),
        minFrameRate: minRate, maxFrameRate: maxRate,
        pixelFormat: fourCC,
        bitsPerChannel: probe.bitsPerChannel,
        chromaSampling: probe.chromaSampling,
        yuvRange: probe.yuvRange)
    }
  }

  /// Frame-rate ranges (fps) for the stream's CURRENT format, via an
  /// unqualified property read. The QUALIFIED variant (passing a format
  /// description) crashes the camera plugin on this OS build —
  /// `GetFormatIndexFromQualifier → CFEqual` on DAL-internal state (verified
  /// crash, TN3121 finding 5) — so it must never be called. Rates for
  /// non-current formats are therefore reported as unknown, never zero.
  public static func frameRateRangesForCurrentFormat(_ located: Located)
    -> [(minimum: Double, maximum: Double)]?
  {
    var addr = CMIOProperty.address(CMIOProperty.frameRateRangesSelector)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(located.streamID, &addr, 0, nil, &size) == 0, size > 0
    else { return nil }
    var buffer = Array(
      repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
      count: Int(size) / MemoryLayout<AudioValueRange>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(located.streamID, &addr, 0, nil, size, &used, &buffer) == 0
    else { return nil }
    let count = Int(used) / MemoryLayout<AudioValueRange>.size
    return buffer.prefix(count).map { (max(0, $0.mMinimum), max(0, $0.mMaximum)) }
  }

  /// Find the advertised format matching a mode's dimensions and pixel format.
  public static func matchingFormat(_ located: Located, mode: CameraMode) -> CMFormatDescription? {
    formats(located).first { desc in
      let dims = CMVideoFormatDescriptionGetDimensions(desc)
      return Int(dims.width) == mode.dimensions.width && Int(dims.height) == mode.dimensions.height
        && CMFormatDescriptionGetMediaSubType(desc) == mode.mediaSubType
    }
  }
}

/// Delivers sample buffers from the CMIO buffer queue to the sinks.
/// Narrow, documented exception: the poller holds immutable configuration
/// snapshots and a lock-protected flag only; frame forwarding reuses the
/// module's sink registry exactly like the AVFoundation delegate path.
final class CMIOFramePoller: @unchecked Sendable {
  private let registry: SinkRegistry
  private let deviceUID: String
  private let generation: Int
  private var queueRef: CMSimpleQueue?
  private let queue: DispatchQueue
  /// Signaled by the queue-altered callback (and teardown); without it the
  /// poller would only wake on its 0.5 s timeout — a 30 fps stream would
  /// deliver at ~2 fps.
  lazy var signalBox = CMIOQueueSignalBox(poller: self)
  private let signals = DispatchSemaphore(value: 0)
  private let running = OSAllocatedUnfairLock<Bool>(initialState: true)
  private let stallReported = OSAllocatedUnfairLock<Bool>(initialState: false)
  private let onStall: @Sendable () -> Void
  private let stallTimeoutNanos: UInt64 = 3_000_000_000

  init(
    registry: SinkRegistry, deviceUID: String, generation: Int,
    onStall: @escaping @Sendable () -> Void
  ) {
    self.registry = registry
    self.deviceUID = deviceUID
    self.generation = generation
    self.onStall = onStall
    self.queue = DispatchQueue(label: "app.pixelbooth.cmio.poller", qos: .userInteractive)
  }

  /// The queue is attached after registration (the registration returns it).
  func attach(queueRef: CMSimpleQueue) {
    self.queueRef = queueRef
  }

  func begin() {
    queue.async { [self] in run() }
  }

  func signal() {
    signals.signal()
  }

  func stopPolling() {
    running.withLock { $0 = false }
    signals.signal()
  }

  private func run() {
    var lastDeliveryNanos = DispatchTime.now().uptimeNanoseconds
    while running.withLock({ $0 }) {
      _ = signals.wait(timeout: .now() + 0.5)
      guard running.withLock({ $0 }) else { break }
      if let queueRef {
        // Drain everything the queue currently holds.
        while let raw = CMSimpleQueueDequeue(queueRef) {
          let sample = Unmanaged<CMSampleBuffer>.fromOpaque(raw).takeRetainedValue()
          guard
            let frame = DeliveredFrame.make(
              sampleBuffer: sample, deviceUniqueID: deviceUID, generation: generation)
          else { continue }
          lastDeliveryNanos = DispatchTime.now().uptimeNanoseconds
          for entry in registry.snapshot() {
            entry.queue.async { entry.sink.receive(frame) }
          }
        }
      }
      let now = DispatchTime.now().uptimeNanoseconds
      if now &- lastDeliveryNanos > stallTimeoutNanos {
        let shouldReport = stallReported.withLock { didReport -> Bool in
          guard !didReport else { return false }
          didReport = true
          return true
        }
        if shouldReport {
          onStall()
          break
        }
      }
    }
  }
}

public enum CMIOCaptureError: Error, LocalizedError {
  case deviceNotFound(String)
  case streamUnavailable(String)
  case formatUnavailable(width: Int, height: Int, fourCC: UInt32)
  case formatNotSettable
  case formatSwitchUnavailable(
    currentWidth: Int, currentHeight: Int,
    requestedWidth: Int, requestedHeight: Int)
  case startFailed(OSStatus)
  case frameRateUnavailable

  public var errorDescription: String? {
    switch self {
    case .deviceNotFound(let uid):
      return "CMIO device not found for the selected camera (\(uid))"
    case .streamUnavailable(let uid):
      return "CMIO video stream unavailable for \(uid)"
    case .formatUnavailable(let width, let height, let fourCC):
      return
        "CMIO stream does not advertise \(width)×\(height) \(CaptureFormat.fourCCString(fourCC))"
    case .formatNotSettable:
      return "CMIO stream format selection is not available on this device"
    case .formatSwitchUnavailable(
      let currentWidth, let currentHeight,
      let requestedWidth, let requestedHeight):
      return
        "CMIO stream is \(currentWidth)×\(currentHeight); switching to \(requestedWidth)×\(requestedHeight) is unavailable on this OS build (camera plugin crash)"
    case .startFailed(let status):
      return "CMIO stream start failed (OSStatus \(status))"
    case .frameRateUnavailable:
      return "CMIO could not request the selected mode's highest frame rate"
    }
  }
}

/// CoreMediaIO HAL capture backend. Same contract as CaptureService: the
/// configure/start/stop/sink surface, generation-tagged frames, and honest
/// stream-stop notifications.
public actor CMIOCaptureService {
  private var generation = 0
  private var located: CMIOCaptureDiscovery.Located?
  private var deviceUID: String?
  private var poller: CMIOFramePoller?
  private var bufferQueue: CMSimpleQueue?
  private var callbackRefCon: UnsafeMutableRawPointer?
  private let sinkRegistry = SinkRegistry()
  public private(set) var configuredFrameRate: Double?

  public init() {}

  /// Select the mode on the CMIO stream directly. Throws when the device,
  /// stream, or the requested format is not actually available — the caller
  /// falls back to the AVFoundation backend on error.
  /// Returns the generation tag frames will carry.
  /// Re-negotiate the device's stream format through AVFoundation's
  /// configuration path. This is the only verified mode-switch mechanism on
  /// this OS build: setting `device.activeFormat` while a session is running
  /// re-negotiates the device (the negotiation survives the session
  /// stopping), after which the direct CMIO stream delivers the selected
  /// format. Verified in probe ordering/2 + pass 1: after the set-while-
  /// running and session stop, the CMIO stream read and delivered
  /// 1552×1552. The direct CMIO format write, by contrast, crashes the
  /// camera plugin (TN3121 finding 4) and must not be used.
  private func renegotiateViaAVFoundation(deviceUniqueID: String, mode: CameraMode) throws {
    guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
      throw CMIOCaptureError.deviceNotFound(deviceUniqueID)
    }
    guard
      let avfFormat = device.formats.first(where: { fmt in
        let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        return Int(d.width) == mode.dimensions.width && Int(d.height) == mode.dimensions.height
          && CMFormatDescriptionGetMediaSubType(fmt.formatDescription) == mode.mediaSubType
      })
    else {
      throw CMIOCaptureError.formatUnavailable(
        width: mode.dimensions.width,
        height: mode.dimensions.height,
        fourCC: mode.mediaSubType)
    }
    let session = AVCaptureSession()
    guard let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else {
      throw CMIOCaptureError.streamUnavailable(deviceUniqueID)
    }
    session.addInput(input)
    session.startRunning()
    defer { session.stopRunning() }
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    device.activeFormat = avfFormat
    // Give the device-side renegotiation a beat before the caller checks
    // the CMIO stream's current format.
    Thread.sleep(forTimeInterval: 0.3)
  }

  public func configure(
    deviceUniqueID: String, mode: CameraMode, requestedFrameRate: Double? = nil,
    generation requestedGeneration: Int? = nil
  ) async throws -> Int {
    guard let located = CMIOCaptureDiscovery.locate(deviceUID: deviceUniqueID) else {
      throw CMIOCaptureError.deviceNotFound(deviceUniqueID)
    }
    guard let target = CMIOCaptureDiscovery.matchingFormat(located, mode: mode) else {
      throw CMIOCaptureError.formatUnavailable(
        width: mode.dimensions.width, height: mode.dimensions.height,
        fourCC: mode.mediaSubType)
    }
    let targetDims = CMVideoFormatDescriptionGetDimensions(target)
    let targetFourCC = CMFormatDescriptionGetMediaSubType(target)

    detachDelivery()

    // Mode selection, without the crashing format-write (TN3121 finding 4):
    // if the CMIO stream already delivers the requested format, stream as-is;
    // otherwise re-negotiate the device through AVFoundation's
    // `activeFormat` path and verify the CMIO stream followed.
    func streamMatchesRequest() -> Bool {
      guard let current = CMIOCaptureDiscovery.currentFormat(located) else { return false }
      let dims = CMVideoFormatDescriptionGetDimensions(current)
      return Int(dims.width) == mode.dimensions.width && Int(dims.height) == mode.dimensions.height
        && CMFormatDescriptionGetMediaSubType(current) == targetFourCC
    }

    if streamMatchesRequest() {
      cmioLog.info(
        "CMIO configure: stream already delivers \(targetDims.width)×\(targetDims.height); no switch needed"
      )
    } else {
      try renegotiateViaAVFoundation(deviceUniqueID: deviceUniqueID, mode: mode)
      // Poll briefly for the renegotiation to become visible at the CMIO
      // layer, then verify; refusal (with AVFoundation fallback) is honest.
      var matched = false
      for _ in 0..<10 {
        if streamMatchesRequest() {
          matched = true
          break
        }
        try await Task.sleep(nanoseconds: 200_000_000)
      }
      guard matched else {
        let current = CMIOCaptureDiscovery.currentFormat(located)
        let dims = current.map { CMVideoFormatDescriptionGetDimensions($0) }
        cmioLog.error(
          "CMIO renegotiation did not take: stream is \(String(describing: dims)), need \(targetDims.width)×\(targetDims.height)"
        )
        throw CMIOCaptureError.formatSwitchUnavailable(
          currentWidth: Int(dims?.width ?? 0), currentHeight: Int(dims?.height ?? 0),
          requestedWidth: mode.dimensions.width, requestedHeight: mode.dimensions.height)
      }
      cmioLog.info(
        "CMIO configure: renegotiated device format to \(targetDims.width)×\(targetDims.height)")
    }

    let frameRanges =
      CMIOCaptureDiscovery.frameRateRangesForCurrentFormat(located)?.map {
        SupportedFrameRateRange(minimum: $0.minimum, maximum: $0.maximum)
      } ?? []
    let rateCeiling = requestedFrameRate ?? (mode.maxFrameRate > 0 ? mode.maxFrameRate : nil)
    let chosenRate = FrameRateSelection.highestSupported(in: frameRanges, ceiling: rateCeiling)
    if let chosenRate {
      let currentRate = CMIOProperty.doubleProperty(
        located.streamID, CMIOProperty.frameRateSelector)
      if let currentRate, abs(currentRate - chosenRate) < 0.01 {
        configuredFrameRate = currentRate
      } else if CMIOProperty.isSettable(located.streamID, CMIOProperty.frameRateSelector),
        CMIOProperty.setDoubleProperty(
          located.streamID, CMIOProperty.frameRateSelector, value: chosenRate) == 0
      {
        configuredFrameRate =
          CMIOProperty.doubleProperty(located.streamID, CMIOProperty.frameRateSelector)
          ?? chosenRate
      } else {
        throw CMIOCaptureError.frameRateUnavailable
      }
    } else {
      let currentRate = CMIOProperty.doubleProperty(
        located.streamID, CMIOProperty.frameRateSelector)
      if let rateCeiling {
        guard let currentRate, currentRate <= rateCeiling else {
          throw CMIOCaptureError.frameRateUnavailable
        }
      }
      configuredFrameRate = currentRate
    }
    generation = requestedGeneration ?? (generation + 1)
    self.located = located
    deviceUID = deviceUniqueID
    return generation
  }

  /// Start streaming: attach a buffer queue, start the CMIO stream, and begin
  /// polling frames into the sinks. Idempotent.
  public func start() throws {
    guard let located, let deviceUID else {
      throw CMIOCaptureError.streamUnavailable(deviceUID ?? "")
    }
    guard poller == nil else {
      // Already streaming for this configuration.
      return
    }
    let observedGeneration = generation
    let poller = CMIOFramePoller(
      registry: sinkRegistry, deviceUID: deviceUID,
      generation: generation,
      onStall: { [weak self] in
        Task {
          await self?.handleDeliveryStall(
            deviceUID: deviceUID, generation: observedGeneration)
        }
      })
    // The signal box is retained for the callback's lifetime and released in
    // detachDelivery after the callback is unregistered.
    let signalRefCon = Unmanaged.passRetained(poller.signalBox).toOpaque()
    var queueUnmanaged: Unmanaged<CMSimpleQueue>?
    let qStatus = CMIOStreamCopyBufferQueue(
      located.streamID,
      cmioQueueAltered, signalRefCon, &queueUnmanaged)
    guard qStatus == 0 else {
      Unmanaged<CMIOQueueSignalBox>.fromOpaque(signalRefCon).release()
      throw CMIOCaptureError.startFailed(qStatus)
    }
    guard let q = queueUnmanaged?.takeRetainedValue() else {
      var nilQueue: Unmanaged<CMSimpleQueue>?
      _ = CMIOStreamCopyBufferQueue(located.streamID, nil, nil, &nilQueue)
      nilQueue?.release()
      Unmanaged<CMIOQueueSignalBox>.fromOpaque(signalRefCon).release()
      throw CMIOCaptureError.startFailed(-1)
    }
    callbackRefCon = signalRefCon
    poller.attach(queueRef: q)
    bufferQueue = q
    self.poller = poller
    let startStatus = CMIODeviceStartStream(located.deviceID, located.streamID)
    guard startStatus == 0 else {
      detachDelivery()
      throw CMIOCaptureError.startFailed(startStatus)
    }
    poller.begin()
  }

  /// Stop camera use (also on window close). Sinks are told delivery stopped
  /// so retained frames are invalidated rather than treated as current.
  public func stop() {
    let uid = deviceUID
    let observedGeneration = generation
    detachDelivery()
    notifyStreamStopped(reason: .stopped, deviceID: uid, observedGeneration: observedGeneration)
  }

  /// Detach delivery: stop the stream, stop the poller, unregister the
  /// queue-altered callback, release its context and the queue. Does not
  /// notify sinks; callers that end a user-visible stream do so.
  private func detachDelivery() {
    if let poller {
      poller.stopPolling()
      self.poller = nil
    }
    if let located {
      _ = CMIODeviceStopStream(located.deviceID, located.streamID)
      // Unregister the callback before releasing its retained context.
      var nilQueue: Unmanaged<CMSimpleQueue>?
      _ = CMIOStreamCopyBufferQueue(located.streamID, nil, nil, &nilQueue)
      nilQueue?.release()
    }
    if let callbackRefCon {
      Unmanaged<CMIOQueueSignalBox>.fromOpaque(callbackRefCon).release()
      self.callbackRefCon = nil
    }
    bufferQueue = nil
  }

  private func handleDeliveryStall(deviceUID: String, generation: Int) {
    guard self.deviceUID == deviceUID, self.generation == generation, poller != nil else { return }
    detachDelivery()
    notifyStreamStopped(
      reason: .runtimeError("camera stopped delivering frames"),
      deviceID: deviceUID, observedGeneration: generation)
  }

  private func notifyStreamStopped(
    reason: StreamStopReason, deviceID: String?,
    observedGeneration: Int?
  ) {
    let stop = StreamStop(
      reason: reason, deviceUniqueID: deviceID,
      generation: observedGeneration)
    for entry in sinkRegistry.snapshot() {
      entry.queue.async { entry.sink.streamStopped(stop) }
    }
  }

  public func addSink(_ sink: FrameSink, queue: DispatchQueue) {
    sinkRegistry.set(sink, queue: queue)
  }

  public func removeSink(_ sink: FrameSink) {
    sinkRegistry.remove(sink)
  }

  /// Sharing state for the status line: another client (any process) is
  /// currently consuming this device, so the format follows the device's
  /// shared stream configuration.
  public func sharedWithAnotherClient() -> Bool {
    guard let located else { return false }
    return CMIOCaptureDiscovery.isRunningSomewhere(located)
  }
}
