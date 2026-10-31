// Shared JPEG/AVIF finalization. Destination policies own durability and cleanup;
// the exact metadata, sample preservation and verification path is common.

import CryptoKit
import Foundation
import PixelBoothAVIF
import PixelBoothCore
import PixelBoothDepth
import PixelBoothJPEG
import PixelBoothMetadata

struct FinalizedCaptureImage: Sendable {
  let data: Data
  let fileName: String
  let codec: String
  let settings: String

  var hashHex: String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

actor CaptureImageFinalizer {
  private let avifEncodingWorker: AVIFEncodingWorker

  init(
    disparityEstimator: (@Sendable ([UInt8]) async throws -> RelativeDisparityMap)? = nil,
    configurationURL: URL? = nil, modelURL: URL? = nil
  ) {
    avifEncodingWorker = AVIFEncodingWorker(
      disparityEstimator: disparityEstimator, configurationURL: configurationURL, modelURL: modelURL
    )
  }

  func finalize(_ capture: CapturedCapture) async throws -> FinalizedCaptureImage {
    let mapping = CaptureMetadataMapper.map(
      cameraObservations: capture.metadata.cameraObservations,
      uvcControls: capture.metadata.uvcControls,
      usbSerialNumber: capture.metadata.usbIdentity?.serialNumber)
    let flash = capture.metadata.deviceMetadata?.hasFlash == false ? UInt16(0x0020) : nil
    let creatorTool = "PixelBooth \(AppVersion.current)"
    switch capture.payload {
    case .jpegBytes(let bytes):
      // Metadata-only addition; image-coding data stays byte-exact. Never
      // replace or rewrite camera Exif (it may contain unknown tags or
      // MakerNotes). When no source Exif exists, add a standards-based Exif
      // block with the host capture time and optional accepted location.
      let jpegStructure = try JPEGParser.parse(bytes)
      let generatedExif: [UInt8] =
        jpegStructure.exifSegment == nil
        ? ExifBuilder.build(
          make: capture.metadata.deviceIdentity?.manufacturer
            ?? capture.metadata.hostObservedDeviceMake,
          model: capture.metadata.deviceIdentity?.model ?? capture.metadata.hostObservedDeviceModel,
          software: creatorTool,
          captureISO: capture.acceptedAtISO,
          location: capture.metadata.hostLocation,
          fNumber: mapping.fNumber?.value,
          focalLength: mapping.focalLength?.value,
          focalLengthIn35mmFilm: mapping.focalLengthIn35mmFilm?.value,
          bodySerialNumber: mapping.bodySerialNumber?.value,
          pixelXDimension: UInt32(exactly: capture.width),
          pixelYDimension: UInt32(exactly: capture.height),
          flash: flash,
          exposureTimeSeconds: mapping.exposureTimeSeconds?.value,
          exposureMode: mapping.exposureMode?.value,
          whiteBalance: mapping.whiteBalance?.value)
        : []
      let additionalExif = generatedExif.isEmpty ? nil : generatedExif
      let xmp = PixelBoothXMP.build(
        captureUUID: capture.uuid, appVersion: AppVersion.current,
        captureBackend: capture.metadata.captureBackend ?? "unknown",
        backendVersion: capture.metadata.captureBackendVersion ?? "unknown",
        libavifVersion: LosslessAVIF.libraryVersion,
        actualCaptureFormat:
          "\(CaptureFormat.fourCCString(capture.pixelFourCC ?? capture.fourCC)) \(capture.width)×\(capture.height)",
        encoderSettings: "metadata-only",
        metadataProvenance: try Self.metadataProvenance(capture, mapping: mapping),
        fidelity: capture.acquisitionEvidence.map { Self.fidelityName($0.fidelity) } ?? "unknown",
        hostLocation: capture.metadata.hostLocation,
        mediaTimeNanos: capture.timestampNanos,
        wallClockAnchorISO: capture.metadata.wallClockAnchorISO,
        sourceFormat: CaptureFormat.fourCCString(capture.fourCC),
        dataSource: String(describing: capture.dataSource ?? .unknown),
        creatorTool: creatorTool,
        frameDurationSeconds: capture.metadata.frameDurationSeconds,
        pixelFormat: capture.metadata.deliveredPixelFormat,
        videoRange: capture.metadata.videoRange,
        activeEffects: capture.metadata.deviceMetadata?.activeEffects ?? [],
        warmupFrames: capture.metadata.warmupFrames)
      let withMeta = try JPEGMetadataWriter.withAdditionalMetadata(
        original: bytes, additionalXMP: xmp, additionalExif: additionalExif)
      return FinalizedCaptureImage(
        data: Data(withMeta), fileName: "capture.jpg",
        codec: "jpeg-passthrough", settings: "metadata-only")

    case .planes(let snapshot):
      let dimensions = try snapshot.nativeDimensions()
      let portraitRenderIntent =
        capture.metadata.includeEstimatedDisparity == true
        ? try PortraitRenderIntent(primaryWidth: dimensions.width, primaryHeight: dimensions.height)
        : nil
      // Lossless AVIF from planes, verified by exact native-channel decode.
      // Metadata: the same application XMP provenance model as the JPEG path,
      // plus Exif carrying the host-observed device identity and capture time
      // (Photos reads Exif; the XMP labels that provenance as host-observed —
      // never presented as camera-provided metadata).
      let provenance =
        try Self.metadataProvenance(capture, mapping: mapping)
      let generatedXMP = PixelBoothXMP.build(
        captureUUID: capture.uuid, appVersion: AppVersion.current,
        captureBackend: capture.metadata.captureBackend ?? "unknown",
        backendVersion: capture.metadata.captureBackendVersion ?? "unknown",
        libavifVersion: LosslessAVIF.libraryVersion,
        actualCaptureFormat:
          "\(CaptureFormat.fourCCString(capture.pixelFourCC ?? capture.fourCC)) \(dimensions.width)×\(dimensions.height)",
        encoderSettings: "quality=100 speed=0 (lossless, round-trip verified)",
        metadataProvenance: provenance,
        fidelity: capture.acquisitionEvidence.map { Self.fidelityName($0.fidelity) } ?? "unknown",
        hostLocation: capture.metadata.hostLocation,
        mediaTimeNanos: capture.timestampNanos,
        wallClockAnchorISO: capture.metadata.wallClockAnchorISO,
        sourceFormat: CaptureFormat.fourCCString(capture.fourCC),
        dataSource: String(describing: capture.dataSource ?? .unknown),
        portraitRenderIntent: portraitRenderIntent,
        creatorTool: creatorTool,
        frameDurationSeconds: capture.metadata.frameDurationSeconds,
        pixelFormat: capture.metadata.deliveredPixelFormat,
        videoRange: capture.metadata.videoRange,
        activeEffects: capture.metadata.deviceMetadata?.activeEffects ?? [],
        warmupFrames: capture.metadata.warmupFrames)
      let xmp: [UInt8]
      if let sourceXMP = capture.metadata.embeddedSourceXMP {
        xmp = try JPEGMetadataWriter.mergingXMP(source: sourceXMP, additional: generatedXMP)
      } else {
        xmp = generatedXMP
      }
      let exif =
        capture.metadata.embeddedSourceExif
        ?? ExifBuilder.build(
          make: capture.metadata.deviceIdentity?.manufacturer
            ?? capture.metadata.hostObservedDeviceMake,
          model: capture.metadata.deviceIdentity?.model ?? capture.metadata.hostObservedDeviceModel,
          software: creatorTool,
          captureISO: capture.acceptedAtISO,
          location: capture.metadata.hostLocation,
          fNumber: mapping.fNumber?.value,
          focalLength: mapping.focalLength?.value,
          focalLengthIn35mmFilm: mapping.focalLengthIn35mmFilm?.value,
          bodySerialNumber: mapping.bodySerialNumber?.value,
          pixelXDimension: UInt32(exactly: dimensions.width),
          pixelYDimension: UInt32(exactly: dimensions.height),
          flash: flash,
          exposureTimeSeconds: mapping.exposureTimeSeconds?.value,
          exposureMode: mapping.exposureMode?.value,
          whiteBalance: mapping.whiteBalance?.value)
      let (data, settings, disparity) = try await avifEncodingWorker.encode(
        capture, exifPayload: exif, xmpPayload: xmp, portraitRenderIntent: portraitRenderIntent)
      var appliedSettings = "quality=\(settings.quality) speed=\(settings.speed)"
      if let disparity {
        appliedSettings +=
          "; DepthAnythingV2 estimated relative disparity \(disparity.width)×\(disparity.height) fdis/L008, lossless storage verified"
        appliedSettings += "; model=\(disparity.modelIdentifier)"
        if let scale = disparity.renderingScale {
          appliedSettings +=
            "; application relative render scale=\(scale.rawValue) \(disparity.nativeMinimumDisparity)…\(disparity.nativeMaximumDisparity)"
        }
        if let intent = disparity.portraitRenderIntent {
          appliedSettings +=
            "; application render intent v1: simulated aperture \(intent.simulatedAperture), center focus; Photos Portrait recognition unverified"
        }
      }
      return FinalizedCaptureImage(
        data: Data(data), fileName: "capture.avif", codec: settings.codec, settings: appliedSettings
      )
    }
  }

  private static func fidelityName(_ fidelity: AcquisitionFidelity) -> String {
    switch fidelity {
    case .nativePreserved: return "nativePreserved"
    case .macDeliveredConverted: return "macDeliveredConverted"
    case .macDeliveredUnknownUpstream: return "macDeliveredUnknownUpstream"
    }
  }

  /// Host-observed device identity and camera-provided value provenance for
  /// the application XMP. The backend-reported device manufacturer/name are
  /// labeled hostObserved; the Exif mirror and application policy fields are
  /// labeled applicationGenerated.
  private static func metadataProvenance(
    _ capture: CapturedCapture, mapping: CaptureMetadataMapping
  ) throws -> [MetadataObservation] {
    var provenance: [MetadataObservation] = []
    if let make = capture.metadata.hostObservedDeviceMake, !make.isEmpty {
      provenance.append(
        MetadataObservation(
          key: "DeviceMake", rawValueString: make, provenance: .hostObserved))
    }
    if let model = capture.metadata.hostObservedDeviceModel, !model.isEmpty {
      provenance.append(
        MetadataObservation(
          key: "DeviceModel", rawValueString: model, provenance: .hostObserved))
    }
    if let modelID = capture.metadata.hostObservedDeviceModelID, !modelID.isEmpty {
      provenance.append(
        MetadataObservation(
          key: "DeviceModelID", rawValueString: modelID, provenance: .hostObserved))
    }
    if let usb = capture.metadata.usbIdentity {
      let values: [(String, String?)] = [
        ("USBVendorID", String(format: "0x%04X", usb.vendorID)),
        ("USBProductID", String(format: "0x%04X", usb.productID)),
        ("USBLocationID", String(format: "0x%08X", usb.locationID)),
        ("USBManufacturerString", usb.manufacturer), ("USBProductString", usb.productName),
        ("USBAssociationMethod", usb.associationMethod),
      ]
      for (key, value) in values {
        if let value {
          provenance.append(
            MetadataObservation(
              key: key, rawValueString: value, provenance: .hostObserved,
              observedAtISO: usb.observedAtISO))
        }
      }
    }
    if let identity = capture.metadata.deviceIdentity {
      if let value = identity.manufacturer, let source = identity.manufacturerSource {
        provenance.append(
          MetadataObservation(
            key: "ResolvedDeviceMake", rawValueString: value,
            provenance: source.provenance))
        provenance.append(
          MetadataObservation(
            key: "DeviceMakeSource", rawValueString: source.rawValue,
            provenance: .applicationGenerated))
      }
      if let value = identity.model, let source = identity.modelSource {
        provenance.append(
          MetadataObservation(
            key: "ResolvedDeviceModel", rawValueString: value,
            provenance: source.provenance))
      }
    }
    provenance.append(
      MetadataObservation(
        key: "ExifMakeModelMirroredFromHostObservedDeviceIdentity",
        rawValueString: capture.metadata.embeddedSourceExif == nil
          && capture.metadata.deviceIdentity == nil
          ? "true" : "false",
        provenance: .applicationGenerated))
    if let serial = mapping.bodySerialNumber {
      provenance.append(
        MetadataObservation(
          key: "USBDeviceSerialString", rawValueString: serial.value,
          provenance: serial.source == .usbIdentity ? .hostObserved : .applicationGenerated,
          observedAtISO: capture.metadata.usbIdentity?.observedAtISO))
      provenance.append(
        MetadataObservation(
          key: "ExifBodySerialNumberSource",
          rawValueString: "USB-host-observed-not-camera-reported",
          provenance: .applicationGenerated))
    }
    if let fNumber = mapping.fNumber {
      provenance.append(
        MetadataObservation(
          key: "ExifFNumberSource", rawValueString: fNumber.raw,
          provenance: fNumber.source == .cameraAttachment ? .cameraProvided : .hostObserved))
    }
    if let focalLength = mapping.focalLength {
      provenance.append(
        MetadataObservation(
          key: "ExifFocalLengthSource", rawValueString: focalLength.raw,
          provenance: focalLength.source == .cameraAttachment ? .cameraProvided : .hostObserved))
    }
    if let focalLength35 = mapping.focalLengthIn35mmFilm {
      provenance.append(
        MetadataObservation(
          key: "ExifFocalLengthIn35mmFilmSource", rawValueString: focalLength35.raw,
          provenance: focalLength35.source == .cameraAttachment ? .cameraProvided : .hostObserved))
    }
    if let exposureTime = mapping.exposureTimeSeconds {
      provenance.append(
        MetadataObservation(
          key: "ExifExposureTimeSource", rawValueString: exposureTime.raw,
          provenance: exposureTime.source == .cameraAttachment ? .cameraProvided : .hostObserved))
    }
    if let exposureMode = mapping.exposureMode {
      provenance.append(
        MetadataObservation(
          key: "ExifExposureModeSource", rawValueString: exposureMode.raw,
          provenance: exposureMode.source == .cameraAttachment ? .cameraProvided : .hostObserved))
    }
    if let whiteBalance = mapping.whiteBalance {
      provenance.append(
        MetadataObservation(
          key: "ExifWhiteBalanceSource", rawValueString: whiteBalance.raw,
          provenance: whiteBalance.source == .cameraAttachment ? .cameraProvided : .hostObserved))
    }
    if let flash = capture.metadata.deviceMetadata?.hasFlash {
      provenance.append(
        MetadataObservation(
          key: "ExifFlashValueSource",
          rawValueString: flash ? "device-has-flash-capability" : "no-flash-function",
          provenance: .applicationGenerated))
    }
    if let deviceType = capture.metadata.deviceMetadata?.deviceType {
      provenance.append(
        MetadataObservation(
          key: "AVCaptureDeviceType", rawValueString: deviceType,
          provenance: .hostObserved))
    }
    provenance.append(contentsOf: capture.metadata.cameraObservations)
    provenance.append(
      contentsOf: CaptureMetadataMapper.uvcObservations(capture.metadata.uvcControls))
    provenance.append(contentsOf: try capture.archivedMetadataProvenance())
    return provenance
  }

}

/// Serializes all AOM work so Save As can request the same encoder without
/// competing with a background Photos encode or exceeding the thread budget.
private actor AVIFEncodingWorker {
  private let estimator: DepthAnythingV2Estimator
  private let testDisparityEstimator: (@Sendable ([UInt8]) async throws -> RelativeDisparityMap)?
  private var encoding = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(
    disparityEstimator: (@Sendable ([UInt8]) async throws -> RelativeDisparityMap)? = nil,
    configurationURL: URL? = nil, modelURL: URL? = nil
  ) {
    self.testDisparityEstimator = disparityEstimator
    self.estimator = DepthAnythingV2Estimator(
      configurationURL: configurationURL, modelURL: modelURL)
  }

  func encode(
    _ capture: CapturedCapture, exifPayload: [UInt8], xmpPayload: [UInt8],
    portraitRenderIntent: PortraitRenderIntent?
  ) async throws -> (
    data: [UInt8], settings: LosslessAVIF.AppliedSettings, disparity: AVIFDisparity.Descriptor?
  ) {
    // Keep the entire job serialized across the estimator actor hop, including
    // an overlapping explicit Save Original request. No second AOM job starts
    // while a primary image and its derived map are in flight.
    if encoding {
      await withCheckedContinuation { waiters.append($0) }
    }
    encoding = true
    defer {
      if waiters.isEmpty {
        encoding = false
      } else {
        waiters.removeFirst().resume()
      }
    }
    try Task.checkCancellation()
    let primary = try capture.encodeAVIF(exifPayload: exifPayload, xmpPayload: xmpPayload)
    guard capture.metadata.includeEstimatedDisparity == true else {
      return (primary.data, primary.settings, nil)
    }
    let map: RelativeDisparityMap
    if let testDisparityEstimator {
      map = try await testDisparityEstimator(primary.data)
    } else {
      map = try await estimator.estimate(avifData: primary.data)
    }
    let result = try AVIFDisparity.attach(
      to: primary.data, width: map.width, height: map.height,
      relativeDisparity: map.values,
      modelIdentifier: map.modelIdentifier,
      preprocessingDescription: map.preprocessingDescription,
      outputDescription: map.outputDescription, portraitRenderIntent: portraitRenderIntent)
    return (result.data, primary.settings, result.descriptor)
  }
}
