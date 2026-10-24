import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PixelBoothCapture
import PixelBoothCore
import PixelBoothMetadata

enum CaptureMetadataArchiver {
  static func snapshot(_ frame: DeliveredFrame) -> CaptureAttachmentArchive {
    var result = CaptureAttachmentArchive()
    func record(_ values: [String: Any], scope: String) {
      for key in values.keys.sorted() {
        let value = values[key]!
        let entry: CaptureAttachmentArchive.Entry
        do {
          if CFGetTypeID(value as CFTypeRef) == CGColorSpace.typeID {
            let space = unsafeDowncast(value as AnyObject, to: CGColorSpace.self)
            guard let icc = space.copyICCData() as Data? else {
              throw CapturedCapture.SnapshotError.unsupportedColorDescriptor
            }
            entry = .init(scope: scope, key: key, encoding: "icc-profile", payload: icc)
          } else {
            let data = try PropertyListSerialization.data(
              fromPropertyList: ["value": value], format: .binary, options: 0)
            entry = .init(scope: scope, key: key, encoding: "binary-property-list", payload: data)
          }
        } catch {
          // Unknown non-property-list objects still get a diagnostic. Do not
          // label their textual description a lossless serialization.
          entry = .init(
            scope: scope, key: key, encoding: "diagnostic-description",
            payload: Data(String(describing: value).utf8), exact: false)
          result.issues.append("\(scope).\(key): object could only be retained as a description")
        }
        result.entries.append(entry)
        if isUnmappedRenderingMetadata(key) {
          result.issues.append(
            "\(scope).\(key): original data archived; native rendering support pending")
        }
      }
    }
    func sample(_ sample: CMSampleBuffer, scope: String) {
      for (mode, suffix) in [
        (CMAttachmentMode(1), "propagating"), (CMAttachmentMode(0), "nonpropagating"),
      ] {
        let values =
          CMCopyDictionaryOfAttachments(
            allocator: nil, target: sample, attachmentMode: mode) as? [String: Any] ?? [:]
        record(values, scope: "\(scope).\(suffix)")
      }
      if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        as? [[String: Any]]
      {
        for (index, values) in attachments.enumerated() {
          record(values, scope: "\(scope).sample[\(index)]")
        }
      }
      if let description = CMSampleBufferGetFormatDescription(sample),
        let values = CMFormatDescriptionGetExtensions(description) as? [String: Any]
      {
        record(values, scope: "\(scope).format")
      }
      if let buffer = CMSampleBufferGetImageBuffer(sample) {
        for (mode, suffix) in [
          (CVAttachmentMode.shouldPropagate, "propagating"),
          (.shouldNotPropagate, "nonpropagating"),
        ] {
          let values = CVBufferCopyAttachments(buffer, mode) as? [String: Any] ?? [:]
          record(values, scope: "\(scope).pixels.\(suffix)")
        }
      }
    }
    sample(frame.sampleBuffer, scope: "delivered")
    if let source = frame.sourceSampleBuffer, source !== frame.sampleBuffer {
      sample(source, scope: "source")
    }
    return result
  }

  private static func isUnmappedRenderingMetadata(_ key: String) -> Bool {
    [
      kCVImageBufferMasteringDisplayColorVolumeKey as String,
      kCVImageBufferAmbientViewingEnvironmentKey as String,
      kCVImageBufferLogTransferFunctionKey as String,
      kCVImageBufferGammaLevelKey as String,
      kCMSampleAttachmentKey_HDR10PlusPerFrameData as String,
    ].contains(key)
  }
}

extension CapturedCapture {
  public var hasMetadataReport: Bool {
    metadata.colorEncodingFailure != nil || !(metadata.attachmentArchive?.issues.isEmpty ?? true)
  }

  public var metadataWarningSummary: String? {
    guard hasMetadataReport else { return nil }
    return
      "Metadata needs review. The captured image, attachment archive, and report are retained on this Mac."
  }

  public func metadataReportData() throws -> Data {
    struct Report: Encodable {
      let version = 1
      let applicationVersion = AppVersion.current
      let captureUUID: UUID
      let deviceUniqueID: String
      let captureTime: String
      let sourceFourCC: UInt32
      let pixelFourCC: UInt32?
      let width: Int
      let height: Int
      let metadata: FrameMetadataSnapshot
      let color: ColorDescriptor?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(
      Report(
        captureUUID: uuid, deviceUniqueID: deviceUniqueID, captureTime: acceptedAtISO,
        sourceFourCC: fourCC,
        pixelFourCC: pixelFourCC, width: width, height: height, metadata: metadata, color: color))
  }

  func archivedMetadataProvenance() throws -> [MetadataObservation] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let suffix = uuid.uuidString.replacingOccurrences(of: "-", with: "")
    var observations: [MetadataObservation] = []
    if let history = metadata.streamColorObservations, !history.isEmpty {
      observations.append(
        MetadataObservation(
          key: "StreamColorObservationsV1_\(suffix)",
          rawValueString: String(decoding: try encoder.encode(history), as: UTF8.self),
          provenance: .hostObserved))
    }
    if let archive = metadata.attachmentArchive,
      !archive.entries.isEmpty || !archive.issues.isEmpty
    {
      observations.append(
        MetadataObservation(
          key: "AttachmentArchiveV1_\(suffix)",
          rawValueString: try encoder.encode(archive).base64EncodedString(),
          provenance: .applicationGenerated))
    }
    if hasMetadataReport {
      observations.append(
        MetadataObservation(
          key: "MetadataReportV1_\(suffix)",
          rawValueString: try metadataReportData().base64EncodedString(),
          provenance: .applicationGenerated))
    }
    return observations
  }
}
