// Helpers for the headless hardware probe (no XCTest dependency).

import Foundation
import AVFoundation
import CoreMedia

final class ProbeDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  // Narrow documented exception: forwards immutable buffers to a local
  // handler on the probe's own queue.
  private let onFrame: @Sendable (CMSampleBuffer) -> Void

  init(onFrame: @escaping @Sendable (CMSampleBuffer) -> Void) {
    self.onFrame = onFrame
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    onFrame(sampleBuffer)
  }
}

/// Real semaphore-backed expectation for the probe (Sendable via confinement).
final class ProbeExpectation: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)

  func fulfill() { semaphore.signal() }

  func wait(seconds: Double) -> Bool {
    let deadline = DispatchTime.now() + seconds
    return semaphore.wait(timeout: deadline) == .success
  }
}

func expectation() -> ProbeExpectation { ProbeExpectation() }
func wait(_ e: ProbeExpectation, seconds: Double) async -> Bool {
  e.wait(seconds: seconds)
}

func fourCCText(_ v: UInt32) -> String {
  let bytes = [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
               UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
  return bytes.map { b -> String in
    let printable = 0x21...0x7e
    return printable.contains(Int(b)) ? String(UnicodeScalar(b)) : "?"
  }.joined()
}
