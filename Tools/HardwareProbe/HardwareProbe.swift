// Headless hardware probe: enumerates real cameras, inspects actual delivered
// sample buffers with an explicitly empty videoSettings dictionary (TN3121),
// and records acquisition-fidelity evidence. Run on hardware with camera
// permission granted.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

@main
struct HardwareProbe {
  static func main() async {
    print("=== PixelBooth hardware probe ===")
    print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

    var status = AVCaptureDevice.authorizationStatus(for: .video)
    print("Camera permission: \(status.rawValue)")

    if status == .notDetermined {
      let granted = await AVCaptureDevice.requestAccess(for: .video)
      print("Permission granted: \(granted)")
      status = AVCaptureDevice.authorizationStatus(for: .video)
    }
    guard status == .authorized else {
      print("DENIED — cannot probe real capture")
      exit(2)
    }

    // CMIO-only diagnostics: run with zero AVFoundation involvement (no
    // discovery session, no sessions) to test the HAL layer in isolation.
    if CommandLine.arguments.contains("--cmio-only") {
      await CMIOProbe.run(matchingUIDs: ["47B4B64B-7067-4B9C-AD2B-AE273A71F4B5"])
      exit(0)
    }

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external, .builtInWideAngleCamera],
      mediaType: .video, position: .unspecified)
    print("Discovered devices:")
    var builtInUIDs = [String]()
    for dev in discovery.devices {
      print(
        "  - \(dev.localizedName) [\(dev.uniqueID)] manufacturer=\(dev.manufacturer) connected=\(dev.isConnected)"
      )
      if dev.deviceType == .builtInWideAngleCamera { builtInUIDs.append(dev.uniqueID) }
    }

    // Standalone override experiment (avoids interference from other probe
    // phases): `--only-override`.
    if CommandLine.arguments.contains("--only-override") {
      FileHandle.standardError.write(Data("only-override: starting\n".utf8))
      guard let dev = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }),
        let square = dev.formats.map(\.formatDescription).first(where: { fd in
          let d = CMVideoFormatDescriptionGetDimensions(fd)
          return Int(d.width) == 1552 && Int(d.height) == 1552
        })
      else {
        print("no square format")
        exit(3)
      }
      FileHandle.standardError.write(Data("only-override: square format located\n".utf8))
      await CMIOProbe.overrideWhileAVFoundationRuns(deviceUID: dev.uniqueID, square: square)
      FileHandle.standardError.write(Data("only-override: completed\n".utf8))
      exit(0)
    }

    for dev in discovery.devices {
      print("\nDevice: \(dev.localizedName)")
      for (i, fmt) in dev.formats.enumerated().prefix(12) {
        let desc = fmt.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let fourCC = CMFormatDescriptionGetMediaSubType(desc)
        if let r = fmt.videoSupportedFrameRateRanges.first, r.minFrameDuration.seconds > 0 {
          let maxRate = 1.0 / r.minFrameDuration.seconds
          print(
            "  fmt[\(i)] \(dims.width)×\(dims.height) fourCC=\(fourCCText(fourCC)) maxRate=\(String(format: "%.1f", maxRate))"
          )
        }
      }

      // Delivery experiments activate the camera; restrict them to built-in
      // devices so external cameras (e.g. Continuity iPhone cameras) are
      // never turned on by the probe.
      guard dev.deviceType == .builtInWideAngleCamera else {
        print("  (delivery experiments skipped: not a built-in camera)")
        continue
      }

      // ACTIVE-FORMAT EXPERIMENT: does the installed SDK honor
      // device.activeFormat for every advertised format, or does the session
      // (whose preset defaults to .high on macOS, where .inputPriority is
      // unavailable) deliver its own configuration regardless?
      // For each format: fresh stopped session, add input, set activeFormat,
      // record the preset before/after assignment and after startRunning,
      // then read the actually delivered sample-buffer format description.
      print("  --- activeFormat experiment (all advertised formats) ---")
      for (i, fmt) in dev.formats.enumerated() {
        let desc = fmt.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let fourCC = CMFormatDescriptionGetMediaSubType(desc)
        let session = AVCaptureSession()
        print(
          "  fmt[\(i)] \(dims.width)×\(dims.height) fourCC=\(fourCCText(fourCC)) preset-before=\(session.sessionPreset.rawValue)"
        )
        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
          print("    (cannot add input; skipping)")
          continue
        }
        session.addInput(input)
        do {
          try dev.lockForConfiguration()
          defer { dev.unlockForConfiguration() }
          dev.activeFormat = fmt
          // Read back what the device actually adopted, not what we asked.
          let activeDims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
          let activeFourCC = CMFormatDescriptionGetMediaSubType(dev.activeFormat.formatDescription)
          print(
            "    activeFormat after set: \(activeDims.width)×\(activeDims.height) fourCC=\(fourCCText(activeFourCC)) preset=\(session.sessionPreset.rawValue)"
          )
        } catch {
          print("    lockForConfiguration failed: \(error.localizedDescription); skipping")
          continue
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [:] as [String: Any]
        guard session.canAddOutput(output) else {
          print("    (cannot add output)")
          continue
        }
        session.addOutput(output)
        let exp = expectation()
        let box = DeliveryBox()
        let delegate = ProbeDelegate { buffer in
          if let fd = CMSampleBufferGetFormatDescription(buffer) {
            let d = CMVideoFormatDescriptionGetDimensions(fd)
            box.set(
              fourCC: CMFormatDescriptionGetMediaSubType(fd),
              width: Int(d.width), height: Int(d.height))
          }
          exp.fulfill()
        }
        output.setSampleBufferDelegate(
          delegate, queue: DispatchQueue(label: "probe.video.activeFormat"))
        session.startRunning()
        let delivered = await wait(exp, seconds: 5)
        session.stopRunning()
        if delivered {
          let d = box.get()
          print(
            "    delivered fourCC=\(fourCCText(d.fourCC)) \(d.width)×\(d.height) preset-after-start=\(session.sessionPreset.rawValue)"
          )
        } else {
          print("    NO DELIVERY within 5 s")
        }
      }
      print("  --- end activeFormat experiment ---")

      // PRESET GOVERNS? Test whether the session preset — not activeFormat —
      // is the knob that determines delivered geometry on macOS 27: apply
      // activeFormat first, then discrete presets, and compare delivery.
      print("  --- session preset experiment ---")
      let formatsUnderTest = dev.formats.enumerated().filter { elem in
        let d = CMVideoFormatDescriptionGetDimensions(elem.element.formatDescription)
        return Int(d.width) != 1920 || Int(d.height) != 1080
      }.prefix(3)
      for (i, fmt) in formatsUnderTest {
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let presets: [AVCaptureSession.Preset] = [
          .high, .vga640x480, .iFrame1280x720, .hd4K3840x2160,
        ]
        for preset in presets {
          let session = AVCaptureSession()
          guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input)
          else { continue }
          session.addInput(input)
          do {
            try dev.lockForConfiguration()
            defer { dev.unlockForConfiguration() }
            dev.activeFormat = fmt
          } catch { continue }
          guard session.canSetSessionPreset(preset) else {
            print(
              "    fmt[\(i)] \(dims.width)×\(dims.height) preset=\(preset.rawValue): not supported by session"
            )
            continue
          }
          session.sessionPreset = preset
          let output = AVCaptureVideoDataOutput()
          output.videoSettings = [:] as [String: Any]
          guard session.canAddOutput(output) else { continue }
          session.addOutput(output)
          let exp = expectation()
          let box = DeliveryBox()
          let delegate = ProbeDelegate { buffer in
            if let fd = CMSampleBufferGetFormatDescription(buffer) {
              let d = CMVideoFormatDescriptionGetDimensions(fd)
              box.set(
                fourCC: CMFormatDescriptionGetMediaSubType(fd),
                width: Int(d.width), height: Int(d.height))
            }
            exp.fulfill()
          }
          output.setSampleBufferDelegate(
            delegate, queue: DispatchQueue(label: "probe.video.preset"))
          session.startRunning()
          let delivered = await wait(exp, seconds: 4)
          session.stopRunning()
          if delivered {
            let d = box.get()
            print(
              "    fmt[\(i)] \(dims.width)×\(dims.height) + preset=\(preset.rawValue) -> delivered \(d.width)×\(d.height) \(fourCCText(d.fourCC))"
            )
          } else {
            print(
              "    fmt[\(i)] \(dims.width)×\(dims.height) + preset=\(preset.rawValue) -> NO DELIVERY within 4 s"
            )
          }
        }
      }
      print("  --- end session preset experiment ---")

      // ORDERING EXPERIMENT on the largest-area non-16:9 format: does
      // activeFormat stick if set (1) before the input joins the session, or
      // (2) while the session is running?
      print("  --- activeFormat ordering experiment ---")
      if let target = dev.formats.enumerated().first(where: { elem in
        let d = CMVideoFormatDescriptionGetDimensions(elem.element.formatDescription)
        return Int(d.width) == 1552 && Int(d.height) == 1552
      })
        ?? dev.formats.enumerated().first(where: { elem in
          let d = CMVideoFormatDescriptionGetDimensions(elem.element.formatDescription)
          return Int(d.width) != 1920 || Int(d.height) != 1080
        })
      {
        let (index, fmt) = target
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)

        // (1) Set before the input is added.
        do {
          let session = AVCaptureSession()
          do {
            try dev.lockForConfiguration()
            dev.activeFormat = fmt
            dev.unlockForConfiguration()
          } catch { print("    ordering/1: lock failed: \(error.localizedDescription)") }
          if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [:] as [String: Any]
            if session.canAddOutput(output) {
              session.addOutput(output)
              let exp = expectation()
              let box = DeliveryBox()
              let delegate = ProbeDelegate { buffer in
                if let fd = CMSampleBufferGetFormatDescription(buffer) {
                  let d = CMVideoFormatDescriptionGetDimensions(fd)
                  box.set(
                    fourCC: CMFormatDescriptionGetMediaSubType(fd), width: Int(d.width),
                    height: Int(d.height))
                }
                exp.fulfill()
              }
              output.setSampleBufferDelegate(
                delegate, queue: DispatchQueue(label: "probe.video.order1"))
              session.startRunning()
              let delivered = await wait(exp, seconds: 4)
              session.stopRunning()
              let readback = CMVideoFormatDescriptionGetDimensions(
                dev.activeFormat.formatDescription)
              print(
                "    ordering/1 fmt[\(index)] \(dims.width)×\(dims.height) set-before-input: activeFormat-readback=\(readback.width)×\(readback.height) delivered=\(delivered ? "\(box.get().width)×\(box.get().height)" : "none")"
              )
            }
          }
        }

        // (2) Set while the session is running.
        do {
          let session = AVCaptureSession()
          if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [:] as [String: Any]
            if session.canAddOutput(output) {
              session.addOutput(output)
              let exp = expectation()
              output.setSampleBufferDelegate(
                ProbeDelegate { _ in exp.fulfill() },
                queue: DispatchQueue(label: "probe.video.order2"))
              session.startRunning()
              _ = await wait(exp, seconds: 4)  // warm up at the default format first
              do {
                try dev.lockForConfiguration()
                dev.activeFormat = fmt
                dev.unlockForConfiguration()
              } catch { print("    ordering/2: lock failed: \(error.localizedDescription)") }
              let exp2 = expectation()
              let box = DeliveryBox()
              output.setSampleBufferDelegate(
                ProbeDelegate { buffer in
                  if let fd = CMSampleBufferGetFormatDescription(buffer) {
                    let d = CMVideoFormatDescriptionGetDimensions(fd)
                    box.set(
                      fourCC: CMFormatDescriptionGetMediaSubType(fd), width: Int(d.width),
                      height: Int(d.height))
                  }
                  exp2.fulfill()
                }, queue: DispatchQueue(label: "probe.video.order2b"))
              let delivered = await wait(exp2, seconds: 4)
              session.stopRunning()
              let d = box.get()
              let readback = CMVideoFormatDescriptionGetDimensions(
                dev.activeFormat.formatDescription)
              print(
                "    ordering/2 fmt[\(index)] \(dims.width)×\(dims.height) set-while-running: activeFormat-readback=\(readback.width)×\(readback.height) delivered=\(delivered ? "\(d.width)×\(d.height)" : "none")"
              )
            }
          }
        }
      }
      print("  --- end activeFormat ordering experiment ---")

      // CMIO override-while-running: does setting the CMIO stream format
      // change what an already-running AVFoundation session delivers?
      if dev.formats.indices.contains(6) {
        await CMIOProbe.overrideWhileAVFoundationRuns(
          deviceUID: dev.uniqueID,
          square: dev.formats[6].formatDescription)
      }

      // CMIO HAL diagnostics run while no AVFoundation session is active.
      await CMIOProbe.run(matchingUIDs: [dev.uniqueID])

      // STILL-PHOTO PIPELINE: AVCapturePhotoOutput negotiates differently
      // from the streaming output and may honor the selected activeFormat
      // for still captures even where the video path does not.
      // Opt-in with --photo: on this toolchain the KVO dynamic subclass the
      // photo output installs aborts the process (ad-hoc CLT build).
      print("  --- photo output experiment ---")
      if CommandLine.arguments.contains("--photo") {
        if let square = dev.formats.first(where: { fmt in
          let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
          return Int(d.width) == 1552 && Int(d.height) == 1552
        }) {
          do {
            let session = AVCaptureSession()
            guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input)
            else {
              print("    photo: cannot add input")
              continue
            }
            session.addInput(input)
            do {
              try dev.lockForConfiguration()
              dev.activeFormat = square
              dev.unlockForConfiguration()
            } catch { print("    photo: lock failed: \(error.localizedDescription)") }
            let readback = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
            print(
              "    photo: activeFormat readback \(readback.width)×\(readback.height) preset=\(session.sessionPreset.rawValue)"
            )
            let photoOutput = AVCapturePhotoOutput()
            guard session.canAddOutput(photoOutput) else {
              print("    photo: cannot add photo output")
              continue
            }
            session.addOutput(photoOutput)
            session.startRunning()
            try? await Task.sleep(nanoseconds: 500_000_000)  // let the photo output become ready
            let box = PhotoBox()
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: box)
            _ = box.wait(seconds: 6)
            session.stopRunning()
            if let dims = box.result {
              print(
                "    photo STILL (activeFormat 1552×1552): delivered photo pixel buffer \(dims.width)×\(dims.height) fourCC=\(fourCCText(dims.fourCC))"
              )
            } else {
              print("    photo: no photo callback within 5 s (error: \(box.errorText ?? "none"))")
            }
          }
        }
      }
      print("  --- end photo output experiment ---")

      // Default delivery with an explicitly EMPTY (non-nil) dictionary.
      // This is exactly the TN3121 distinction the product requires us to
      // verify: does the installed SDK retain an empty dictionary (native
      // delivery) or normalize it to nil (default uncompressed output)?
      let output = AVCaptureVideoDataOutput()
      output.videoSettings = [:] as [String: Any]
      if output.videoSettings == nil {
        print(
          "  VERIFIED-CONVERSION: empty dictionary was normalized to nil -> default uncompressed delivery (documented conversion)"
        )
      } else {
        let keys = output.videoSettings!.keys
        print(
          "  videoSettings after [:] -> \(keys.count) keys (empty dictionary retained, not nil)")
      }
      let session = AVCaptureSession()
      if let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
        session.addInput(input)
        if session.canAddOutput(output) {
          session.addOutput(output)
          let exp = expectation()
          let box = DeliveryBox()
          let delegate = ProbeDelegate { buffer in
            if let fd = CMSampleBufferGetFormatDescription(buffer) {
              let d = CMVideoFormatDescriptionGetDimensions(fd)
              box.set(
                fourCC: CMFormatDescriptionGetMediaSubType(fd),
                width: Int(d.width), height: Int(d.height))
            }
            exp.fulfill()
          }
          output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "probe.video"))
          session.startRunning()
          _ = await wait(exp, seconds: 5)
          session.stopRunning()
          let d = box.get()
          print("  delivered fourCC=\(fourCCText(d.fourCC)) \(d.width)×\(d.height)")
        }
      }
    }

    // CMIO HAL diagnostics run last, after all AVFoundation sessions stopped;
    // allow AVFoundation's internal reconfiguration to settle first —
    // concurrent CMIO property access races in the camera plugin otherwise.
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    await CMIOProbe.run(matchingUIDs: builtInUIDs)
    exit(0)
  }
}

