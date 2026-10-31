import CoreMedia
import CoreVideo
import Foundation
import PixelBoothCapture
import PixelBoothLibrary
import PixelBoothMetadata

private enum CameraObservationFixtureError: Error { case setup }

private func cameraObservationFrame() throws -> DeliveredFrame {
  var pixel: CVPixelBuffer?
  guard
    CVPixelBufferCreate(
      nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess,
    let pixel
  else { throw CameraObservationFixtureError.setup }
  var format: CMVideoFormatDescription?
  guard
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format) == noErr,
    let format
  else { throw CameraObservationFixtureError.setup }
  var timing = CMSampleTimingInfo(
    duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 30),
    decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  guard
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil, imageBuffer: pixel, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
    let sample
  else { throw CameraObservationFixtureError.setup }

  CMSetAttachment(
    sample, key: "SampleOptical" as CFString, value: "camera" as CFString,
    attachmentMode: kCMAttachmentMode_ShouldPropagate)
  CMSetAttachment(
    sample, key: "FNumber" as CFString, value: NSNumber(value: 2.4),
    attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
  CMSetAttachment(
    sample, key: "MetadataDictionary" as CFString,
    value: ["Fnumber": NSNumber(value: 1.8), "FocalLength": NSNumber(value: 5.6)] as CFDictionary,
    attachmentMode: kCMAttachmentMode_ShouldPropagate)
  CVBufferSetAttachment(
    pixel, "PixelOptical" as CFString, NSNumber(value: 7), .shouldPropagate)
  CVBufferSetAttachment(
    pixel, "MetadataDictionary" as CFString,
    [
      "ExposureTime": NSNumber(value: 0.0125),
      "WhiteBalance": NSNumber(value: 5200),
      "UnrelatedNestedValue": NSNumber(value: 42),
    ] as CFDictionary,
    .shouldPropagate)
  return DeliveredFrame(
    sampleBuffer: sample, generation: 1, deviceUniqueID: "synthetic",
    fourCC: kCVPixelFormatType_32BGRA, width: 2, height: 2,
    timestampNanos: 1, hostMonotonicNanos: 1, hostWallClockISO: "2026-10-31T00:00:00Z")
}

func runCameraObservationSuite() async {
  suite("CameraObservation")

  await test("collectsPublicSamplePixelAndNestedOpticalAttachments") {
    let frame = try cameraObservationFrame()
    let observations = CameraObservationCollector.collect(from: frame)
    let byKey = Dictionary(grouping: observations, by: \.key)
    check(byKey["SampleOptical"]?.first?.rawValueString == "camera", "sample attachment copied")
    check(byKey["PixelOptical"]?.first?.rawValueString == "7", "pixel attachment copied")
    check(
      byKey["ExifFNumber"]?.contains(where: { $0.rawValueString == "1.8" }) == true,
      "nested Fnumber spelling maps to ExifFNumber")
    check(
      byKey["ExifFNumber"]?.contains(where: { $0.rawValueString == "2.4" }) == true,
      "nonpropagating sample attachment is observed")
    check(
      byKey["ExifFocalLength"]?.first?.rawValueString == "5.6",
      "nested focal length is observed")
    check(
      byKey["ExposureTime"]?.first?.rawValueString == "0.0125",
      "pixel-buffer nested exposure time is observed")
    check(
      byKey["WhiteBalance"]?.first?.rawValueString == "5200",
      "pixel-buffer nested white balance is observed")
    check(byKey["UnrelatedNestedValue"] == nil, "unrelated nested metadata is not flattened")
    check(
      observations.allSatisfy { $0.provenance == .cameraProvided },
      "attachment observations are labeled camera provided")
  }

  await test("normalizesNSNumberAtIntBoundaryWithoutOverflow") {
    let frame = try cameraObservationFrame()
    CMSetAttachment(
      frame.sampleBuffer, key: "BoundaryNumber" as CFString,
      value: NSNumber(value: 9_223_372_036_854_775_808.0),
      attachmentMode: kCMAttachmentMode_ShouldPropagate)
    let observations = CameraObservationCollector.collect(from: frame)
    check(
      observations.contains(where: { $0.key == "BoundaryNumber" }),
      "out-of-range integral NSNumber remains a finite observation")
  }
}
