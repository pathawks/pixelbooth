// Opt-in metadata diagnostics. Examples after building the HardwareProbe target:
// .build/debug/HardwareProbe --color-metadata --device-uid UID --backend cmio --frames 120
// .build/debug/HardwareProbe --color-metadata --device-uid UID --backend avfoundation
// Close other camera clients first. This starts only the explicitly named camera,
// records metadata without reading image planes, and stops within 30 seconds.
// No USB requests, Photos access, explicit format/rate selection, or color overrides.
// AVFoundation may renegotiate shared device state even with empty output settings.

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreVideo
import CryptoKit
import Foundation
import PixelBoothCapture
import os

enum ColorMetadataProbe {
  private struct Options: Sendable {
    var uid: String
    var backend = "cmio"
    var frames = 120
  }

  static func run(arguments: [String]) async -> Int32 {
    guard let options = parse(arguments) else { return 2 }
    // Capture configuration and the bounded wait are isolated from the main
    // actor. AVFoundation/CMIO objects never leave this detached task.
    return await Task.detached { execute(options) }.value
  }

  private static func parse(_ arguments: [String]) -> Options? {
    var options = Options(uid: "")
    var position = 0
    var seen: Set<String> = []
    while position < arguments.count {
      let flag = arguments[position]
      guard seen.insert(flag).inserted else { return usage("duplicate argument \(flag)") }
      if flag == "--color-metadata" {
        position += 1
        continue
      }
      guard ["--device-uid", "--backend", "--frames"].contains(flag),
        position + 1 < arguments.count
      else { return usage("unexpected or incomplete argument \(flag)") }
      let value = arguments[position + 1]
      switch flag {
      case "--device-uid": options.uid = value
      case "--backend":
        guard ["cmio", "avfoundation"].contains(value) else {
          return usage("backend must be cmio or avfoundation")
        }
        options.backend = value
      case "--frames":
        guard let count = Int(value), (1...600).contains(count) else {
          return usage("frames must be an integer in 1...600")
        }
        options.frames = count
      default: return nil
      }
      position += 2
    }
    guard !options.uid.isEmpty, !options.uid.hasPrefix("--") else {
      return usage("an explicit --device-uid UID is required")
    }
    return options
  }

  private static func usage(_ reason: String) -> Options? {
    print("Color metadata probe refused: \(reason)")
    print(
      "Usage: HardwareProbe --color-metadata --device-uid UID "
        + "[--backend cmio|avfoundation] [--frames 1...600]")
    print("Default backend: cmio. Default frames: 120. Maximum duration: 30 seconds.")
    return nil
  }

