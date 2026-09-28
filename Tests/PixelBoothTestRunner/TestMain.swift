// PixelBooth test suite entry point.
// Covers: mode selection ranking, readiness timing, sample-layout adapters,
// lossless AVIF round-trip fidelity, JPEG segment preservation, and metadata
// policy. Hardware-dependent checks are reported "Not run" when the
// environment lacks the hardware or permissions.

import Foundation
import PixelBoothCore
import PixelBoothAdapters
import PixelBoothJPEG
import PixelBoothAVIF
import PixelBoothMetadata
import PixelBoothLibrary
import PixelBoothCapture

@main
struct PixelBoothTestRunner {
  static func main() {
    runModeSelectorSuite()
    runReadinessSuite()
    runAdapterSuite()
    runJPEGSuite()
    runAVIFSuite()
    runMetadataSuite()
    runHardwareDependentNotes()
    exit(Int32(reportSummary()))
  }
}
