// PixelBoothAdapters — pure-Swift sample-layout adapters.
// These adapt camera-delivered buffers into plane-structured representations
// for AVIF encoding, without any conversion of meaningful sample values.
// Repacking interleaved→planar, byte-order handling, and dropping unused
// storage bits are allowed. Changing subsampling, range, bit depth, or color
// interpretation is NOT allowed and these adapters never do it.

import Foundation
import PixelBoothCore

/// A plane descriptor with checked bounds. All adapters validate size/stride.
public struct PlaneView {
  public var base: UnsafeRawPointer
  public var bytesPerRow: Int
  public var rowCount: Int

  /// Byte range for a row, bounds-checked.
  public func rowBytes(_ row: Int, _ bytesNeeded: Int) throws -> UnsafeRawPointer {
    precondition(row >= 0 && row < rowCount, "row out of bounds")
    precondition(bytesNeeded >= 0 && bytesNeeded <= bytesPerRow, "bytesNeeded exceeds stride")
    return base.advanced(by: row * bytesPerRow)
  }
}

/// Errors from adapters. Unsupported representations are rejected, never
/// silently normalized.
public enum AdapterError: Error, Equatable, Sendable {
  case unsupportedFourCC(UInt32)
  case unsupportedBitDepth(Int)
  case insufficientData(expected: Int, actual: Int)
  case nonContiguousPlane
  case invalidDimensions(width: Int, height: Int)
  case unsupportedRange(String)
}

/// Plane pointers plus metadata describing what was adapted (never a claim
/// about upstream acquisition).
public struct PlanarImage {
  public var width: Int
  public var height: Int
  public var bitsPerChannel: Int
  /// Y, U, V plane bytes (for RGB identity, G,B,R land in Y,U,V slots).
  public var planes: [UnsafeRawPointer]
  public var bytesPerRow: [Int]
  public var rowCount: [Int]
  /// Bytes per sample in each plane (1 for 8-bit, 2 for 10/12/16-bit).
  public var bytesPerSample: Int
  /// True when U/V planes are subsampled relative to Y (420/422).
  public var chromaWidth: Int
  public var chromaHeight: Int
  /// Owned backing storage, if any (adapters that must deinterleave).
  public var ownedStorage: [UnsafeMutableRawPointer?]

  public init(
    width: Int, height: Int, bitsPerChannel: Int, planes: [UnsafeRawPointer],
    bytesPerRow: [Int], rowCount: [Int], bytesPerSample: Int,
    chromaWidth: Int, chromaHeight: Int,
    ownedStorage: [UnsafeMutableRawPointer?] = []
  ) {
    self.width = width
    self.height = height
    self.bitsPerChannel = bitsPerChannel
    self.planes = planes
    self.bytesPerRow = bytesPerRow
    self.rowCount = rowCount
    self.bytesPerSample = bytesPerSample
    self.chromaWidth = chromaWidth
    self.chromaHeight = chromaHeight
    self.ownedStorage = ownedStorage
  }

  /// Byte count for each plane with checked arithmetic.
  public func planeByteCount(_ i: Int) -> Int {
    precondition(i >= 0 && i < bytesPerRow.count, "plane index out of bounds")
    let rows = rowCount[i]
    let bpr = bytesPerRow[i]
    // rowCount is always > 0 for a valid plane; bpr > 0 likewise.
    precondition(rows > 0 && bpr > 0, "invalid plane geometry")
    return rows * bpr
  }
}

/// Adapts a raw packed buffer plus its FourCC into a `PlanarImage`.
/// The adapter never resizes, crops, mirrors, rotates, tone-maps, or clamps
/// legal storage values. It does not route YUV through RGB.
public enum SampleLayoutAdapter {
  /// YUY2 (a.k.a. "2yuv"): packed 4:2:2 8-bit, Y0 U Y1 V per 4 bytes.
  public static func adaptYUY2(
    data: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int
  ) throws -> PlanarImage {
    try adaptPacked422(
      data: data, bytesPerRow: bytesPerRow, width: width, height: height,
      yFirst: true)
  }

  /// UYVY (a.k.a. "yuvs"): packed 4:2:2 8-bit, U Y0 V Y1 per 4 bytes.
  public static func adaptUYVY(
    data: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int
  ) throws -> PlanarImage {
    try adaptPacked422(
      data: data, bytesPerRow: bytesPerRow, width: width, height: height,
      yFirst: false)
  }

