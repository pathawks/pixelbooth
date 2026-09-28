// CoreMediaIO HAL probe: the layer beneath AVFoundation. Diagnoses device
// ownership (hog mode), whether the camera is running elsewhere, what stream
// formats CMIO actually exposes, and whether the stream format is settable
// directly. Public C API only (CoreMediaIO.framework).
//
// CF-object handling discipline: all CF references from CMIOObjectGetPropertyData
// are get-rule (+1). They are wrapped with Unmanaged and taken unretained so
// Swift never releases them; the small process leaks them deliberately.

import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

let cmioMainElement = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
let cmioGlobalScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)
let cmioSystemObject = CMIOObjectID(kCMIOObjectSystemObject)
let cmioDevicesSelector = CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
let cmioDeviceUIDSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
let cmioRunningSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
let cmioHogSelector = CMIOObjectPropertySelector(kCMIODevicePropertyHogMode)
let cmioStreamsSelector = CMIOObjectPropertySelector(kCMIODevicePropertyStreams)
let cmioInputScope = CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput)
let cmioFormatSelector = CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription)
let cmioFormatsSelector = CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescriptions)

private func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
  CMIOObjectPropertyAddress(mSelector: selector, mScope: cmioGlobalScope, mElement: cmioMainElement)
}

private func rawDataSize(_ objectID: CMIOObjectID, _ selector: CMIOObjectPropertySelector)
  -> UInt32?
{
  var addr = address(selector)
  var size: UInt32 = 0
  let status = CMIOObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
  return status == 0 ? size : nil
}

