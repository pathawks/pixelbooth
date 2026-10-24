// CapturedCapture — an accepted photograph with all provenance needed for
// archival encoding. Immutable after acceptance; owns its payload snapshot
// (retained/copied at acceptance so later buffer reuse cannot mutate it).

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import PixelBoothAVIF
import PixelBoothAdapters
import PixelBoothCapture
import PixelBoothCore
import PixelBoothJPEG
import PixelBoothMetadata

public struct CapturedCapture: Sendable, Codable {
  public static let completeColorAttachmentSnapshotKey =
    "org.pixelbooth.colorAttachmentsComplete"

  public var uuid: UUID
  /// Source coding FourCC retained for provenance (e.g. `avc1` after decode).
  public var fourCC: UInt32
  /// Pixel layout whose native samples are stored in `payload`, when distinct
  /// from source coding (e.g. `420v` reconstructed from H.264).
  public var pixelFourCC: UInt32?
  public var dataSource: DataSource?
  public var width: Int
  public var height: Int
  public var timestampNanos: UInt64
  public var deviceUniqueID: String
  public var metadata: FrameMetadataSnapshot
  public var acceptedAtISO: String
  /// Delivered interpretation captured with the sample. Optional fields mean
  /// unknown; finalization refuses interpretations it cannot represent.
  public var color: ColorDescriptor?
  /// Negotiated versus delivered acquisition facts at the shutter. Optional
  /// only for legacy serialized captures that predate this evidence.
  public var acquisitionEvidence: AcquisitionEvidence?

  public struct ColorDescriptor: Sendable, Codable, Hashable {
    public var yuvRange: CaptureFormat.YUVRange?
    public var primaries: Int?
    public var transfer: Int?
    public var matrix: Int?
    public var chromaLocation: CaptureFormat.ChromaLocation?
    public var iccProfile: [UInt8]?
    public var contentLightLevels: [UInt8]?
    public init(
      yuvRange: CaptureFormat.YUVRange?, primaries: Int?, transfer: Int?,
      matrix: Int?, chromaLocation: CaptureFormat.ChromaLocation?, iccProfile: [UInt8]?,
      contentLightLevels: [UInt8]? = nil
    ) {
      self.yuvRange = yuvRange
      self.primaries = primaries
      self.transfer = transfer
      self.matrix = matrix
      self.chromaLocation = chromaLocation
      self.iccProfile = iccProfile
      self.contentLightLevels = contentLightLevels
    }
  }

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
    /// Meaningful channel precision. Nil is retained for older journal rows.
    public var bitsPerChannel: Int?
    public var chromaWidth: Int
    public var chromaHeight: Int
    /// Contiguous plane bytes only (padding excluded).
    public var contiguous: [[UInt8]]

    public func validate(width: Int, height: Int) throws {
      guard bytesPerSample == 1 || bytesPerSample == 2, width > 0, height > 0,
        contiguous.count == 3 || contiguous.count == 4, rows.count == contiguous.count,
        bytesPerRow.count == contiguous.count,
        bitsPerChannel.map({ $0 > 0 && $0 <= bytesPerSample * 8 }) ?? true
      else { throw SnapshotError.invalidLayout }
      guard rows[0] == height, rows[1] == chromaHeight, rows[2] == chromaHeight,
        contiguous.count == 3 || rows[3] == height
      else { throw SnapshotError.invalidLayout }
      guard
        (chromaWidth == width && chromaHeight == height)
          || (width % 2 == 0 && height % 2 == 0 && chromaWidth == width / 2
            && chromaHeight == height / 2)
          || (width % 2 == 0 && chromaWidth == width / 2 && chromaHeight == height)
      else { throw SnapshotError.invalidLayout }
      for i in contiguous.indices {
        let cols = i == 0 || i == 3 ? width : chromaWidth
        let (rowBytes, overflow) = cols.multipliedReportingOverflow(by: bytesPerSample)
        let (total, totalOverflow) = rowBytes.multipliedReportingOverflow(by: rows[i])
        guard !overflow, !totalOverflow, cols > 0, rows[i] > 0,
          bytesPerRow[i] == rowBytes, contiguous[i].count == total
        else {
          throw SnapshotError.invalidLayout
        }
      }
    }