  private static func execute(_ options: Options) -> Int32 {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      print("Color metadata probe refused: camera permission is not already authorized.")
      return 2
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified)
    guard let device = discovery.devices.first(where: { $0.uniqueID == options.uid }),
      device.isConnected, !device.isSuspended,
      let located = CMIOCaptureDiscovery.locate(deviceUID: options.uid)
    else {
      print("Color metadata probe refused: named camera or its CMIO stream is unavailable.")
      return 3
    }
    guard !device.isInUseByAnotherApplication, isRunning(located) == false else {
      print("Color metadata probe refused: camera is busy or its running state is unavailable.")
      return 3
    }
    print("=== Opt-in color metadata probe ===")
    print("Device: \(device.localizedName), UID: \(options.uid), backend: \(options.backend)")
    print("Requested frames: \(options.frames); time limit: 30 seconds.")
    print("No image planes are read or saved. No explicit format, rate, or color writes.")
    print("AVFoundation can renegotiate shared device state even with empty output settings.")
    let statistics = ColorProbeStatistics(limit: options.frames)
    switch options.backend {
    case "avfoundation":
      return avfoundation(device: device, located: located, statistics: statistics)
    default: return cmio(located: located, statistics: statistics)
    }
  }

  /// Unqualified scalar read with exact size checking; unknown state refuses activation.
  private static func isRunning(_ located: CMIOCaptureDiscovery.Located) -> Bool? {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(located.deviceID, &address, 0, nil, &size) == noErr,
      size == MemoryLayout<UInt32>.size
    else { return nil }
    var value: UInt32 = 0
    var used: UInt32 = 0
    guard
      CMIOObjectGetPropertyData(
        located.deviceID, &address, 0, nil, size, &used, &value) == noErr,
      used == size
    else { return nil }
    return value != 0
  }

  private static func cmio(
    located: CMIOCaptureDiscovery.Located, statistics: ColorProbeStatistics
  ) -> Int32 {
    guard let current = CMIOCaptureDiscovery.currentFormat(located) else {
      print("CMIO current format is unavailable; no stream started.")
      return 3
    }
    print("CMIO current-format metadata: \(ColorProbeSnapshot.format(current))")
    guard isRunning(located) == false else {
      print("CMIO camera became busy; no stream started.")
      return 3
    }
    var reference: Unmanaged<CMSimpleQueue>?
    let queueStatus = CMIOStreamCopyBufferQueue(
      located.streamID, colorProbeQueueChanged, nil, &reference)
    guard queueStatus == noErr, let queue = reference?.takeRetainedValue() else {
      print("CMIO queue unavailable: \(queueStatus)")
      return 4
    }
    var started = false
    defer {
      if started {
        print("CMIO stop status: \(CMIODeviceStopStream(located.deviceID, located.streamID))")
      }
      var detached: Unmanaged<CMSimpleQueue>?
      _ = CMIOStreamCopyBufferQueue(located.streamID, nil, nil, &detached)
      detached?.release()
      while let pointer = CMSimpleQueueDequeue(queue) {
        Unmanaged<CMSampleBuffer>.fromOpaque(pointer).release()
      }
      if let after = CMIOCaptureDiscovery.currentFormat(located) {
        print("CMIO format after stopping: \(ColorProbeSnapshot.format(after))")
      }
    }
    let status = CMIODeviceStartStream(located.deviceID, located.streamID)
    guard status == noErr else {
      print("CMIO start failed: \(status)")
      return 4
    }
    started = true
    let deadline = DispatchTime.now() + .seconds(30)
    while !statistics.isComplete && DispatchTime.now() < deadline {
      if let pointer = CMSimpleQueueDequeue(queue) {
        let sample = Unmanaged<CMSampleBuffer>.fromOpaque(pointer).takeRetainedValue()
        statistics.record(sample)
      } else {
        Thread.sleep(forTimeInterval: 0.005)
      }
    }
    return statistics.report()
  }

  private static func avfoundation(
    device: AVCaptureDevice, located: CMIOCaptureDiscovery.Located,
    statistics: ColorProbeStatistics
  ) -> Int32 {
    print(
      "AVFoundation active format before session: \(ColorProbeSnapshot.format(device.activeFormat.formatDescription))"
    )
    if let before = CMIOCaptureDiscovery.currentFormat(located) {
      print("CMIO format before AVFoundation session: \(ColorProbeSnapshot.format(before))")
    }
    let session = AVCaptureSession()
    guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
      print("AVFoundation camera input is unavailable.")
      return 4
    }
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [:] as [String: Any]
    output.alwaysDiscardsLateVideoFrames = true
    session.addInput(input)
    guard session.canAddOutput(output) else {
      print("AVFoundation native video output is unavailable.")
      return 4
    }
    session.addOutput(output)
    let queue = DispatchQueue(label: "app.pixelbooth.color-metadata-probe")
    let delegate = ProbeDelegate { statistics.record($0) }
    output.setSampleBufferDelegate(delegate, queue: queue)
    defer {
      session.stopRunning()
      output.setSampleBufferDelegate(nil, queue: nil)
      queue.sync {}
      withExtendedLifetime(delegate) {}
    }
    guard !device.isInUseByAnotherApplication, isRunning(located) == false else {
      print("AVFoundation camera became busy; no stream started.")
      return 3
    }
    // No session preset, activeFormat, frame durations, or color space is set.
    // AVFoundation may negotiate its own format; report the actual deliveries.
    session.startRunning()
    guard session.isRunning else {
      print("AVFoundation session did not start.")
      return 4
    }
    _ = statistics.wait()
    session.stopRunning()
    output.setSampleBufferDelegate(nil, queue: nil)
    queue.sync {}
    print(
      "AVFoundation active format after session: \(ColorProbeSnapshot.format(device.activeFormat.formatDescription))"
    )
    if let after = CMIOCaptureDiscovery.currentFormat(located) {
      print("CMIO format after AVFoundation session: \(ColorProbeSnapshot.format(after))")
    }
    return statistics.report()
  }
}

private func colorProbeQueueChanged(
  _ stream: CMIOStreamID, _ token: UnsafeMutableRawPointer?, _ context: UnsafeMutableRawPointer?
) {}

private final class ColorProbeStatistics: Sendable {
  private struct Variant: Sendable {
    var count: Int
    var firstFrame: Int
    var lastFrame: Int
  }

  private struct State: Sendable {
    var count = 0
    var variants: [String: Variant] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let completion = DispatchSemaphore(value: 0)
  private let limit: Int

  init(limit: Int) { self.limit = limit }

  var isComplete: Bool { state.withLock { $0.count >= limit } }

  func record(_ sample: CMSampleBuffer) {
    guard !isComplete else { return }
    let snapshot = ColorProbeSnapshot.sample(sample)
    let finished = state.withLock { state -> Bool in
      guard state.count < limit else { return false }
      state.count += 1
      if var variant = state.variants[snapshot] {
        variant.count += 1
        variant.lastFrame = state.count
        state.variants[snapshot] = variant
      } else {
        state.variants[snapshot] = Variant(
          count: 1, firstFrame: state.count, lastFrame: state.count)
      }
      return state.count == limit
    }
    if finished { completion.signal() }
  }

  func wait() -> Bool { completion.wait(timeout: .now() + .seconds(30)) == .success }

