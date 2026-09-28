// Headless hardware probe: enumerates real cameras, inspects actual delivered
// sample buffers with an explicitly empty videoSettings dictionary (TN3121),
// and records acquisition-fidelity evidence. Run on hardware with camera
// permission granted.

import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

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

    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.external, .builtInWideAngleCamera],
      mediaType: .video, position: .unspecified)
    print("Discovered devices:")
    for dev in discovery.devices {
      print("  - \(dev.localizedName) [\(dev.uniqueID)] manufacturer=\(dev.manufacturer) connected=\(dev.isConnected)")
    }

    for dev in discovery.devices {
      print("\nDevice: \(dev.localizedName)")
      for (i, fmt) in dev.formats.enumerated().prefix(12) {
        let desc = fmt.formatDescription
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let fourCC = CMFormatDescriptionGetMediaSubType(desc)
        if let r = fmt.videoSupportedFrameRateRanges.first, r.minFrameDuration.seconds > 0 {
          let maxRate = 1.0 / r.minFrameDuration.seconds
          print("  fmt[\(i)] \(dims.width)×\(dims.height) fourCC=\(fourCCText(fourCC)) maxRate=\(String(format: "%.1f", maxRate))")
        }
      }

      // Actual delivery with an explicitly EMPTY (non-nil) dictionary.
      // This is exactly the TN3121 distinction the product requires us to
      // verify: does the installed SDK retain an empty dictionary (native
      // delivery) or normalize it to nil (default uncompressed output)?
      let output = AVCaptureVideoDataOutput()
      output.videoSettings = [:] as [String: Any]
      if output.videoSettings == nil {
        print("  VERIFIED-CONVERSION: empty dictionary was normalized to nil -> default uncompressed delivery (documented conversion)")
      } else {
        let keys = output.videoSettings!.keys
        print("  videoSettings after [:] -> \(keys.count) keys (empty dictionary retained, not nil)")
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
              box.set(fourCC: CMFormatDescriptionGetMediaSubType(fd),
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
    lock.lock(); defer { lock.unlock() }
    self.fourCC = fourCC; self.width = width; self.height = height
  }

  func get() -> (fourCC: UInt32, width: Int, height: Int) {
    lock.lock(); defer { lock.unlock() }
    return (fourCC, width, height)
  }
}
