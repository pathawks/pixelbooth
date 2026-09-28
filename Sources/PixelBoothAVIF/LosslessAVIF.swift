import Foundation
import PixelBoothCore
import PixelBoothAdapters
import PixelBoothCAvifShim

/// Lossless AVIF encoding via pinned libavif + libaom.
/// codecChoice = AVIF_CODEC_CHOICE_AOM, quality = AVIF_QUALITY_LOSSLESS,
/// qualityAlpha = AVIF_QUALITY_LOSSLESS (when alpha exists), speed = 0.
/// Every newly encoded AVIF is decoded back and native-channel samples are
/// compared exactly before validation succeeds.
public enum LosslessAVIF {
  public static let libraryVersion = String(cString: pixelbooth_avif_version())

  public enum AVIFError: Error, Equatable, Sendable {
    case imageCreationFailed
    case planePopulationFailed
    case encodingFailed(String)
    case codecNotAOM
    case validationFailed(String)
    case unsupportedLayout(String)
  }

  /// Encoder settings actually applied, for provenance.
  public struct AppliedSettings: Equatable, Sendable, Codable {
    public var codec: String
    public var quality: Int
    public var qualityAlpha: Int
    public var speed: Int
    public var pixelFormat: String
    public var depth: Int
    public var losslessVerified: Bool
  }

