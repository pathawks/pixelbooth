// CapturedCapture — an accepted photograph with all provenance needed for
// archival encoding. Immutable after acceptance; owns its payload snapshot
// (retained/copied at acceptance so later buffer reuse cannot mutate it).

import Foundation
import AVFoundation
import CoreVideo
import PixelBoothCore
import PixelBoothCapture
import PixelBoothMetadata
import PixelBoothAdapters
import PixelBoothJPEG

public struct CapturedCapture: Sendable, Codable {
  public var uuid: UUID
  public var fourCC: UInt32
  public var width: Int
  public var height: Int
  public var timestampNanos: UInt64
  public var deviceUniqueID: String
  public var metadata: FrameMetadataSnapshot
  public var acceptedAtISO: String

  /// Immutable archival payload, snapshotted at acceptance:
  /// - MJPEG (`MJPG`): the complete camera JPEG, byte-exact.
  /// - Uncompressed: the adapted planes (G,B,R in Y,U,V slots / Y,U,V), stride
  ///   and geometry recorded, with padding excluded from the canonical hash.
  public enum Payload: Sendable, Codable {
    case jpegBytes([UInt8])
    case planes(PlaneSnapshot)
  }

  public struct PlaneSnapshot: Sendable, Codable, Hashable {
    public var bytesPerRow: [Int]
    public var rows: [Int]
    public var bytesPerSample: Int
    public var chromaWidth: Int
    public var chromaHeight: Int
    /// Contiguous plane bytes only (padding excluded).
    public var contiguous: [[UInt8]]

    init(bytesPerRow: [Int], rows: [Int], bytesPerSample: Int,
         chromaWidth: Int, chromaHeight: Int, contiguous: [[UInt8]]) {
      self.bytesPerRow = bytesPerRow; self.rows = rows
      self.bytesPerSample = bytesPerSample
      self.chromaWidth = chromaWidth; self.chromaHeight = chromaHeight
      self.contiguous = contiguous
    }

    /// Rebuild a PlanarImage referencing freshly copied plane buffers.
    public func asPlanarImage(width: Int, height: Int,
                              planePointers: [UnsafeMutableRawPointer]) -> PlanarImage {
      PlanarImage(
        width: width, height: height,
        bitsPerChannel: bytesPerSample * 8,
        planes: planePointers.map { UnsafeRawPointer($0) },
        bytesPerRow: bytesPerRow, rowCount: rows,
        bytesPerSample: bytesPerSample,
        chromaWidth: chromaWidth, chromaHeight: chromaHeight,
        ownedStorage: [])
    }
  }

  public var payload: Payload

  public init(from frame: DeliveredFrame, metadata: FrameMetadataSnapshot) throws {
    self.uuid = UUID()
    self.fourCC = frame.fourCC
    self.width = frame.width
    self.height = frame.height
    self.timestampNanos = frame.timestampNanos
    self.deviceUniqueID = frame.deviceUniqueID
    self.metadata = metadata
    self.acceptedAtISO = frame.hostWallClockISO
    // Snapshot the immutable payload at acceptance.
    if frame.fourCC == 0x4d4a5047 {
      // MJPEG: complete JPEG passthrough, byte-exact.
      self.payload = .jpegBytes(try FrameExtraction.extractJPEG(from: frame.sampleBuffer))
    } else if let pb = frame.sampleBuffer.imageBuffer as CVPixelBuffer? {
      // Uncompressed: adapt and snapshot contiguous planes (padding excluded).
      let planar = try FrameExtraction.adapt(pb, fourCC: frame.fourCC)
      var contiguous: [[UInt8]] = []
      for (i, plane) in planar.planes.enumerated() {
        let rowCount = planar.rowCount[i]
        let cols = i == 0 ? planar.width : planar.chromaWidth
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rowCount * cols * planar.bytesPerSample)
        for row in 0..<rowCount {
          let p = plane.advanced(by: row * planar.bytesPerRow[i])
          bytes.append(contentsOf: UnsafeRawBufferPointer(
            start: p, count: cols * planar.bytesPerSample))
        }
        bytes.append(contentsOf: [])
        contiguous.append(bytes)
      }
      self.payload = .planes(PlaneSnapshot(
        bytesPerRow: planar.bytesPerRow, rows: planar.rowCount,
        bytesPerSample: planar.bytesPerSample,
        chromaWidth: planar.chromaWidth, chromaHeight: planar.chromaHeight,
        contiguous: contiguous))
    } else {
      throw AdapterError.unsupportedFourCC(frame.fourCC)
    }
  }
}
