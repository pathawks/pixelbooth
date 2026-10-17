// PixelBooth test suite entry point.
// Covers: mode selection ranking, readiness timing, sample-layout adapters,
// lossless AVIF round-trip fidelity, JPEG segment preservation, and metadata
// policy. Hardware-dependent checks are reported "Not run" when the
// environment lacks the hardware or permissions.

import Foundation
import PixelBoothAVIF
import PixelBoothAdapters
import PixelBoothCapture
import PixelBoothCore
import PixelBoothJPEG
import PixelBoothLibrary
import PixelBoothMetadata

@main
struct PixelBoothTestRunner {
  static func main() async {
    await runReproSuite()
    await runModeSelectorSuite()
    await runReadinessSuite()
    await runFreshnessSuite()
    await runAdapterSuite()
    await runJPEGSuite()
    await runAVIFSuite()
    await runCaptureFidelitySuite()
    await runH264PipelineSuite()
    await runAcquisitionPolicySuite()
    await runCaptureDecisionSuite()
    await runMetadataSuite()
    await runMetadataExifSuite()
    await runFourCCSuite()
    await runCaptureConcurrencySuite()
    await runPersistenceSuite()
    await runSaveQueueBufferSuite()
    await runRecoverySuite()
    runHardwareDependentNotes()
    exit(Int32(reportSummary()))
  }
}