  /// Encode a PlanarImage losslessly and verify by decode-compare.
  /// `planes` layout: [Y/G, U/B, V/R] or [Y/G, U/B, V/R, A] for BGRA sources.
  /// For RGB identity coding, callers pass G,B,R into Y,U,V slots and set
  /// `isRGBIdentity` to write correct, non-contradictory color descriptors.
  public static func encodeLossless(
    _ image: PlanarImage,
    isRGBIdentity: Bool,
    yuvRange: CaptureFormat.YUVRange?,
    chromaLocation: CaptureFormat.ChromaLocation?
  ) throws -> (data: [UInt8], settings: AppliedSettings) {
    let depth = image.bitsPerChannel
    guard [8, 10, 12].contains(depth) else {
      throw AVIFError.unsupportedLayout("unsupported bit depth \(depth)")
    }

    guard let avifImage = avifImageCreate(
      UInt32(image.width), UInt32(image.height), UInt32(depth),
      AVIF_PIXEL_FORMAT_YUV444) else {
      throw AVIFError.imageCreationFailed
    }
    defer { avifImageDestroy(avifImage) }

    // Choose pixel format based on geometry.
    if image.chromaWidth == image.width && image.chromaHeight == image.height {
      avifImage.pointee.yuvFormat = AVIF_PIXEL_FORMAT_YUV444
    } else if image.chromaWidth == image.width / 2 && image.chromaHeight == image.height / 2 {
      avifImage.pointee.yuvFormat = AVIF_PIXEL_FORMAT_YUV420
    } else if image.chromaWidth == image.width / 2 && image.chromaHeight == image.height {
      avifImage.pointee.yuvFormat = AVIF_PIXEL_FORMAT_YUV422
    } else {
      throw AVIFError.unsupportedLayout(
        "unsupported chroma geometry \(image.chromaWidth)×\(image.chromaHeight) for \(image.width)×\(image.height)")
    }

    if isRGBIdentity {
      // Identity-matrix, full-range, 4:4:4 representation at the original bit
      // depth. G,B,R land in Y,U,V slots; no YCbCr conversion occurred.
      avifImage.pointee.matrixCoefficients = avifMatrixCoefficients(0) // AVIF_MATRIX_COEFFICIENTS_IDENTITY
      avifImage.pointee.yuvRange = AVIF_RANGE_FULL
      // Do not claim a transfer/primaries we do not know; leave unspecified.
      avifImage.pointee.transferCharacteristics = avifTransferCharacteristics(2) // AVIF_TRANSFER_CHARACTERISTICS_UNSPECIFIED
      avifImage.pointee.colorPrimaries = avifColorPrimaries(2) // AVIF_COLOR_PRIMARIES_UNSPECIFIED
    } else if let range = yuvRange {
      avifImage.pointee.yuvRange = range == .full ? AVIF_RANGE_FULL : AVIF_RANGE_LIMITED
    }

    switch chromaLocation {
    case .left, .topLeft:
      avifImage.pointee.yuvChromaSamplePosition = AVIF_CHROMA_SAMPLE_POSITION_COLOCATED
    case .center:
      avifImage.pointee.yuvChromaSamplePosition = AVIF_CHROMA_SAMPLE_POSITION_VERTICAL
    case nil, .top, .topRight, .bottomLeft, .bottom, .bottomRight:
      avifImage.pointee.yuvChromaSamplePosition = AVIF_CHROMA_SAMPLE_POSITION_UNKNOWN
    }

    // Allocate YUV planes inside the image.
    let allocResult = avifImageAllocatePlanes(avifImage, avifPlanesFlags(AVIF_PLANES_YUV.rawValue))
    guard allocResult == AVIF_RESULT_OK else {
      throw AVIFError.planePopulationFailed
    }

    // Populate planes; no conversion, no clamping, no reordering beyond
    // interleave→plane (allowed) while sample values stay identical.
    let bytesPerSample = depth > 8 ? 2 : 1
    let planeGeometries: [(Int, Int)] = [
      (image.width, image.height),
      (image.chromaWidth, image.chromaHeight),
      (image.chromaWidth, image.chromaHeight),
    ]
    for i in 0..<3 {
      let planesTuple = avifImage.pointee.yuvPlanes
      let rowBytesTuple = avifImage.pointee.yuvRowBytes
      let dst: UnsafeMutablePointer<UInt8> = switch i {
        case 0: planesTuple.0!
        case 1: planesTuple.1!
        default: planesTuple.2!
      }
      let rawBpr: UInt32 = switch i {
        case 0: rowBytesTuple.0
        case 1: rowBytesTuple.1
        default: rowBytesTuple.2
      }
      let dstBpr = Int(rawBpr)
      let (cols, rows) = planeGeometries[i]
      let rowBytes = cols * bytesPerSample
      let src = image.planes[i]
      guard dstBpr >= rowBytes else { throw AVIFError.planePopulationFailed }
      for row in 0..<rows {
        memcpy(dst.advanced(by: row * dstBpr),
               src.advanced(by: row * image.bytesPerRow[i]),
               rowBytes)
      }
    }

    // Alpha plane when meaningful (plane 3 exists for BGRA/RGBA sources).
    var hasAlpha = false
    if image.planes.count > 3, image.rowCount.count > 3, image.bytesPerRow.count > 3 {
      let alphaResult = avifImageAllocatePlanes(avifImage, avifPlanesFlags(AVIF_PLANES_A.rawValue))
      guard alphaResult == AVIF_RESULT_OK else {
        throw AVIFError.planePopulationFailed
      }
      let dst = avifImage.pointee.alphaPlane!
      let dstBpr = Int(avifImage.pointee.alphaRowBytes)
      let rowBytes = image.width * bytesPerSample
      let src = image.planes[3]
      guard dstBpr >= rowBytes else { throw AVIFError.planePopulationFailed }
      for row in 0..<image.height {
        memcpy(dst.advanced(by: row * dstBpr),
               src.advanced(by: row * image.bytesPerRow[3]),
               rowBytes)
      }
      hasAlpha = true
    }

    // Encoder configuration.
    guard let encoder = avifEncoderCreate() else {
      throw AVIFError.encodingFailed("encoder allocation failed")
    }
    defer { avifEncoderDestroy(encoder) }
    encoder.pointee.codecChoice = AVIF_CODEC_CHOICE_AOM
    encoder.pointee.quality = AVIF_QUALITY_LOSSLESS
    encoder.pointee.qualityAlpha = AVIF_QUALITY_LOSSLESS
    encoder.pointee.speed = AVIF_SPEED_SLOWEST

    var output = avifRWData()
    defer { avifRWDataFree(&output) }
    let status = avifEncoderWrite(encoder, avifImage, &output)
    guard status == AVIF_RESULT_OK else {
      throw AVIFError.encodingFailed(
        "avifEncoderWrite: \(String(cString: avifResultToString(status)))")
    }
    guard PixelBoothLibAvif.encoderUsesAOM(encoder) else {
      throw AVIFError.codecNotAOM
    }

    let raw = [UInt8](UnsafeBufferPointer(start: output.data, count: Int(output.size)))

    // Round-trip verification: decode and compare all native-channel samples.
    try verifyLosslessRoundTrip(
      encoded: raw,
      expectedPlanes: Array(image.planes.prefix(3)),
      expectedBytesPerRow: Array(image.bytesPerRow.prefix(3)),
      expectedRowCount: Array(image.rowCount.prefix(3)),
      width: image.width, height: image.height,
      chromaWidth: image.chromaWidth, chromaHeight: image.chromaHeight,
      depth: depth,
      hasAlpha: hasAlpha,
      alphaSrc: hasAlpha ? image.planes[3] : nil,
      alphaBytesPerRow: hasAlpha ? image.bytesPerRow[3] : 0)

    let pixelFormatString = switch avifImage.pointee.yuvFormat {
      case AVIF_PIXEL_FORMAT_YUV444: "YUV444"
      case AVIF_PIXEL_FORMAT_YUV422: "YUV422"
      case AVIF_PIXEL_FORMAT_YUV420: "YUV420"
      case AVIF_PIXEL_FORMAT_YUV400: "YUV400"
      default: "unknown"
    }
    let settings = AppliedSettings(
      codec: "aom", quality: Int(AVIF_QUALITY_LOSSLESS), qualityAlpha: Int(AVIF_QUALITY_LOSSLESS),
      speed: 0, pixelFormat: pixelFormatString, depth: depth, losslessVerified: true)
    return (raw, settings)
  }

