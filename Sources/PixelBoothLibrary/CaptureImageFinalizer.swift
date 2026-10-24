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
          software: "PixelBooth \(AppVersion.current)",
          captureISO: capture.acceptedAtISO,
          location: capture.metadata.hostLocation)
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
        metadataProvenance: try Self.deviceIdentityProvenance(capture)
          + capture.archivedMetadataProvenance(),
        fidelity: capture.acquisitionEvidence.map { Self.fidelityName($0.fidelity) } ?? "unknown",
        hostLocation: capture.metadata.hostLocation,
        mediaTimeNanos: capture.timestampNanos,
        wallClockAnchorISO: capture.metadata.wallClockAnchorISO,
        sourceFormat: CaptureFormat.fourCCString(capture.fourCC),
        dataSource: String(describing: capture.dataSource ?? .unknown))
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
        try Self.deviceIdentityProvenance(capture) + capture.archivedMetadataProvenance()
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
        portraitRenderIntent: portraitRenderIntent)
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
          software: "PixelBooth \(AppVersion.current)",
          captureISO: capture.acceptedAtISO,
          location: capture.metadata.hostLocation)
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

  /// Host-observed device identity provenance for the application XMP. The
  /// backend-reported device manufacturer/name are labeled hostObserved; the
  /// Exif mirror is labeled applicationGenerated.
  private static func deviceIdentityProvenance(_ capture: CapturedCapture) -> [MetadataObservation]
  {
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