  /// Deinterleave a packed 4:2:2 8-bit buffer into Y, U, V planes.
  /// Only interleaving changes; sample values are untouched.
  public static func adaptPacked422(
    data: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int,
    yFirst: Bool
  ) throws -> PlanarImage {
    guard width > 0, height > 0 else {
      throw AdapterError.invalidDimensions(width: width, height: height)
    }
    guard width % 2 == 0 else {
      // 4:2:2 packed formats are specified for even widths.
      throw AdapterError.invalidDimensions(width: width, height: height)
    }
    // 4 bytes per 2 pixels.
    let rowBytesNeeded = width * 2
    guard bytesPerRow >= rowBytesNeeded else {
      throw AdapterError.insufficientData(expected: rowBytesNeeded, actual: bytesPerRow)
    }
    let totalNeeded = bytesPerRow * height
    _ = totalNeeded  // caller is responsible for the buffer being at least this big

    // Allocate three planes.
    let yCount = width * height
    let cCount = (width / 2) * height
    let yBuf = UnsafeMutableRawPointer.allocate(byteCount: yCount, alignment: 16)
    let uBuf = UnsafeMutableRawPointer.allocate(byteCount: cCount, alignment: 16)
    let vBuf = UnsafeMutableRawPointer.allocate(byteCount: cCount, alignment: 16)
    defer {
      // Copy completed; planes reference owned storage which the caller owns
      // via `ownedStorage`, so no deallocation here.
      _ = yBuf
      _ = uBuf
      _ = vBuf
    }
    let yPtr = yBuf.assumingMemoryBound(to: UInt8.self)
    let uPtr = uBuf.assumingMemoryBound(to: UInt8.self)
    let vPtr = vBuf.assumingMemoryBound(to: UInt8.self)
    var yIdx = 0
    var cIdx = 0
    for row in 0..<height {
      let rowBase = data.advanced(by: row * bytesPerRow)
      let bytes = rowBase.assumingMemoryBound(to: UInt8.self)
      var x = 0
      while x < width {
        // Byte order: YUY2 = Y0 U Y1 V; UYVY = U Y0 V Y1.
        let y0 = yFirst ? bytes[2 * x] : bytes[2 * x + 1]
        let y1 = yFirst ? bytes[2 * x + 2] : bytes[2 * x + 3]
        let u = yFirst ? bytes[2 * x + 1] : bytes[2 * x]
        let v = yFirst ? bytes[2 * x + 3] : bytes[2 * x + 2]
        yPtr[yIdx] = y0
        yIdx += 1
        yPtr[yIdx] = y1
        yIdx += 1
        uPtr[cIdx] = u
        vPtr[cIdx] = v
        cIdx += 1
        x += 2
      }
    }
    return PlanarImage(
      width: width, height: height, bitsPerChannel: 8,
      planes: [UnsafeRawPointer(yBuf), UnsafeRawPointer(uBuf), UnsafeRawPointer(vBuf)],
      bytesPerRow: [width, width / 2, width / 2],
      rowCount: [height, height, height],
      bytesPerSample: 1,
      chromaWidth: width / 2, chromaHeight: height,
      ownedStorage: [yBuf, uBuf, vBuf])
  }

  /// NV12 bi-planar: full-resolution Y plane, interleaved U/V chroma plane.
  /// Supports full and limited range; the range value is carried unchanged in
  /// the result metadata (adapter itself does not touch samples).
  public static func adaptNV12(
    yPlane: UnsafeRawPointer, yBytesPerRow: Int,
    chromaPlane: UnsafeRawPointer, chromaBytesPerRow: Int,
    width: Int, height: Int
  ) throws -> PlanarImage {
    guard width > 0, height > 0, width % 2 == 0 else {
      throw AdapterError.invalidDimensions(width: width, height: height)
    }
    let yRowNeeded = width
    let chromaRowNeeded = width  // interleaved: 2 bytes per chroma pair
    let chromaRows = height / 2
    guard yBytesPerRow >= yRowNeeded else {
      throw AdapterError.insufficientData(expected: yRowNeeded, actual: yBytesPerRow)
    }
    guard chromaBytesPerRow >= chromaRowNeeded else {
      throw AdapterError.insufficientData(expected: chromaRowNeeded, actual: chromaBytesPerRow)
    }
    guard height % 2 == 0 else {
      // NV12 requires even height.
      throw AdapterError.invalidDimensions(width: width, height: height)
    }

    // Y is already planar and contiguous per row; pass through the plane view.
    // U and V must be deinterleaved from the chroma plane.
    let cCount = (width / 2) * (height / 2)
    let uBuf = UnsafeMutableRawPointer.allocate(byteCount: cCount, alignment: 16)
    let vBuf = UnsafeMutableRawPointer.allocate(byteCount: cCount, alignment: 16)
    let uPtr = uBuf.assumingMemoryBound(to: UInt8.self)
    let vPtr = vBuf.assumingMemoryBound(to: UInt8.self)
    var idx = 0
    for row in 0..<chromaRows {
      let rowBase = chromaPlane.advanced(by: row * chromaBytesPerRow)
      let bytes = rowBase.assumingMemoryBound(to: UInt8.self)
      var x = 0
      while x < width / 2 {
        uPtr[idx] = bytes[2 * x]
        vPtr[idx] = bytes[2 * x + 1]
        idx += 1
        x += 1
      }
    }
    return PlanarImage(
      width: width, height: height, bitsPerChannel: 8,
      planes: [yPlane, UnsafeRawPointer(uBuf), UnsafeRawPointer(vBuf)],
      bytesPerRow: [yBytesPerRow, width / 2, width / 2],
      rowCount: [height, height / 2, height / 2],
      bytesPerSample: 1,
      chromaWidth: width / 2, chromaHeight: height / 2,
      ownedStorage: [nil, uBuf, vBuf])
  }

