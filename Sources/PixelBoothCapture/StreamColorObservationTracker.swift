import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import PixelBoothCore

/// Confined to one serial delivery queue. Keeps the first color variant and
/// seven recent distinct variants, including omitted metadata. It never edits
/// a sample or supplies an encoding fallback. A new stream identity resets it.
public struct StreamColorObservationTracker {
  public static let maximumObservations = 8
  private static let maximumTagBytes = 256

  private struct Identity: Equatable {
    let deviceUniqueID: String
    let generation: Int
    let width: Int
    let height: Int
    let fourCC: UInt32
  }

  private var identity: Identity?
  private var frameIndex: UInt64 = 0
  public private(set) var observations: [DeliveredColorObservation] = []

  public init() {}

  public mutating func observe(_ frame: DeliveredFrame) -> [DeliveredColorObservation] {
    let current = Identity(
      deviceUniqueID: frame.deviceUniqueID, generation: frame.generation,
      width: frame.width, height: frame.height, fourCC: frame.fourCC)
    if identity != current {
      identity = current
      frameIndex = 0
      observations.removeAll(keepingCapacity: true)
    }
    if frameIndex < UInt64.max { frameIndex += 1 }
    let pixelBuffer = frame.sampleBuffer.imageBuffer
    let extensions =
      CMSampleBufferGetFormatDescription(frame.sampleBuffer).flatMap {
        CMFormatDescriptionGetExtensions($0) as? [String: Any]
      } ?? [:]
    let pixelTags = Self.tags { key in
      pixelBuffer.flatMap { CVBufferCopyAttachment($0, key, nil) }
    }
    let formatTags = Self.tags { key in extensions[key as String] as CFTypeRef? }
    if !observations.contains(where: {
      $0.pixelBuffer == pixelTags && $0.formatDescription == formatTags
    }) {
      if observations.count == Self.maximumObservations { observations.remove(at: 1) }
      observations.append(
        DeliveredColorObservation(
          frameIndex: frameIndex, deviceUniqueID: frame.deviceUniqueID,
          generation: frame.generation, width: frame.width, height: frame.height,
          fourCC: frame.fourCC, mediaTimeNanos: frame.timestampNanos,
          hostMonotonicNanos: frame.hostMonotonicNanos, observedAtISO: frame.hostWallClockISO,
          pixelBuffer: pixelTags, formatDescription: formatTags))
    }
    return observations
  }

  private static func tags(_ value: (CFString) -> CFTypeRef?) -> DeliveredColorObservation.Tags {
    func string(_ key: CFString) -> String? {
      guard let raw = value(key) else { return nil }
      guard let text = raw as? String else {
        return "non-string value (CFTypeID \(CFGetTypeID(raw)))"
      }
      guard text.utf8.count <= maximumTagBytes else {
        return "value exceeds \(maximumTagBytes) UTF-8 bytes"
      }
      return text
    }
    func digest(_ data: Data?) -> String? {
      data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
    let profile = value(kCVImageBufferICCProfileKey) as? Data
    let colorSpace = value(kCVImageBufferCGColorSpaceKey).flatMap { raw -> CGColorSpace? in
      guard CFGetTypeID(raw) == CGColorSpace.typeID else { return nil }
      return unsafeDowncast(raw as AnyObject, to: CGColorSpace.self)
    }
    return .init(
      matrix: string(kCVImageBufferYCbCrMatrixKey),
      primaries: string(kCVImageBufferColorPrimariesKey),
      transfer: string(kCVImageBufferTransferFunctionKey),
      iccProfileSHA256: digest(profile),
      colorSpaceICCProfileSHA256: digest(colorSpace?.copyICCData() as Data?))
  }
}