  func report() -> Int32 {
    let snapshot = state.withLock { $0 }
    print(
      "Captured metadata for \(snapshot.count)/\(limit) frames; \(snapshot.variants.count) variants."
    )
    for key in snapshot.variants.keys.sorted() {
      let variant = snapshot.variants[key]!
      print(
        "VARIANT count=\(variant.count), first=\(variant.firstFrame), last=\(variant.lastFrame)")
      print(key)
    }
    if snapshot.count < limit {
      print("Probe ended before the requested frame count; partial observations are reported.")
      return 5
    }
    return 0
  }
}

private enum ColorProbeSnapshot {
  private static var requiredKeys: [CFString] {
    [
      kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
      kCVImageBufferYCbCrMatrixKey, kCVImageBufferICCProfileKey, kCVImageBufferCGColorSpaceKey,
    ]
  }

  private static var optionalKeys: [CFString] {
    [
      kCVImageBufferGammaLevelKey, kCVImageBufferChromaLocationTopFieldKey,
      kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferMasteringDisplayColorVolumeKey,
      kCVImageBufferContentLightLevelInfoKey, kCVImageBufferAmbientViewingEnvironmentKey,
      kCVImageBufferLogTransferFunctionKey, kCMSampleAttachmentKey_HDR10PlusPerFrameData,
    ]
  }

  static func format(_ description: CMFormatDescription) -> String {
    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
    let code = fourCCText(CMFormatDescriptionGetMediaSubType(description))
    let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
    var result = fields(extensions, scope: "format")
    result["format.layout"] = "\(dimensions.width)x\(dimensions.height) \(code)"
    return json(result)
  }

  static func sample(_ sample: CMSampleBuffer) -> String {
    var result: [String: String] = [:]
    if let description = CMSampleBufferGetFormatDescription(sample) {
      let dimensions = CMVideoFormatDescriptionGetDimensions(description)
      result["delivered.format"] =
        "\(dimensions.width)x\(dimensions.height) \(fourCCText(CMFormatDescriptionGetMediaSubType(description)))"
      let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
      result.merge(fields(extensions, scope: "format")) { _, new in new }
    } else {
      result["delivered.format"] = "missing"
    }
    for (mode, suffix) in [
      (CMAttachmentMode(1), "propagating"), (CMAttachmentMode(0), "nonpropagating"),
    ] {
      let values =
        CMCopyDictionaryOfAttachments(allocator: nil, target: sample, attachmentMode: mode)
        as? [String: Any] ?? [:]
      result.merge(fields(values, scope: "sample.\(suffix)")) { _, new in new }
    }
    if let samples = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[String: Any]]
    {
      for (index, values) in samples.enumerated() {
        result.merge(fields(values, scope: "perSample[\(index)]")) { _, new in new }
      }
    }
    if let pixels = CMSampleBufferGetImageBuffer(sample) {
      result["delivered.pixels"] =
        "\(CVPixelBufferGetWidth(pixels))x\(CVPixelBufferGetHeight(pixels)) \(fourCCText(CVPixelBufferGetPixelFormatType(pixels)))"
      for (mode, suffix) in [
        (CVAttachmentMode.shouldPropagate, "propagating"), (.shouldNotPropagate, "nonpropagating"),
      ] {
        let values = CVBufferCopyAttachments(pixels, mode) as? [String: Any] ?? [:]
        result.merge(fields(values, scope: "pixels.\(suffix)")) { _, new in new }
      }
    } else {
      result["delivered.pixels"] = "no image buffer; compressed sample"
    }
    return json(result)
  }

  private static func fields(_ values: [String: Any], scope: String) -> [String: String] {
    var result: [String: String] = [:]
    for key in requiredKeys {
      result["\(scope).\(key)"] = values[key as String].map(value) ?? "missing"
    }
    for key in optionalKeys {
      if let attachment = values[key as String] { result["\(scope).\(key)"] = value(attachment) }
    }
    return result
  }

  private static func value(_ object: Any) -> String {
    if CFGetTypeID(object as CFTypeRef) == CGColorSpace.typeID {
      let color = unsafeDowncast(object as AnyObject, to: CGColorSpace.self)
      let name = color.name as String? ?? "unnamed"
      guard let data = color.copyICCData() as Data? else {
        return "CGColorSpace \(name); ICC unavailable"
      }
      return "CGColorSpace \(name); ICC bytes=\(data.count) sha256=\(hash(data))"
    }
    if let data = object as? Data { return "data bytes=\(data.count) sha256=\(hash(data))" }
    if let data = try? PropertyListSerialization.data(
      fromPropertyList: ["value": object], format: .binary, options: 0)
    {
      let description = String(String(describing: object).prefix(256))
      return "\(description); binary-plist bytes=\(data.count) sha256=\(hash(data))"
    }
    return "unserializable \(String(String(describing: object).prefix(256)))"
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func json(_ values: [String: String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "metadata serialization failed" }
    return text
  }
}
