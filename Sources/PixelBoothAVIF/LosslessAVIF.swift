import Foundation
import PixelBoothAdapters
import PixelBoothCAvifShim
import PixelBoothCore

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
    chromaLocation: CaptureFormat.ChromaLocation?,
    colorPrimaries: Int? = nil, transferCharacteristics: Int? = nil,
    matrixCoefficients: Int? = nil, iccProfile: [UInt8]? = nil,
    contentLightLevels: [UInt8]? = nil,
    exifPayload: [UInt8]? = nil, xmpPayload: [UInt8]? = nil
  ) throws -> (data: [UInt8], settings: AppliedSettings) {
    let depth = image.bitsPerChannel
    guard [8, 10, 12].contains(depth) else {
      throw AVIFError.unsupportedLayout("unsupported bit depth \(depth)")
    }
    guard image.width > 0, image.height > 0, image.width <= Int(UInt32.max),
      image.height <= Int(UInt32.max),
      image.planes.count == 3 || image.planes.count == 4,
      image.bytesPerRow.count == image.planes.count, image.rowCount.count == image.planes.count,
      image.chromaWidth > 0, image.chromaHeight > 0
    else {
      throw AVIFError.unsupportedLayout("invalid plane geometry")
    }
    if let colorPrimaries, ![1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 22].contains(colorPrimaries) {
      throw AVIFError.unsupportedLayout("invalid CICP primaries \(colorPrimaries)")
    }
    if let transferCharacteristics,
      ![1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18].contains(
        transferCharacteristics)
    {
      throw AVIFError.unsupportedLayout("invalid CICP transfer \(transferCharacteristics)")
    }
    if let matrixCoefficients,
      ![0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14].contains(matrixCoefficients)
    {
      throw AVIFError.unsupportedLayout("invalid CICP matrix \(matrixCoefficients)")
    }
    let valid420 =
      image.chromaWidth == image.width / 2 && image.chromaHeight == image.height / 2
      && image.width % 2 == 0 && image.height % 2 == 0
    let valid422 =
      image.chromaWidth == image.width / 2 && image.chromaHeight == image.height
      && image.width % 2 == 0
    let valid444 = image.chromaWidth == image.width && image.chromaHeight == image.height
    guard valid420 || valid422 || valid444,
      image.bytesPerSample == (depth > 8 ? 2 : 1),
      image.planes.count != 4 || (isRGBIdentity && valid444)
    else {
      throw AVIFError.unsupportedLayout("inconsistent plane geometry or representation")
    }
    let rowCounts = [image.height, image.chromaHeight, image.chromaHeight]
    let rowWidths = [image.width, image.chromaWidth, image.chromaWidth]
    for i in 0..<3 {
      let (needed, overflow) = rowWidths[i].multipliedReportingOverflow(by: image.bytesPerSample)
      guard !overflow, image.rowCount[i] == rowCounts[i], image.bytesPerRow[i] >= needed else {
        throw AVIFError.unsupportedLayout("invalid plane \(i) bounds")
      }
    }
    if image.planes.count == 4 {
      guard image.rowCount[3] == image.height,
        image.bytesPerRow[3] >= image.width * image.bytesPerSample
      else {
        throw AVIFError.unsupportedLayout("invalid alpha plane bounds")
      }
    }

    guard
      let avifImage = avifImageCreate(
        UInt32(image.width), UInt32(image.height), UInt32(depth),
        AVIF_PIXEL_FORMAT_YUV444)
    else {
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
        "unsupported chroma geometry \(image.chromaWidth)×\(image.chromaHeight) for \(image.width)×\(image.height)"
      )
    }

    if isRGBIdentity {
      // Identity-matrix, full-range, 4:4:4 representation at the original bit
      // depth. G,B,R land in Y,U,V slots; no YCbCr conversion occurred.
      // The identity matrix represents AVIF_MATRIX_COEFFICIENTS_IDENTITY.
      avifImage.pointee.matrixCoefficients = avifMatrixCoefficients(0)
      avifImage.pointee.yuvRange = AVIF_RANGE_FULL
      // Do not claim a transfer/primaries we do not know; leave unspecified.
      avifImage.pointee.transferCharacteristics = avifTransferCharacteristics(
        UInt32(transferCharacteristics ?? 2))
      avifImage.pointee.colorPrimaries = avifColorPrimaries(UInt32(colorPrimaries ?? 2))
    } else {
      guard let range = yuvRange else { throw AVIFError.unsupportedLayout("unknown YUV range") }
      avifImage.pointee.yuvRange = range == .full ? AVIF_RANGE_FULL : AVIF_RANGE_LIMITED
      avifImage.pointee.colorPrimaries = avifColorPrimaries(UInt32(colorPrimaries ?? 2))
      avifImage.pointee.transferCharacteristics = avifTransferCharacteristics(
        UInt32(transferCharacteristics ?? 2))
      avifImage.pointee.matrixCoefficients = avifMatrixCoefficients(UInt32(matrixCoefficients ?? 2))
    }

    switch chromaLocation {
    case .topLeft:
      avifImage.pointee.yuvChromaSamplePosition = AVIF_CHROMA_SAMPLE_POSITION_COLOCATED
    case .left:
      avifImage.pointee.yuvChromaSamplePosition = AVIF_CHROMA_SAMPLE_POSITION_VERTICAL
    case nil:
      avifImage.pointee.yuvChromaSamplePosition = AVIF_CHROMA_SAMPLE_POSITION_UNKNOWN
    default:
      throw AVIFError.unsupportedLayout("chroma position is not representable by AVIF")
    }

    if let iccProfile, !iccProfile.isEmpty {
      let result = iccProfile.withUnsafeBufferPointer { bytes in
        avifImageSetProfileICC(avifImage, bytes.baseAddress, bytes.count)
      }
      guard result == AVIF_RESULT_OK else {
        throw AVIFError.unsupportedLayout("ICC profile rejected by libavif")
      }
    }
    if let contentLightLevels {
      guard contentLightLevels.count == 4 else {
        throw AVIFError.unsupportedLayout("invalid CLLI attachment")
      }
      avifImage.pointee.clli.maxCLL =
        UInt16(contentLightLevels[0]) << 8 | UInt16(contentLightLevels[1])
      avifImage.pointee.clli.maxPALL =
        UInt16(contentLightLevels[2]) << 8 | UInt16(contentLightLevels[3])
    }

    // Application metadata: Exif (host-observed device identity, capture
    // time) and the versioned application XMP. Set before encoding; the
    // round-trip verifier below compares them byte-exactly.
    if let exifPayload, !exifPayload.isEmpty {
      let result = exifPayload.withUnsafeBufferPointer { bytes in
        avifImageSetMetadataExif(avifImage, bytes.baseAddress, exifPayload.count)
      }
      guard result == AVIF_RESULT_OK else {
        throw AVIFError.unsupportedLayout("Exif payload rejected by libavif")
      }
    }
    if let xmpPayload, !xmpPayload.isEmpty {
      let result = xmpPayload.withUnsafeBufferPointer { bytes in
        avifImageSetMetadataXMP(avifImage, bytes.baseAddress, xmpPayload.count)
      }
      guard result == AVIF_RESULT_OK else {
        throw AVIFError.unsupportedLayout("XMP payload rejected by libavif")
      }
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
      let dst: UnsafeMutablePointer<UInt8> =
        switch i {
        case 0: planesTuple.0!
        case 1: planesTuple.1!
        default: planesTuple.2!
        }
      let rawBpr: UInt32 =
        switch i {
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
        memcpy(
          dst.advanced(by: row * dstBpr),
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
        memcpy(
          dst.advanced(by: row * dstBpr),
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
      alphaBytesPerRow: hasAlpha ? image.bytesPerRow[3] : 0,
      expectedRange: isRGBIdentity || yuvRange == .full
        ? Int(AVIF_RANGE_FULL.rawValue) : Int(AVIF_RANGE_LIMITED.rawValue),
      expectedPrimaries: colorPrimaries ?? 2,
      expectedTransfer: transferCharacteristics ?? 2,
      expectedMatrix: isRGBIdentity ? 0 : (matrixCoefficients ?? 2),
      expectedChromaPosition: Int(avifImage.pointee.yuvChromaSamplePosition.rawValue),
      expectedICC: iccProfile, expectedCLLI: contentLightLevels,
      expectedExif: exifPayload, expectedXMP: xmpPayload)

    let pixelFormatString =
      switch avifImage.pointee.yuvFormat {
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

  /// Byte-exact comparison of a decoded avifRWData metadata block against the
  /// expected payload.
  static func compareMetadata(_ decoded: avifRWData, _ expected: [UInt8]?, _ name: String) throws {
    if let expected, !expected.isEmpty {
      guard Int(decoded.size) == expected.count else {
        throw AVIFError.validationFailed("decoded \(name) size differs")
      }
      let matches = expected.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        return memcmp(decoded.data, base, expected.count) == 0
      }
      guard matches else {
        throw AVIFError.validationFailed("decoded \(name) differs")
      }
    } else if decoded.size != 0 {
      throw AVIFError.validationFailed("unexpected decoded \(name)")
    }
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
    alphaBytesPerRow: Int,
    expectedRange: Int? = nil,
    expectedPrimaries: Int? = nil,
    expectedTransfer: Int? = nil,
    expectedMatrix: Int? = nil,
    expectedChromaPosition: Int? = nil,
    expectedICC: [UInt8]? = nil,
    expectedCLLI: [UInt8]? = nil,
    expectedExif: [UInt8]? = nil,
    expectedXMP: [UInt8]? = nil
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
      return avifDecoderReadMemory(
        decoder, decoded, base.assumingMemoryBound(to: UInt8.self), rawBytes.count)
    }
    guard parseResult == AVIF_RESULT_OK else {
      throw AVIFError.validationFailed(
        "decode failed: \(String(cString: avifResultToString(parseResult)))")
    }
    if let expectedRange, Int(decoded.pointee.yuvRange.rawValue) != expectedRange {
      throw AVIFError.validationFailed("decoded range differs")
    }
    if let expectedPrimaries, Int(decoded.pointee.colorPrimaries) != expectedPrimaries {
      throw AVIFError.validationFailed("decoded primaries differ")
    }
    if let expectedTransfer, Int(decoded.pointee.transferCharacteristics) != expectedTransfer {
      throw AVIFError.validationFailed("decoded transfer differs")
    }
    if let expectedMatrix, Int(decoded.pointee.matrixCoefficients) != expectedMatrix {
      throw AVIFError.validationFailed("decoded matrix differs")
    }
    if let expectedChromaPosition,
      Int(decoded.pointee.yuvChromaSamplePosition.rawValue) != expectedChromaPosition
    {
      throw AVIFError.validationFailed("decoded chroma position differs")
    }
    let profile = decoded.pointee.icc
    if let expectedICC {
      guard Int(profile.size) == expectedICC.count else {
        throw AVIFError.validationFailed("decoded ICC size differs")
      }
      let matches = expectedICC.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return expectedICC.isEmpty }
        return memcmp(profile.data, base, expectedICC.count) == 0
      }
      guard matches else { throw AVIFError.validationFailed("decoded ICC differs") }
    } else if profile.size != 0 {
      throw AVIFError.validationFailed("unexpected decoded ICC")
    }
    if let expectedCLLI {
      guard expectedCLLI.count == 4,
        decoded.pointee.clli.maxCLL == UInt16(expectedCLLI[0]) << 8 | UInt16(expectedCLLI[1]),
        decoded.pointee.clli.maxPALL == UInt16(expectedCLLI[2]) << 8 | UInt16(expectedCLLI[3])
      else {
        throw AVIFError.validationFailed("decoded CLLI differs")
      }
    } else if decoded.pointee.clli.maxCLL != 0 || decoded.pointee.clli.maxPALL != 0 {
      throw AVIFError.validationFailed("unexpected decoded CLLI")
    }
    // Application metadata round-trips byte-exactly (Exif payload, XMP).
    try compareMetadata(decoded.pointee.exif, expectedExif, "Exif")
    try compareMetadata(decoded.pointee.xmp, expectedXMP, "XMP")

    guard Int(decoded.pointee.width) == width, Int(decoded.pointee.height) == height,
      Int(decoded.pointee.depth) == depth,
      Int(decoded.pointee.yuvFormat.rawValue)
        == (chromaWidth == width && chromaHeight == height
          ? AVIF_PIXEL_FORMAT_YUV444.rawValue
          : (chromaWidth == width / 2 && chromaHeight == height / 2
            ? AVIF_PIXEL_FORMAT_YUV420.rawValue : AVIF_PIXEL_FORMAT_YUV422.rawValue))
    else {
      throw AVIFError.validationFailed("decoded geometry, depth, or subsampling differs")
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
        let b = UnsafeRawPointer(decodedAlpha).advanced(
          by: row * Int(decoded.pointee.alphaRowBytes))
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
      return avifDecoderReadMemory(
        decoder, decoded, base.assumingMemoryBound(to: UInt8.self), encoded.count)
    }
    guard parseResult == AVIF_RESULT_OK else {
      throw AVIFError.validationFailed(
        "decode failed: \(String(cString: avifResultToString(parseResult)))")
    }
    let depth = Int(decoded.pointee.depth)
    let bytesPerSample = depth > 8 ? 2 : 1
    let w = Int(decoded.pointee.width)
    let h = Int(decoded.pointee.height)

    func extract(_ base: UnsafeMutablePointer<UInt8>?, _ bpr: UInt32, _ rows: Int, _ cols: Int)
      -> [UInt8]
    {
      guard let base else { return [] }
      var out = [UInt8]()
      out.reserveCapacity(rows * cols * bytesPerSample)
      for row in 0..<rows {
        let p = UnsafeRawPointer(base).advanced(by: row * Int(bpr))
        out.append(contentsOf: UnsafeRawBufferPointer(start: p, count: cols * bytesPerSample))
      }
      return out
    }

    func extract32(_ base: UnsafeMutablePointer<UInt8>?, _ bpr: UInt32, _ rows: Int, _ cols: Int)
      -> [UInt8]
    {
      extract(base, bpr, rows, cols)
    }

    var chromaW = w
    var chromaH = h
    switch decoded.pointee.yuvFormat {
    case AVIF_PIXEL_FORMAT_YUV444:
      chromaW = w
      chromaH = h
    case AVIF_PIXEL_FORMAT_YUV422:
      chromaW = w / 2
      chromaH = h
    case AVIF_PIXEL_FORMAT_YUV420:
      chromaW = w / 2
      chromaH = h / 2
    case AVIF_PIXEL_FORMAT_YUV400:
      chromaW = 0
      chromaH = 0
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
      colorPrimaries: Int(decoded.pointee.colorPrimaries),
      transferCharacteristics: Int(decoded.pointee.transferCharacteristics),
      chromaSamplePosition: Int(decoded.pointee.yuvChromaSamplePosition.rawValue),
      range: Int(decoded.pointee.yuvRange.rawValue),
      planes: planes)
  }

  public struct DecodedImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int
    public var yuvFormat: UInt32
    public var matrixCoefficients: Int
    public var colorPrimaries: Int
    public var transferCharacteristics: Int
    public var chromaSamplePosition: Int
    public var range: Int
    public var planes: [[UInt8]]
  }
}