  /// Decode an AVIF and compare all native-channel samples exactly.
  /// Does NOT compare only RGB renderings — YUV planes are compared in place.
  public static func verifyLosslessRoundTrip(
    encoded: [UInt8],
    expectedPlanes: [UnsafeRawPointer],
    expectedBytesPerRow: [Int],
    expectedRowCount: [Int],
    width: Int, height: Int,
    chromaWidth: Int, chromaHeight: Int,
    depth: Int,
    hasAlpha: Bool,
    alphaSrc: UnsafeRawPointer?,
    alphaBytesPerRow: Int
  ) throws {
    guard let decoded = avifImageCreateEmpty() else {
      throw AVIFError.validationFailed("decoder image allocation failed")
    }
    defer { avifImageDestroy(decoded) }
    guard let decoder = avifDecoderCreate() else {
      throw AVIFError.validationFailed("decoder allocation failed")
    }
    defer { avifDecoderDestroy(decoder) }
    let parseResult = encoded.withUnsafeBytes { rawBytes -> avifResult in
      guard let base = rawBytes.baseAddress else { return AVIF_RESULT_NO_CONTENT }
      return avifDecoderReadMemory(decoder, decoded, base.assumingMemoryBound(to: UInt8.self), rawBytes.count)
    }
    guard parseResult == AVIF_RESULT_OK else {
      throw AVIFError.validationFailed(
        "decode failed: \(String(cString: avifResultToString(parseResult)))")
    }

    // Compare planes in their native container (8/10/12-bit as stored).
    let bytesPerSample = depth > 8 ? 2 : 1
    let dPlanes = decoded.pointee.yuvPlanes
    let dRowBytes = decoded.pointee.yuvRowBytes
    let decodedPlanes = [
      UnsafeRawPointer(dPlanes.0!), UnsafeRawPointer(dPlanes.1!), UnsafeRawPointer(dPlanes.2!),
    ]
    let decodedRowBytes = [Int(dRowBytes.0), Int(dRowBytes.1), Int(dRowBytes.2)]
    let planeGeometries = [
      (width, height),
      (chromaWidth, chromaHeight),
      (chromaWidth, chromaHeight),
    ]
    for i in 0..<3 {
      let src = expectedPlanes[i]
      let dst = decodedPlanes[i]
      let (cols, rows) = planeGeometries[i]
      let rowBytes = cols * bytesPerSample
      guard decodedRowBytes[i] >= rowBytes else {
        throw AVIFError.validationFailed("decoded plane \(i) stride too small")
      }
      for row in 0..<rows {
        let a = src.advanced(by: row * expectedBytesPerRow[i])
        let b = dst.advanced(by: row * decodedRowBytes[i])
        if memcmp(a, b, rowBytes) != 0 {
          throw AVIFError.validationFailed("plane \(i) row \(row) differs after decode")
        }
      }
    }

    if hasAlpha {
      guard let alphaSrc else { throw AVIFError.validationFailed("missing alpha source") }
      guard let decodedAlpha = decoded.pointee.alphaPlane else {
        throw AVIFError.validationFailed("missing decoded alpha")
      }
      let rowBytes = width * bytesPerSample
      guard Int(decoded.pointee.alphaRowBytes) >= rowBytes else {
        throw AVIFError.validationFailed("decoded alpha stride too small")
      }
      for row in 0..<height {
        let a = alphaSrc.advanced(by: row * alphaBytesPerRow)
        let b = UnsafeRawPointer(decodedAlpha).advanced(by: row * Int(decoded.pointee.alphaRowBytes))
        if memcmp(a, b, rowBytes) != 0 {
          throw AVIFError.validationFailed("alpha row \(row) differs after decode")
        }
      }
    }
  }