private func isSettable(_ objectID: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> Bool {
  var addr = address(selector)
  var settable: DarwinBoolean = false
  _ = CMIOObjectIsPropertySettable(objectID, &addr, &settable)
  return settable.boolValue
}

/// C-convention queue-altered callback (no-op; we poll the queue instead).
private func cmioQueueAltered(
  _ streamID: CMIOStreamID, _ token: UnsafeMutableRawPointer?,
  _ refCon: UnsafeMutableRawPointer?
) {}

func describe(_ desc: CMFormatDescription) -> String {
  let dims = CMVideoFormatDescriptionGetDimensions(desc)
  let fourCC = CMFormatDescriptionGetMediaSubType(desc)
  return "\(dims.width)×\(dims.height) \(fourCCText(fourCC))"
}

/// Read a property whose data is a single CF object reference (get-rule).
/// Returns the CF object as an unretained managed reference (never released).
private func cfObjectProperty(
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
  return Unmanaged<CFTypeRef>.fromOpaque(cf).takeUnretainedValue()
}

private func uint32Property(_ objectID: CMIOObjectID, _ selector: CMIOObjectPropertySelector)
  -> UInt32?
{
  guard let size = rawDataSize(objectID, selector), size > 0 else { return nil }
  var addr = address(selector)
  var value: UInt32 = 0
  var used: UInt32 = 0
  let status = CMIOObjectGetPropertyData(objectID, &addr, 0, nil, size, &used, &value)
  return status == 0 ? value : nil
}

enum CMIOProbe {
  static func run(matchingUIDs: [String]) async {
    print("=== CoreMediaIO HAL probe ===")
    guard let size = rawDataSize(cmioSystemObject, cmioDevicesSelector) else {
      print("CMIO: cannot read device list")
      return
    }
    var deviceIDs = Array(
      repeating: CMIODeviceID(), count: Int(size) / MemoryLayout<CMIODeviceID>.size)
    var used: UInt32 = 0
    var addr = address(cmioDevicesSelector)
    let status = CMIOObjectGetPropertyData(cmioSystemObject, &addr, 0, nil, size, &used, &deviceIDs)
    guard status == 0 else {
      print("CMIO: device list read failed: \(status)")
      return
    }
    deviceIDs = Array(deviceIDs.prefix(Int(used) / MemoryLayout<CMIODeviceID>.size))

    for deviceID in deviceIDs {
      guard let uidCF = cfObjectProperty(deviceID, cmioDeviceUIDSelector),
        let uid = uidCF as? String
      else { continue }
      let running = (uint32Property(deviceID, cmioRunningSelector) ?? 0) != 0
      var hog: pid_t = -1
      if let s = rawDataSize(deviceID, cmioHogSelector) {
        var a = address(cmioHogSelector)
        var u: UInt32 = 0
        _ = CMIOObjectGetPropertyData(deviceID, &a, 0, nil, s, &u, &hog)
      }
      let matched = matchingUIDs.contains(uid)
      print("CMIO device [\(uid)] runningSomewhere=\(running) hogModePID=\(hog) matched=\(matched)")
      guard matched else { continue }
      await probeDevice(deviceID, uid: uid)
    }
  }

  private static func probeDevice(_ deviceID: CMIODeviceID, uid: String) async {
    // Streams on the input scope; fall back to global.
    var streams = [CMIOStreamID]()
    for scope in [cmioInputScope, cmioGlobalScope] {
      var sAddr = CMIOObjectPropertyAddress(
        mSelector: cmioStreamsSelector, mScope: scope, mElement: cmioMainElement)
      var size: UInt32 = 0
      guard CMIOObjectGetPropertyDataSize(deviceID, &sAddr, 0, nil, &size) == 0, size > 0 else {
        continue
      }
      var used: UInt32 = 0
      var buffer = Array(
        repeating: CMIOStreamID(), count: Int(size) / MemoryLayout<CMIOStreamID>.size)
      let status = CMIOObjectGetPropertyData(deviceID, &sAddr, 0, nil, size, &used, &buffer)
      if status == 0, used > 0 {
        streams = Array(buffer.prefix(Int(used) / MemoryLayout<CMIOStreamID>.size))
        break
      }
    }
    print("  CMIO streams: \(streams.count)")

    for streamID in streams {
      guard let currentCF = cfObjectProperty(streamID, cmioFormatSelector) else {
        print("  stream \(streamID): no current format")
        continue
      }
      let current = unsafeDowncast(currentCF, to: CMFormatDescription.self)
      let settable = isSettable(streamID, cmioFormatSelector)
      print("  stream \(streamID) current format: \(describe(current)) settable=\(settable)")

      guard let rawListPtr = rawDataSize(streamID, cmioFormatsSelector).map({ $0 }) else {
        print("  stream \(streamID): no format list")
        continue
      }
      _ = rawListPtr
      guard let listSize = rawDataSize(streamID, cmioFormatsSelector) else { continue }
      var square: CMFormatDescription?
      // The property may deliver a CFArrayRef (single CF object) or an inline
      // C array of CMFormatDescriptionRefs; decide by its data size.
      if listSize == UInt32(MemoryLayout<UnsafeRawPointer>.size),
        let listCF = cfObjectProperty(streamID, cmioFormatsSelector)
      {
        let list = unsafeDowncast(listCF, to: CFArray.self)
        let count = CFArrayGetCount(list)
        for i in 0..<count {
          guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
          let d = Unmanaged<CMFormatDescription>.fromOpaque(raw).takeUnretainedValue()
          print("    cmio fmt[\(i)] \(describe(d))")
          let dims = CMVideoFormatDescriptionGetDimensions(d)
          if Int(dims.width) == 1552 && Int(dims.height) == 1552 { square = d }
        }
      } else {
        let count = Int(listSize) / MemoryLayout<UnsafeRawPointer>.size
        var refs = [UnsafeMutableRawPointer?](repeating: nil, count: count)
        var sAddr = address(cmioFormatsSelector)
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(streamID, &sAddr, 0, nil, listSize, &used, &refs)
        guard status == 0 else {
          print("  stream \(streamID): inline format list read failed: \(status)")
          continue
        }
        for i in 0..<min(count, Int(used) / MemoryLayout<UnsafeRawPointer>.size) {
          guard let raw = refs[i] else { continue }
          let d = Unmanaged<CMFormatDescription>.fromOpaque(raw).takeUnretainedValue()
          print("    cmio fmt[\(i)] \(describe(d))")
          let dims = CMVideoFormatDescriptionGetDimensions(d)
          if Int(dims.width) == 1552 && Int(dims.height) == 1552 { square = d }
        }
      }

      if settable, let square, CommandLine.arguments.contains("--cmio-set") {
        // Attempt: select the square format, stream one buffer, restore.
        // With --cmio-hog, acquire hog mode (exclusive device control) first:
        // format changes may be restricted to the exclusive client.
        var heldHog = false
        if CommandLine.arguments.contains("--cmio-hog") {
          var hogAddr = address(cmioHogSelector)
          var pid = getpid()
          let hogStatus = CMIOObjectSetPropertyData(
            deviceID, &hogAddr, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &pid)
          heldHog = hogStatus == 0
          print("  stream \(streamID): hog mode acquire status=\(hogStatus) (pid \(getpid()))")
        }
        print("  stream \(streamID): attempting square-format selection...")
        let ptr = Unmanaged.passUnretained(square).toOpaque()
        var sAddr = address(cmioFormatSelector)
        let setStatus = CMIOObjectSetPropertyData(
          streamID, &sAddr, 0, nil,
          UInt32(MemoryLayout<UnsafeRawPointer>.size), ptr)
        print("  stream \(streamID): set status=\(setStatus)")
        if setStatus == 0, let afterCF = cfObjectProperty(streamID, cmioFormatSelector) {
          let after = unsafeDowncast(afterCF, to: CMFormatDescription.self)
          print("  stream \(streamID): format after set: \(describe(after))")
        }
        if heldHog {
          var hogAddr = address(cmioHogSelector)
          var released: pid_t = -1
          let releaseStatus = CMIOObjectSetPropertyData(
            deviceID, &hogAddr, 0, nil,
            UInt32(MemoryLayout<pid_t>.size), &released)
          print("  stream \(streamID): hog mode release status=\(releaseStatus)")
        }
      } else {
        print(
          "  stream \(streamID): format-set skipped (settable=\(settable), square=\(square != nil), pass --cmio-set to attempt)"
        )
      }

      // Attach a buffer queue, start the stream, dequeue one buffer.
      var queue: Unmanaged<CMSimpleQueue>?
      let qStatus = CMIOStreamCopyBufferQueue(streamID, cmioQueueAltered, nil, &queue)
      print("  stream \(streamID): buffer queue status=\(qStatus)")
      if let q = queue?.takeRetainedValue() {
        let startStatus = CMIODeviceStartStream(deviceID, streamID)
        print("  stream \(streamID): start status=\(startStatus)")
        var sample: CMSampleBuffer?
        let deadline = DispatchTime.now() + 3.0
        while DispatchTime.now() < deadline {
          if let raw = CMSimpleQueueDequeue(q) {
            sample = Unmanaged<CMSampleBuffer>.fromOpaque(raw).takeRetainedValue()
            break
          }
          usleep(20_000)
        }
        _ = CMIODeviceStopStream(deviceID, streamID)
        if let sample, let fd = CMSampleBufferGetFormatDescription(sample) {
          let dims = CMVideoFormatDescriptionGetDimensions(fd)
          print(
            "  stream \(streamID): DELIVERED \(dims.width)×\(dims.height) \(fourCCText(CMFormatDescriptionGetMediaSubType(fd)))"
          )
        } else {
          print("  stream \(streamID): no sample buffer within 3 s")
        }
      }

      if CommandLine.arguments.contains("--cmio-set") {
        // Restore the original format.
        let ptr = Unmanaged.passUnretained(current).toOpaque()
        var sAddr = address(cmioFormatSelector)
        let restoreStatus = CMIOObjectSetPropertyData(
          streamID, &sAddr, 0, nil,
          UInt32(MemoryLayout<UnsafeRawPointer>.size), ptr)
        print("  stream \(streamID): restore status=\(restoreStatus)")
      }
    }
  }

  /// The make-or-break experiment: start an AVFoundation session (which pins
  /// the CMIO stream format to its default), then set the CMIO stream format
  /// directly and observe whether AVFoundation-delivered buffers follow.
  static func overrideWhileAVFoundationRuns(deviceUID: String, square: CMFormatDescription) async {
    FileHandle.standardError.write(Data("override: device lookup\n".utf8))
    let dev = AVCaptureDevice(uniqueID: deviceUID)
    guard let dev else { return }
    FileHandle.standardError.write(Data("override: session setup\n".utf8))
    let session = AVCaptureSession()
    guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
      return
    }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [:] as [String: Any]
    guard session.canAddOutput(output) else { return }
    session.addOutput(output)
    let frameBox = OSAllocatedUnfairLock<[(Int, Int)]>(initialState: [])
    let delegate = ProbeDelegate { buffer in
      if let fd = CMSampleBufferGetFormatDescription(buffer) {
        let d = CMVideoFormatDescriptionGetDimensions(fd)
        frameBox.withLock { $0.append((Int(d.width), Int(d.height))) }
      }
    }
    output.setSampleBufferDelegate(
      delegate, queue: DispatchQueue(label: "probe.video.cmioOverride"))
    session.startRunning()
    FileHandle.standardError.write(Data("override: session running\n".utf8))
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let before = frameBox.withLock { $0.map { "\($0.0)×\($0.1)" }.joined(separator: " ") }
    print("  cmio-override: frames before set: \(before)")

    // Locate the CMIO device + stream.
    FileHandle.standardError.write(Data("override: CMIO enumeration\n".utf8))
    guard let size = rawDataSize(cmioSystemObject, cmioDevicesSelector) else { return }
    var ids = Array(repeating: CMIODeviceID(), count: Int(size) / MemoryLayout<CMIODeviceID>.size)
    var used: UInt32 = 0
    var addr = address(cmioDevicesSelector)
    guard CMIOObjectGetPropertyData(cmioSystemObject, &addr, 0, nil, size, &used, &ids) == 0 else {
      return
    }
    outer: for id in ids.prefix(Int(used) / MemoryLayout<CMIODeviceID>.size) {
      guard let uidCF = cfObjectProperty(id, cmioDeviceUIDSelector),
        let uid = uidCF as? String, uid == deviceUID
      else { continue }
      var sAddr = CMIOObjectPropertyAddress(
        mSelector: cmioStreamsSelector, mScope: cmioInputScope, mElement: cmioMainElement)
      var ssize: UInt32 = 0
      guard CMIOObjectGetPropertyDataSize(id, &sAddr, 0, nil, &ssize) == 0, ssize > 0 else { break }
      var sbuf = Array(
        repeating: CMIOStreamID(), count: Int(ssize) / MemoryLayout<CMIOStreamID>.size)
      var sused: UInt32 = 0
      guard CMIOObjectGetPropertyData(id, &sAddr, 0, nil, ssize, &sused, &sbuf) == 0, sused > 0
      else { break }
      let streamID = sbuf[0]
      if let currentCF = cfObjectProperty(streamID, cmioFormatSelector) {
        let current = unsafeDowncast(currentCF, to: CMFormatDescription.self)
        print("  cmio-override: CMIO current format before set: \(describe(current))")
      }
      let ptr = Unmanaged.passUnretained(square).toOpaque()
      var fAddr = address(cmioFormatSelector)
      let setStatus = CMIOObjectSetPropertyData(
        streamID, &fAddr, 0, nil,
        UInt32(MemoryLayout<UnsafeRawPointer>.size), ptr)
      print("  cmio-override: set status=\(setStatus)")
      if setStatus == 0 {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let afterCF = cfObjectProperty(streamID, cmioFormatSelector) {
          let after = unsafeDowncast(afterCF, to: CMFormatDescription.self)
          print("  cmio-override: CMIO current format after set: \(describe(after))")
        }
        let newFrames = frameBox.withLock {
          $0.suffix(5).map { "\($0.0)×\($0.1)" }.joined(separator: " ")
        }
        print("  cmio-override: frames after set: \(newFrames)")
      }
      break outer
    }
    session.stopRunning()
  }
}