/// Thread-safe delivery record for the probe.
final class DeliveryBox: @unchecked Sendable {
  private let lock = NSLock()
  private var fourCC: UInt32 = 0
  private var width = 0
  private var height = 0

  func set(fourCC: UInt32, width: Int, height: Int) {
    lock.lock()
    defer { lock.unlock() }
    self.fourCC = fourCC
    self.width = width
    self.height = height
  }

  func get() -> (fourCC: UInt32, width: Int, height: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (fourCC, width, height)
  }
}

/// Photo-capture delegate collecting the delivered pixel-buffer geometry.
final class PhotoBox: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
  private let exp = ProbeExpectation()
  private let lock = NSLock()
  private var fourCC: UInt32 = 0
  private var width = 0
  private var height = 0
  private var got = false
  var errorText: String?

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishCaptureFor photoCapture: AVCaptureResolvedPhotoSettings,
    error: Error?
  ) {
    lock.lock()
    if let error, errorText == nil { errorText = error.localizedDescription }
    lock.unlock()
    exp.fulfill()
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    lock.lock()
    if let pb = photo.pixelBuffer {
      fourCC = CVPixelBufferGetPixelFormatType(pb)
      width = CVPixelBufferGetWidth(pb)
      height = CVPixelBufferGetHeight(pb)
      got = true
    }
    if let error { errorText = error.localizedDescription }
    lock.unlock()
    exp.fulfill()
  }

  func wait(seconds: Double) -> Bool {
    exp.wait(seconds: seconds)
  }

  var result: (fourCC: UInt32, width: Int, height: Int)? {
    lock.lock()
    defer { lock.unlock() }
    return got ? (fourCC, width, height) : nil
  }
}