    /// Resolve image geometry from the retained full-resolution plane. This
    /// remains authoritative if a legacy capture recorded stale dimensions.
    public func nativeDimensions() throws -> (width: Int, height: Int) {
      guard let rowBytes = bytesPerRow.first, let height = rows.first,
        bytesPerSample > 0, rowBytes % bytesPerSample == 0
      else { throw SnapshotError.invalidLayout }
      let width = rowBytes / bytesPerSample
      try validate(width: width, height: height)
      return (width, height)
    }

    public init(
      bytesPerRow: [Int], rows: [Int], bytesPerSample: Int,
      chromaWidth: Int, chromaHeight: Int, contiguous: [[UInt8]],
      bitsPerChannel: Int? = nil
    ) {
      self.bytesPerRow = bytesPerRow
      self.rows = rows
      self.bytesPerSample = bytesPerSample
      self.bitsPerChannel = bitsPerChannel
      self.chromaWidth = chromaWidth
      self.chromaHeight = chromaHeight
      self.contiguous = contiguous
    }

    /// Rebuild a PlanarImage referencing freshly copied plane buffers.
    public func asPlanarImage(
      width: Int, height: Int,
      planePointers: [UnsafeMutableRawPointer]
    ) throws -> PlanarImage {
      try validate(width: width, height: height)
      guard planePointers.count == contiguous.count else { throw SnapshotError.invalidLayout }
      return PlanarImage(
        width: width, height: height,
        bitsPerChannel: bitsPerChannel ?? bytesPerSample * 8,
        planes: planePointers.map { UnsafeRawPointer($0) },
        bytesPerRow: bytesPerRow, rowCount: rows,
        bytesPerSample: bytesPerSample,
        chromaWidth: chromaWidth, chromaHeight: chromaHeight,
        ownedStorage: [])
    }
  }

  public enum SnapshotError: Error, LocalizedError {
    case invalidLayout, unsupportedColorDescriptor, conflictingColorDescriptor

    public var errorDescription: String? {
      switch self {
      case .invalidLayout:
        return "The saved image planes do not match their recorded dimensions or layout."
      case .unsupportedColorDescriptor:
        return
          "There is not enough verified color metadata to encode this image as AVIF without guessing."
      case .conflictingColorDescriptor:
        return "The image contains conflicting color metadata."
      }
    }
  }

  public var payload: Payload

  /// Production AVIF path, also used by tests after JSON persistence. The
  /// encoder's verifier compares against the immutable compact snapshot.
  /// Exif and XMP payloads are embedded when provided (host-observed device
  /// identity and the versioned application XMP).
  public func encodeAVIF(exifPayload: [UInt8]? = nil, xmpPayload: [UInt8]? = nil)
    throws -> (data: [UInt8], settings: LosslessAVIF.AppliedSettings)
  {
    guard case .planes(let snapshot) = payload else { throw AdapterError.unsupportedFourCC(fourCC) }
    let color = try encodingColorDescriptor(for: snapshot)
    let isRGB = snapshot.contiguous.count == 4 || PixelFormatFourCC.isRGB(pixelFourCC ?? fourCC)
    if !isRGB && color.yuvRange == nil { throw SnapshotError.unsupportedColorDescriptor }
    if ![nil, .left, .topLeft].contains(color.chromaLocation) {
      throw SnapshotError.unsupportedColorDescriptor
    }
    let dimensions = try snapshot.nativeDimensions()
    let buffers = snapshot.contiguous.map { bytes -> UnsafeMutableRawPointer in
      let ptr = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 16)
      bytes.withUnsafeBytes { raw in ptr.copyMemory(from: raw.baseAddress!, byteCount: bytes.count)
      }
      return ptr
    }
    defer { for buffer in buffers { buffer.deallocate() } }
    return try LosslessAVIF.encodeLossless(
      try snapshot.asPlanarImage(
        width: dimensions.width, height: dimensions.height, planePointers: buffers),
      isRGBIdentity: isRGB, yuvRange: color.yuvRange, chromaLocation: color.chromaLocation,
      colorPrimaries: color.primaries, transferCharacteristics: color.transfer,
      matrixCoefficients: color.matrix, iccProfile: color.iccProfile,
      contentLightLevels: color.contentLightLevels,
      exifPayload: exifPayload, xmpPayload: xmpPayload)
  }

  private func encodingColorDescriptor(for snapshot: PlaneSnapshot) throws -> ColorDescriptor {
    guard metadata.colorEncodingFailure == nil else {
      throw SnapshotError.unsupportedColorDescriptor
    }
    if let color { return color }

    // Legacy snapshots predate the serialized ColorDescriptor. Reconstruct only
    // from the shutter-time delivered-format evidence and verbatim CoreVideo
    // attachments retained in FrameMetadataSnapshot; never choose defaults for
    // values that affect sample interpretation.
    let attachments = metadata.pixelBufferAttachments
    guard attachments[Self.completeColorAttachmentSnapshotKey] == "true" else {
      throw SnapshotError.unsupportedColorDescriptor
    }
    let isRGBIdentity =
      snapshot.contiguous.count == 4 || PixelFormatFourCC.isRGB(pixelFourCC ?? fourCC)
    let dimensions = try snapshot.nativeDimensions()
    let range: CaptureFormat.YUVRange?
    if isRGBIdentity {
      range = nil
    } else {
      guard let evidence = acquisitionEvidence,
        evidence.deviceUniqueID == deviceUniqueID,
        evidence.generation == metadata.generation,
        evidence.deliveredFormat.width == dimensions.width,
        evidence.deliveredFormat.height == dimensions.height,
        CaptureFormatFacts.isConsistent(evidence.deliveredFormat)
      else { throw SnapshotError.unsupportedColorDescriptor }
      range = CaptureFormatFacts.applying(to: evidence.deliveredFormat).yuvRange
      guard range != nil else { throw SnapshotError.unsupportedColorDescriptor }
    }

    for key in [
      kCVImageBufferICCProfileKey, kCVImageBufferCGColorSpaceKey,
      kCVImageBufferContentLightLevelInfoKey, kCVImageBufferMasteringDisplayColorVolumeKey,
      kCVImageBufferLogTransferFunctionKey, kCVImageBufferGammaLevelKey,
      kCVImageBufferAmbientViewingEnvironmentKey,
    ] {
      guard attachments[key as String] == nil else {
        throw SnapshotError.unsupportedColorDescriptor
      }
    }

    let topKey = kCVImageBufferChromaLocationTopFieldKey as String
    let bottomKey = kCVImageBufferChromaLocationBottomFieldKey as String
    let top = attachments[topKey]
    let bottom = attachments[bottomKey]
    guard top == nil || bottom == nil || top == bottom else {
      throw SnapshotError.conflictingColorDescriptor
    }
    let chromaLocation: CaptureFormat.ChromaLocation?
    if let raw = top ?? bottom {
      let locations: [(String, CaptureFormat.ChromaLocation)] = [
        (kCVImageBufferChromaLocation_Left as String, .left),
        (kCVImageBufferChromaLocation_Center as String, .center),
        (kCVImageBufferChromaLocation_TopLeft as String, .topLeft),
        (kCVImageBufferChromaLocation_Top as String, .top),
        (kCVImageBufferChromaLocation_BottomLeft as String, .bottomLeft),
        (kCVImageBufferChromaLocation_Bottom as String, .bottom),
      ]
      guard let value = locations.first(where: { $0.0 == raw })?.1 else {
        throw SnapshotError.unsupportedColorDescriptor
      }
      chromaLocation = value
    } else {
      chromaLocation = nil
    }

    return ColorDescriptor(
      yuvRange: range,
      primaries: try Self.recoveredColorCodePoint(
        kCVImageBufferColorPrimariesKey, from: attachments,
        convert: CVColorPrimariesGetIntegerCodePointForString,
        reverse: { CVColorPrimariesGetStringForIntegerCodePoint($0)?.takeUnretainedValue() }),
      transfer: try Self.recoveredColorCodePoint(
        kCVImageBufferTransferFunctionKey, from: attachments,
        convert: CVTransferFunctionGetIntegerCodePointForString,
        reverse: { CVTransferFunctionGetStringForIntegerCodePoint($0)?.takeUnretainedValue() },
        allows2020Alias: true),
      matrix: try Self.recoveredColorCodePoint(
        kCVImageBufferYCbCrMatrixKey, from: attachments,
        convert: CVYCbCrMatrixGetIntegerCodePointForString,
        reverse: { CVYCbCrMatrixGetStringForIntegerCodePoint($0)?.takeUnretainedValue() }),
      chromaLocation: chromaLocation, iccProfile: nil, contentLightLevels: nil)
  }

  private static func recoveredColorCodePoint(
    _ key: CFString,
    from attachments: [String: String],
    convert: (CFString?) -> Int32,
    reverse: (Int32) -> CFString?,
    allows2020Alias: Bool = false
  ) throws -> Int? {
    guard let raw = attachments[key as String] else { return nil }
    let value = raw as CFString
    let code = convert(value)
    let alias =
      allows2020Alias
      && CFEqual(value, kCVImageBufferTransferFunction_ITU_R_2020) && code == 1
    guard code >= 0, alias || (reverse(code).map { CFEqual(value, $0) } ?? false) else {
      throw SnapshotError.unsupportedColorDescriptor
    }
    return Int(code)
  }

  public init(
    from frame: DeliveredFrame, metadata: FrameMetadataSnapshot,
    acquisitionEvidence: AcquisitionEvidence? = nil
  ) throws {
    let sourceSampleBuffer = frame.sourceSampleBuffer ?? frame.sampleBuffer
    try FrameExtraction.validateProgressiveFrame(
      sampleBuffer: frame.sampleBuffer, sourceSampleBuffer: frame.sourceSampleBuffer)
    let pixelBuffer = frame.sampleBuffer.imageBuffer
    let dimensions: (width: Int, height: Int)
    if !PixelFormatFourCC.isJPEG(frame.fourCC), let pixelBuffer {
      dimensions = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
    } else {
      dimensions = (frame.width, frame.height)
    }
    self.uuid = UUID()
    self.fourCC = frame.sourceFourCC
    self.pixelFourCC = frame.fourCC
    self.dataSource =
      PixelFormatFourCC.isJPEG(frame.sourceFourCC)
      ? .cameraNative
      : (frame.sourceFourCC == PixelFormatFourCC.avc1 ? .macDecoded : .macDelivered)
    self.width = dimensions.width
    self.height = dimensions.height
    self.timestampNanos = frame.timestampNanos
    self.deviceUniqueID = frame.deviceUniqueID
    self.metadata = metadata
    if let observations = frame.streamColorObservations {
      self.metadata.streamColorObservations = observations
    }
    self.metadata.attachmentArchive = CaptureMetadataArchiver.snapshot(frame)
    self.acceptedAtISO = frame.hostWallClockISO
    do {
      self.color = try Self.colorDescriptor(
        pixelBuffer, formatDescription: CMSampleBufferGetFormatDescription(sourceSampleBuffer))
    } catch {
      self.color = nil
      self.metadata.colorEncodingFailure = error.localizedDescription
    }
    self.acquisitionEvidence = acquisitionEvidence
    // Snapshot the immutable payload at acceptance.
    if PixelFormatFourCC.isJPEG(frame.sourceFourCC) {
      // MJPEG: complete JPEG passthrough, byte-exact.
      self.payload = .jpegBytes(
        try FrameExtraction.extractJPEG(from: sourceSampleBuffer))
      if case .jpegBytes(let bytes) = self.payload {
        let structure = try JPEGParser.parse(bytes)
        for segment in structure.segments
        where (0xE0...0xEF).contains(segment.marker) || segment.marker == 0xFE {
          self.metadata.attachmentArchive?.entries.append(
            .init(
              scope: "source.jpeg",
              key: String(format: "segment-%02X-at-%d", segment.marker, segment.offset),
              encoding: "jpeg-segment-payload", payload: Data(segment.payload)))
        }
      }
    } else if let pb = pixelBuffer {
      // Uncompressed: adapt and snapshot contiguous planes (padding excluded).
      self.payload = .planes(
        try FrameExtraction.snapshot(
          pb, fourCC: frame.fourCC,
          formatDescriptions: [
            CMSampleBufferGetFormatDescription(frame.sampleBuffer),
            CMSampleBufferGetFormatDescription(sourceSampleBuffer),
          ]))
    } else {
      throw AdapterError.unsupportedFourCC(frame.fourCC)
    }
    if case .planes(let snapshot) = payload, let color,
      snapshot.contiguous.count != 4, !PixelFormatFourCC.isRGB(frame.fourCC),
      color.matrix == nil || color.matrix == 2
    {
      self.metadata.attachmentArchive?.issues.append(
        "delivered.YCbCrMatrix: YUV-to-RGB matrix is unavailable; native samples are retained with unspecified matrix coefficients"
      )
    }
  }

  /// Snapshot contiguous plane bytes from an adapted PlanarImage.
  public static func snapshotPlanes(from planar: PlanarImage) throws -> PlaneSnapshot {
    guard planar.planes.count >= 3, planar.planes.count == planar.bytesPerRow.count,
      planar.planes.count == planar.rowCount.count, planar.width > 0,
      planar.height > 0, planar.bytesPerSample > 0
    else { throw SnapshotError.invalidLayout }
    var contiguous: [[UInt8]] = []
    var compactRows: [Int] = []
    for (i, plane) in planar.planes.enumerated() {
      let rowCount = planar.rowCount[i]
      let cols = i == 0 || i == 3 ? planar.width : planar.chromaWidth
      let (rowBytes, overflow) = cols.multipliedReportingOverflow(by: planar.bytesPerSample)
      guard !overflow, rowBytes > 0, planar.bytesPerRow[i] >= rowBytes,
        rowCount > 0
      else { throw SnapshotError.invalidLayout }
      var bytes: [UInt8] = []
      let (total, totalOverflow) = rowCount.multipliedReportingOverflow(by: rowBytes)
      guard !totalOverflow else { throw SnapshotError.invalidLayout }
      bytes.reserveCapacity(total)
      for row in 0..<rowCount {
        let (offset, offsetOverflow) = row.multipliedReportingOverflow(by: planar.bytesPerRow[i])
        guard !offsetOverflow else { throw SnapshotError.invalidLayout }
        let p = plane.advanced(by: offset)
        bytes.append(
          contentsOf: UnsafeRawBufferPointer(
            start: p, count: rowBytes))
      }
      contiguous.append(bytes)
      compactRows.append(rowBytes)
    }
    return PlaneSnapshot(
      bytesPerRow: compactRows, rows: planar.rowCount,
      bytesPerSample: planar.bytesPerSample,
      chromaWidth: planar.chromaWidth, chromaHeight: planar.chromaHeight,
      contiguous: contiguous, bitsPerChannel: planar.bitsPerChannel)
  }

  private static func colorDescriptor(_ pb: CVPixelBuffer?, formatDescription: CMFormatDescription?)
    throws -> ColorDescriptor?
  {
    guard let pb else { return nil }
    let extensions =
      formatDescription.flatMap { CMFormatDescriptionGetExtensions($0) } as? [CFString: Any] ?? [:]
    func attachment(_ key: CFString) throws -> CFTypeRef? {
      let pixel = CVBufferCopyAttachment(pb, key, nil)
      let format = extensions[key] as CFTypeRef?
      if let pixel, let format, !CFEqual(pixel, format) {
        throw SnapshotError.conflictingColorDescriptor
      }
      return pixel ?? format
    }
    func raw(
      _ key: CFString, _ convert: (CFString?) -> Int32,
      _ reverse: (Int32) -> CFString?
    ) throws -> Int? {
      guard let value = try attachment(key) else { return nil }
      guard CFGetTypeID(value) == CFStringGetTypeID() else {
        throw SnapshotError.unsupportedColorDescriptor
      }
      let string = unsafeDowncast(value, to: CFString.self)
      let code = convert(string)
      let transfer2020Alias =
        key == kCVImageBufferTransferFunctionKey
        && CFEqual(string, kCVImageBufferTransferFunction_ITU_R_2020) && code == 1
      guard code >= 0, transfer2020Alias || (reverse(code).map { CFEqual(string, $0) } ?? false)
      else {
        throw SnapshotError.unsupportedColorDescriptor
      }
      return Int(code)
    }
    let format = CVPixelBufferGetPixelFormatType(pb)
    let range = CaptureFormatFacts.applying(
      to: CaptureFormat(
        width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), fourCC: format)
    ).yuvRange
    let topChromaValue = try attachment(kCVImageBufferChromaLocationTopFieldKey)
    let bottomChromaValue = try attachment(kCVImageBufferChromaLocationBottomFieldKey)
    if let topChromaValue, let bottomChromaValue, !CFEqual(topChromaValue, bottomChromaValue) {
      throw SnapshotError.unsupportedColorDescriptor
    }
    let chromaValue = topChromaValue ?? bottomChromaValue
    let chromaMap: [(CFString, CaptureFormat.ChromaLocation)] = [
      (kCVImageBufferChromaLocation_Left, .left), (kCVImageBufferChromaLocation_Center, .center),
      (kCVImageBufferChromaLocation_TopLeft, .topLeft), (kCVImageBufferChromaLocation_Top, .top),
      (kCVImageBufferChromaLocation_BottomLeft, .bottomLeft),
      (kCVImageBufferChromaLocation_Bottom, .bottom),
    ]
    let chroma = try chromaValue.map { value -> CaptureFormat.ChromaLocation in
      guard let known = chromaMap.first(where: { CFEqual(value, $0.0) })?.1 else {
        throw SnapshotError.unsupportedColorDescriptor
      }
      return known
    }
    let iccValue = try attachment(kCVImageBufferICCProfileKey)
    guard iccValue == nil || CFGetTypeID(iccValue!) == CFDataGetTypeID() else {
      throw SnapshotError.unsupportedColorDescriptor
    }
    var icc = iccValue as? Data
    if let colorSpaceValue = try attachment(kCVImageBufferCGColorSpaceKey) {
      guard CFGetTypeID(colorSpaceValue) == CGColorSpace.typeID else {
        throw SnapshotError.unsupportedColorDescriptor
      }
      let colorSpace = unsafeDowncast(colorSpaceValue, to: CGColorSpace.self)
      guard let iccData = colorSpace.copyICCData() as Data?, !iccData.isEmpty else {
        throw SnapshotError.unsupportedColorDescriptor
      }
      if let icc, icc != iccData { throw SnapshotError.conflictingColorDescriptor }
      icc = iccData
    }
    if iccValue != nil && (icc == nil || icc!.isEmpty) {
      throw SnapshotError.unsupportedColorDescriptor
    }
    let logTransfer = try attachment(kCVImageBufferLogTransferFunctionKey)
    guard logTransfer == nil else { throw SnapshotError.unsupportedColorDescriptor }
    let gamma = try attachment(kCVImageBufferGammaLevelKey)
    guard gamma == nil || icc != nil else { throw SnapshotError.unsupportedColorDescriptor }
    let clliValue = try attachment(kCVImageBufferContentLightLevelInfoKey)
    guard
      clliValue == nil
        || (CFGetTypeID(clliValue!) == CFDataGetTypeID() && (clliValue as! Data).count == 4)
    else {
      throw SnapshotError.unsupportedColorDescriptor
    }
    return ColorDescriptor(
      yuvRange: range,
      primaries: try raw(
        kCVImageBufferColorPrimariesKey, CVColorPrimariesGetIntegerCodePointForString,
        { CVColorPrimariesGetStringForIntegerCodePoint($0)?.takeUnretainedValue() }),
      transfer: try raw(
        kCVImageBufferTransferFunctionKey, CVTransferFunctionGetIntegerCodePointForString,
        { CVTransferFunctionGetStringForIntegerCodePoint($0)?.takeUnretainedValue() }),
      matrix: try raw(
        kCVImageBufferYCbCrMatrixKey, CVYCbCrMatrixGetIntegerCodePointForString,
        { CVYCbCrMatrixGetStringForIntegerCodePoint($0)?.takeUnretainedValue() }),
      chromaLocation: chroma, iccProfile: icc.map(Array.init),
      contentLightLevels: (clliValue as? Data).map(Array.init))
  }

  /// Test/development fixture constructor (never default app behavior).
  public init(
    fourCC: UInt32, width: Int, height: Int,
    payload: Payload, deviceUniqueID: String = "synthetic"
  ) {
    self.uuid = UUID()
    self.fourCC = fourCC
    self.width = width
    self.height = height
    self.timestampNanos = 0
    self.deviceUniqueID = deviceUniqueID
    self.metadata = FrameMetadataSnapshot(
      sampleBufferAttachments: [:], pixelBufferAttachments: [:],
      formatDescriptionData: [:], embeddedSourceExif: nil,
      embeddedSourceXMP: nil, embeddedSourceICC: nil, unknownSegments: [],
      hostObservations: [], hostLocation: nil,
      mediaTimeNanos: 0, wallClockAnchorISO: "2026-09-21T12:00:00.000Z",
      generation: 0)
    self.acceptedAtISO = "2026-09-21T12:00:00.000Z"
    self.acquisitionEvidence = nil
    self.payload = payload
  }

  /// Convenience for tests: build with an explicit payload.
  public static func makeTestCapture(
    fourCC: UInt32, width: Int, height: Int,
    payload: Payload
  ) -> CapturedCapture {
    CapturedCapture(fourCC: fourCC, width: width, height: height, payload: payload)
  }
}