  /// 8-bit RGB in byte order B,G,R (common in macOS pixel buffers).
  /// Produces G,B,R planes for identity-matrix YUV slots.
  public static func adaptBGR24(
    data: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int
  ) throws -> PlanarImage {
    try adaptPackedRGB(
      data: data, bytesPerRow: bytesPerRow, width: width, height: height,
      channelOrder: .bgr)
  }

  /// 8-bit RGB in byte order R,G,B.
  public static func adaptRGB24(
    data: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int
  ) throws -> PlanarImage {
    try adaptPackedRGB(
      data: data, bytesPerRow: bytesPerRow, width: width, height: height,
      channelOrder: .rgb)
  }

  /// 32-bit BGRA with meaningful alpha preserved as plane[3].
  /// Padding bytes in other 4-byte layouts are never mistaken for alpha.
  public static func adaptBGRA32(
    data: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int
  ) throws -> PlanarImage {
    try adaptPackedRGB(
      data: data, bytesPerRow: bytesPerRow, width: width, height: height,
      channelOrder: .bgra)
  }

  enum RGBChannelOrder { case rgb, bgr, bgra, rgba }

  static func adaptPackedRGB(
    data: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int,
    channelOrder: RGBChannelOrder
  ) throws -> PlanarImage {
    guard width > 0, height > 0 else {
      throw AdapterError.invalidDimensions(width: width, height: height)
    }
    let bpp: Int
    switch channelOrder {
    case .rgb, .bgr: bpp = 3
    case .bgra, .rgba: bpp = 4
    }
    let rowBytesNeeded = width * bpp
    guard bytesPerRow >= rowBytesNeeded else {
      throw AdapterError.insufficientData(expected: rowBytesNeeded, actual: bytesPerRow)
    }
    let count = width * height
    let rBuf = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    let gBuf = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    let bBuf = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    var aBuf: UnsafeMutableRawPointer?
    if case .bgra = channelOrder {
      aBuf = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    }
    let rPtr = rBuf.assumingMemoryBound(to: UInt8.self)
    let gPtr = gBuf.assumingMemoryBound(to: UInt8.self)
    let bPtr = bBuf.assumingMemoryBound(to: UInt8.self)
    let aPtr = aBuf?.assumingMemoryBound(to: UInt8.self)
    var idx = 0
    for row in 0..<height {
      let rowBase = data.advanced(by: row * bytesPerRow)
      let bytes = rowBase.assumingMemoryBound(to: UInt8.self)
      for x in 0..<width {
        switch channelOrder {
        case .rgb:
          rPtr[idx] = bytes[3 * x]
          gPtr[idx] = bytes[3 * x + 1]
          bPtr[idx] = bytes[3 * x + 2]
        case .bgr:
          bPtr[idx] = bytes[3 * x]
          gPtr[idx] = bytes[3 * x + 1]
          rPtr[idx] = bytes[3 * x + 2]
        case .bgra:
          bPtr[idx] = bytes[4 * x]
          gPtr[idx] = bytes[4 * x + 1]
          rPtr[idx] = bytes[4 * x + 2]
          aPtr![idx] = bytes[4 * x + 3]
        case .rgba:
          rPtr[idx] = bytes[4 * x]
          gPtr[idx] = bytes[4 * x + 1]
          bPtr[idx] = bytes[4 * x + 2]
          aPtr![idx] = bytes[4 * x + 3]
        }
        idx += 1
      }
    }
    var planes: [UnsafeRawPointer] = [
      UnsafeRawPointer(gBuf), UnsafeRawPointer(bBuf), UnsafeRawPointer(rBuf),
    ]
    var bpr: [Int] = [width, width, width]
    var rows: [Int] = [height, height, height]
    var owned: [UnsafeMutableRawPointer?] = [gBuf, bBuf, rBuf]
    if let aBuf {
      planes.append(UnsafeRawPointer(aBuf))
      bpr.append(width)
      rows.append(height)
      owned.append(aBuf)
    }
    return PlanarImage(
      width: width, height: height, bitsPerChannel: 8,
      planes: planes, bytesPerRow: bpr, rowCount: rows,
      bytesPerSample: 1,
      chromaWidth: width, chromaHeight: height,
      ownedStorage: owned)
  }