  /// Standalone decode helper (used by the test suite as an independent check).
  public static func decode(encoded: [UInt8]) throws -> DecodedImage {
    guard let decoded = avifImageCreateEmpty() else {
      throw AVIFError.validationFailed("decoder image allocation failed")
    }
    defer { avifImageDestroy(decoded) }
    guard let decoder = avifDecoderCreate() else {
      throw AVIFError.validationFailed("decoder allocation failed")
    }
    defer { avifDecoderDestroy(decoder) }
    let parseResult = encoded.withUnsafeBytes { rawBytes -> avifResult in
      guard let base = rawBytes.baseAddress else { return AVIF_RESULT_NO_CONTENT }
      return avifDecoderReadMemory(decoder, decoded, base.assumingMemoryBound(to: UInt8.self), encoded.count)
    }
    guard parseResult == AVIF_RESULT_OK else {
      throw AVIFError.validationFailed(
        "decode failed: \(String(cString: avifResultToString(parseResult)))")
    }
    let depth = Int(decoded.pointee.depth)
    let bytesPerSample = depth > 8 ? 2 : 1
    let w = Int(decoded.pointee.width)
    let h = Int(decoded.pointee.height)

    func extract(_ base: UnsafeMutablePointer<UInt8>?, _ bpr: UInt32, _ rows: Int, _ cols: Int) -> [UInt8] {
      guard let base else { return [] }
      var out = [UInt8]()
      out.reserveCapacity(rows * cols * bytesPerSample)
      for row in 0..<rows {
        let p = UnsafeRawPointer(base).advanced(by: row * Int(bpr))
        out.append(contentsOf: UnsafeRawBufferPointer(start: p, count: cols * bytesPerSample))
      }
      return out
    }

    func extract32(_ base: UnsafeMutablePointer<UInt8>?, _ bpr: UInt32, _ rows: Int, _ cols: Int) -> [UInt8] {
      extract(base, bpr, rows, cols)
    }

    var chromaW = w, chromaH = h
    switch decoded.pointee.yuvFormat {
    case AVIF_PIXEL_FORMAT_YUV444:
      chromaW = w; chromaH = h
    case AVIF_PIXEL_FORMAT_YUV422:
      chromaW = w / 2; chromaH = h
    case AVIF_PIXEL_FORMAT_YUV420:
      chromaW = w / 2; chromaH = h / 2
    case AVIF_PIXEL_FORMAT_YUV400:
      chromaW = 0; chromaH = 0
    default:
      break
    }

    var planes: [[UInt8]] = [
      extract(decoded.pointee.yuvPlanes.0, decoded.pointee.yuvRowBytes.0, h, w),
      extract(decoded.pointee.yuvPlanes.1, decoded.pointee.yuvRowBytes.1, chromaH, chromaW),
      extract(decoded.pointee.yuvPlanes.2, decoded.pointee.yuvRowBytes.2, chromaH, chromaW),
    ]
    if let alphaPlane = decoded.pointee.alphaPlane {
      planes.append(extract32(alphaPlane, decoded.pointee.alphaRowBytes, h, w))
    }
    return DecodedImage(
      width: w, height: h, depth: depth,
      yuvFormat: decoded.pointee.yuvFormat.rawValue,
      matrixCoefficients: Int(decoded.pointee.matrixCoefficients),
      range: Int(decoded.pointee.yuvRange.rawValue),
      planes: planes)
  }

  public struct DecodedImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int
    public var yuvFormat: UInt32
    public var matrixCoefficients: Int
    public var range: Int
    public var planes: [[UInt8]]
  }
}
