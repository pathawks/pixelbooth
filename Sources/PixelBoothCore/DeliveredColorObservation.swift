import Foundation

/// Color metadata explicitly observed on an earlier delivered frame. This is
/// stream evidence, never permission to fill missing values on another frame.
public struct DeliveredColorObservation: Hashable, Sendable, Codable {
  public struct Tags: Hashable, Sendable, Codable {
    public var matrix: String?
    public var primaries: String?
    public var transfer: String?
    public var iccProfileSHA256: String?
    public var colorSpaceICCProfileSHA256: String?

    public init(
      matrix: String? = nil, primaries: String? = nil, transfer: String? = nil,
      iccProfileSHA256: String? = nil, colorSpaceICCProfileSHA256: String? = nil
    ) {
      self.matrix = matrix
      self.primaries = primaries
      self.transfer = transfer
      self.iccProfileSHA256 = iccProfileSHA256
      self.colorSpaceICCProfileSHA256 = colorSpaceICCProfileSHA256
    }
  }

  public var frameIndex: UInt64
  public var deviceUniqueID: String
  public var generation: Int
  public var width: Int
  public var height: Int
  public var fourCC: UInt32
  public var mediaTimeNanos: UInt64
  public var hostMonotonicNanos: UInt64
  public var observedAtISO: String
  public var pixelBuffer: Tags
  public var formatDescription: Tags

  public init(
    frameIndex: UInt64, deviceUniqueID: String, generation: Int,
    width: Int, height: Int, fourCC: UInt32, mediaTimeNanos: UInt64,
    hostMonotonicNanos: UInt64, observedAtISO: String,
    pixelBuffer: Tags, formatDescription: Tags
  ) {
    self.frameIndex = frameIndex
    self.deviceUniqueID = deviceUniqueID
    self.generation = generation
    self.width = width
    self.height = height
    self.fourCC = fourCC
    self.mediaTimeNanos = mediaTimeNanos
    self.hostMonotonicNanos = hostMonotonicNanos
    self.observedAtISO = observedAtISO
    self.pixelBuffer = pixelBuffer
    self.formatDescription = formatDescription
  }
}