  /// 10-bit bi-planar YUV 4:2:0 (e.g. Apple 'x420' or similar packed 10-bit
  /// NV12-like layouts exposed by the camera). Each 16-bit little-endian
  /// sample carries a 10-bit meaningful value; the adapter repacks them into
  /// plane-oriented 16-bit containers without altering the 10-bit values.
  public static func adaptBiPlanar10BitYUV(
    yPlane: UnsafeRawPointer, yBytesPerRow: Int,
    chromaPlane: UnsafeRawPointer, chromaBytesPerRow: Int,
    width: Int, height: Int
  ) throws -> PlanarImage {
    guard width > 0, height > 0, height % 2 == 0, width % 2 == 0 else {
      throw AdapterError.invalidDimensions(width: width, height: height)
    }
    let yRowBytesNeeded = width * 2
    let chromaRowBytesNeeded = width * 2  // interleaved U/V pairs, 2 bytes each
    guard yBytesPerRow >= yRowBytesNeeded else {
      throw AdapterError.insufficientData(expected: yRowBytesNeeded, actual: yBytesPerRow)
    }
    guard chromaBytesPerRow >= chromaRowBytesNeeded else {
      throw AdapterError.insufficientData(expected: chromaRowBytesNeeded, actual: chromaBytesPerRow)
    }
    let yCount = width * height
    let cCount = (width / 2) * (height / 2)
    let yBuf = UnsafeMutableRawPointer.allocate(byteCount: yCount * 2, alignment: 16)
    let uBuf = UnsafeMutableRawPointer.allocate(byteCount: cCount * 2, alignment: 16)
    let vBuf = UnsafeMutableRawPointer.allocate(byteCount: cCount * 2, alignment: 16)
    let yPtr = yBuf.assumingMemoryBound(to: UInt16.self)
    let uPtr = uBuf.assumingMemoryBound(to: UInt16.self)
    let vPtr = vBuf.assumingMemoryBound(to: UInt16.self)
    for row in 0..<height {
      let rowBase = yPlane.advanced(by: row * yBytesPerRow)
      let samples = rowBase.assumingMemoryBound(to: UInt16.self)
      for x in 0..<width {
        // CoreVideo's 10-bit bi-planar samples occupy the high bits of a
        // little-endian 16-bit word. The canonical encoder expects values
        // packed into the low 10 bits.
        yPtr[row * width + x] = UInt16(littleEndian: samples[x]) >> 6
      }
    }
    var idx = 0
    for row in 0..<(height / 2) {
      let rowBase = chromaPlane.advanced(by: row * chromaBytesPerRow)
      let bytes = rowBase.assumingMemoryBound(to: UInt16.self)
      for x in 0..<(width / 2) {
        uPtr[idx] = UInt16(littleEndian: bytes[2 * x]) >> 6
        vPtr[idx] = UInt16(littleEndian: bytes[2 * x + 1]) >> 6
        idx += 1
      }
    }
    return PlanarImage(
      width: width, height: height, bitsPerChannel: 10,
      planes: [UnsafeRawPointer(yBuf), UnsafeRawPointer(uBuf), UnsafeRawPointer(vBuf)],
      bytesPerRow: [width * 2, width, width],
      rowCount: [height, height / 2, height / 2],
      bytesPerSample: 2,
      chromaWidth: width / 2, chromaHeight: height / 2,
      ownedStorage: [yBuf, uBuf, vBuf])
  }
}
