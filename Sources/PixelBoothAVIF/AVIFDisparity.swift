import Foundation
import PixelBoothCAvifShim
import PixelBoothMetadata

/// Adds an estimated relative disparity auxiliary without re-encoding the photograph.
/// `fdis` identifies the floating-point source representation. AV1 stores a separately
/// documented, quantized L008 map; it cannot store arbitrary IEEE Float32 samples.
public enum AVIFDisparity {
  public static let auxiliaryType = "urn:mpeg:mpegB:cicp:systems:auxiliary:depth"

  /// Application-selected disparity units for an external renderer. This range
  /// controls blur strength; it does not establish physical distance or optics.
  public enum RenderingScale: String, Codable, Sendable {
    case portraitRelativeV1 = "portrait-relative-v1"

    public var minimum: Float { 1.777344 }
    public var maximum: Float { 6.09375 }
  }

  public enum DisparityError: Error, LocalizedError, Equatable, Sendable {
    case invalidMap(String)
    case invalidContainer(String)
    case verificationFailed(String)

    public var errorDescription: String? {
      switch self {
      case .invalidMap(let reason): "Estimated disparity map is invalid: \(reason)."
      case .invalidContainer(let reason): "AVIF disparity attachment is unsupported: \(reason)."
      case .verificationFailed(let reason): "AVIF disparity verification failed: \(reason)."
      }
    }
  }

  public struct Descriptor: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let nativeFormat: String
    public let storedFormat: String
    public let minimumRelativeDisparity: Float
    public let maximumRelativeDisparity: Float
    public let modelIdentifier: String
    public let preprocessingDescription: String?
    public let outputDescription: String?
    public let portraitRenderIntent: PortraitRenderIntent?
    /// Absent in older journal descriptors and when no Portrait intent is requested.
    public let renderingScale: RenderingScale?
    public let losslessStorageVerified: Bool

    /// Reconstruction endpoint for stored integer zero, not an observed map minimum.
    public var nativeMinimumDisparity: Float {
      renderingScale?.minimum ?? minimumRelativeDisparity
    }

    /// Reconstruction endpoint for stored integer 255, not an observed map maximum.
    public var nativeMaximumDisparity: Float {
      renderingScale?.maximum ?? maximumRelativeDisparity
    }
  }

  public struct StoredMap: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let samples: [UInt8]
    public let xmp: String
  }

  /// Quantizes finite, nonnegative model values to 8-bit samples and losslessly
  /// encodes those samples. Larger values indicate nearer objects. Source min/max
  /// retain the model's arbitrary scale. With a Portrait intent, native readback
  /// uses fixed virtual rendering units so raw model scale cannot magnify blur.
  /// Constant maps remain uniform at the native minimum. No calibration is claimed.
  public static func attach(
    to primaryAVIF: [UInt8], width: Int, height: Int,
    relativeDisparity: [Float], modelIdentifier: String,
    preprocessingDescription: String? = nil, outputDescription: String? = nil,
    portraitRenderIntent: PortraitRenderIntent? = nil
  ) throws -> (data: [UInt8], descriptor: Descriptor) {
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow, width > 0, height > 0, width <= 65_536, height <= 65_536,
      count <= 67_108_864, relativeDisparity.count == count,
      relativeDisparity.allSatisfy({ $0.isFinite && $0 >= 0 }),
      !modelIdentifier.isEmpty, modelIdentifier.utf8.count <= 4_096,
      [modelIdentifier, preprocessingDescription, outputDescription].compactMap({ $0 }).allSatisfy({
        $0.utf8.count <= 4_096 && $0.unicodeScalars.allSatisfy({ $0.value >= 0x20 })
      })
    else { throw DisparityError.invalidMap("invalid geometry, samples, or provenance") }

    var original = try AVIFItemContainer(primaryAVIF)
    guard !original.hasDepthAuxiliary else {
      throw DisparityError.invalidContainer("a depth auxiliary already exists")
    }
    let primaryImage = try LosslessAVIF.decode(encoded: primaryAVIF)
    if let intent = portraitRenderIntent {
      guard intent.primaryWidth == primaryImage.width,
        intent.primaryHeight == primaryImage.height
      else { throw DisparityError.invalidMap("render intent does not match the primary image") }
    }

    let minimum = relativeDisparity.min()!
    let maximum = relativeDisparity.max()!
    let span = Double(maximum) - Double(minimum)
    let samples = relativeDisparity.map { value -> UInt8 in
      if span == 0 { return 0 }
      return UInt8(((Double(value) - Double(minimum)) / span * 255).rounded())
    }
    let descriptor = Descriptor(
      width: width, height: height, nativeFormat: "fdis", storedFormat: "L008",
      minimumRelativeDisparity: minimum, maximumRelativeDisparity: maximum,
      modelIdentifier: modelIdentifier, preprocessingDescription: preprocessingDescription,
      outputDescription: outputDescription, portraitRenderIntent: portraitRenderIntent,
      renderingScale: portraitRenderIntent == nil ? nil : .portraitRelativeV1,
      losslessStorageVerified: true)
    let xmp = Array(metadata(descriptor).utf8)
    let auxiliary = try encodeMonochrome(samples, width: width, height: height)
    let source = try AVIFItemContainer(auxiliary)
    try original.addDisparity(source, xmp: xmp)
    let result = try original.serialize()

    // Reparse the final file and decode the actual attached auxiliary payload.
    let finalContainer = try AVIFItemContainer(result)
    let map = try extract(from: result)
    guard map.width == width, map.height == height, map.samples == samples,
      map.xmp == String(bytes: xmp, encoding: .utf8),
      try primaryImage == LosslessAVIF.decode(encoded: result)
    else { throw DisparityError.verificationFailed("final native samples or metadata differ") }
    let originalContainer = try AVIFItemContainer(primaryAVIF)
    for item in originalContainer.items {
      guard let finalItem = finalContainer.items.first(where: { $0.id == item.id }),
        finalItem.payload == item.payload, finalItem.info.bytes == item.info.bytes,
        finalContainer.properties(for: item.id).map(\.bytes)
          == originalContainer.properties(for: item.id).map(\.bytes),
        finalContainer.associations[item.id] == originalContainer.associations[item.id]
      else {
        throw DisparityError.verificationFailed("original item coding or metadata bytes differ")
      }
    }
    guard
      Array(finalContainer.references.prefix(originalContainer.references.count))
        == originalContainer.references
    else { throw DisparityError.verificationFailed("original item relationships differ") }
    return (result, descriptor)
  }

  /// Extracts the stored AV1 auxiliary using its property and reference relationships.
  /// This checks native stored samples, independently of ImageIO/Photos support.
  public static func extract(from encoded: [UInt8]) throws -> StoredMap {
    let container = try AVIFItemContainer(encoded)
    let candidates = container.items.filter { item in
      (container.associations[item.id] ?? []).contains { association in
        let property = container.propertyBoxes[(association & 0x7FFF) - 1]
        return association & 0x8000 != 0 && property.type == "auxC"
          && property.payload == [0, 0, 0, 0] + Array(auxiliaryType.utf8) + [0]
      }
        && item.info.payload[3] & 1 != 0
        && container.references.contains {
          $0.type == "auxl" && $0.from == item.id && $0.to == [container.primaryID]
        }
    }
    guard candidates.count == 1, let item = candidates.first else {
      throw DisparityError.invalidContainer("expected one attached depth auxiliary")
    }
    let metadataItems = container.items.filter { candidate in
      candidate.type == "mime"
        && container.references.contains {
          $0.type == "cdsc" && $0.from == candidate.id && $0.to == [item.id]
        }
    }
    guard metadataItems.count == 1,
      let xmp = String(bytes: metadataItems[0].payload, encoding: .utf8)
    else { throw DisparityError.invalidContainer("missing or ambiguous depth XMP") }
    let standalone = try container.standalone(itemID: item.id)
    let decoded = try LosslessAVIF.decode(encoded: standalone)
    guard decoded.depth == 8, decoded.yuvFormat == AVIF_PIXEL_FORMAT_YUV400.rawValue,
      decoded.range == Int(AVIF_RANGE_FULL.rawValue), decoded.planes.count == 3,
      decoded.planes[1].isEmpty, decoded.planes[2].isEmpty,
      decoded.planes[0].count == decoded.width * decoded.height
    else { throw DisparityError.verificationFailed("depth is not full-range monochrome8") }
    return StoredMap(
      width: decoded.width, height: decoded.height, samples: decoded.planes[0], xmp: xmp)
  }

  private static func metadata(_ descriptor: Descriptor) -> String {
    func escaped(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
    }
    let model = escaped(descriptor.modelIdentifier)
    let preprocessing =
      descriptor.preprocessingDescription.map {
        " pbdepth:Preprocessing=\"\(escaped($0))\""
      } ?? ""
    let output =
      descriptor.outputDescription.map {
        " pbdepth:ModelOutput=\"\(escaped($0))\""
      } ?? ""
    let rendering =
      descriptor.portraitRenderIntent.map { intent in
        " xmlns:depthBlurEffect=\"http://ns.apple.com/depthBlurEffect/1.0/\""
          + " depthBlurEffect:SimulatedAperture=\"\(intent.simulatedAperture)\""
          + " pbdepth:PortraitRenderIntentSchemaVersion=\"1\""
          + " pbdepth:PortraitRenderIntentOrigin=\"\(intent.origin.rawValue)\""
      } ?? ""
    let scale =
      descriptor.renderingScale.map { scale in
        " pbdepth:RenderScale=\"\(scale.rawValue)\""
          + " pbdepth:RenderScaleUnits=\"virtual-relative-disparity\""
          + " pbdepth:RenderMinimum=\"\(scale.minimum)\""
          + " pbdepth:RenderMaximum=\"\(scale.maximum)\""
          + " pbdepth:RenderReconstruction=\"renderMinimum+sample*(renderMaximum-renderMinimum)/255\""
          + " pbdepth:SourceRangeRole=\"model-output-before-render-normalization\""
      } ?? ""
    let schemaVersion = descriptor.renderingScale == nil ? 1 : 2
    return """
      <x:xmpmeta xmlns:x="adobe:ns:meta/">
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:apdi="http://ns.apple.com/pixeldatainfo/1.0/" xmlns:depthData="http://ns.apple.com/depthData/1.0/" xmlns:pbdepth="https://pixelbooth.app/ns/estimated-disparity/1.0/" apdi:AuxiliaryImageType="disparity" apdi:NativeFormat="1717856627" apdi:StoredFormat="1278226488" apdi:FloatMinValue="\(descriptor.nativeMinimumDisparity)" apdi:FloatMaxValue="\(descriptor.nativeMaximumDisparity)" apdi:IntMinValue="0" apdi:IntMaxValue="255" depthData:Accuracy="relative" pbdepth:SchemaVersion="\(schemaVersion)" pbdepth:NativeFormatName="fdis" pbdepth:StoredFormatName="L008" pbdepth:Source="monocular-model-estimate" pbdepth:ApplicationGenerated="true" pbdepth:LargerIsNearer="true" pbdepth:Model="\(model)" pbdepth:Units="arbitrary-relative-disparity" pbdepth:Minimum="\(descriptor.minimumRelativeDisparity)" pbdepth:Maximum="\(descriptor.maximumRelativeDisparity)" pbdepth:Quantization="round-nearest((value-minimum)/(maximum-minimum)*255); constant-map=0" pbdepth:Reconstruction="minimum+sample*(maximum-minimum)/255" pbdepth:StorageLosslessVerified="true"\(preprocessing)\(output)\(rendering)\(scale)/>
      </rdf:RDF>
      </x:xmpmeta>
      """
  }

  private static func encodeMonochrome(_ samples: [UInt8], width: Int, height: Int) throws
    -> [UInt8]
  {
    guard let image = avifImageCreate(UInt32(width), UInt32(height), 8, AVIF_PIXEL_FORMAT_YUV400)
    else { throw DisparityError.verificationFailed("auxiliary image allocation failed") }
    defer { avifImageDestroy(image) }
    image.pointee.yuvRange = AVIF_RANGE_FULL
    image.pointee.colorPrimaries = 2
    image.pointee.transferCharacteristics = 2
    image.pointee.matrixCoefficients = 2
    guard
      avifImageAllocatePlanes(image, avifPlanesFlags(AVIF_PLANES_YUV.rawValue)) == AVIF_RESULT_OK,
      let plane = image.pointee.yuvPlanes.0, Int(image.pointee.yuvRowBytes.0) >= width
    else { throw DisparityError.verificationFailed("auxiliary plane allocation failed") }
    samples.withUnsafeBytes { bytes in
      for row in 0..<height {
        memcpy(
          plane.advanced(by: row * Int(image.pointee.yuvRowBytes.0)),
          bytes.baseAddress!.advanced(by: row * width), width)
      }
    }
    guard let encoder = avifEncoderCreate() else {
      throw DisparityError.verificationFailed("auxiliary encoder allocation failed")
    }
    defer { avifEncoderDestroy(encoder) }
    encoder.pointee.codecChoice = AVIF_CODEC_CHOICE_AOM
    encoder.pointee.quality = AVIF_QUALITY_LOSSLESS
    encoder.pointee.qualityAlpha = AVIF_QUALITY_LOSSLESS
    encoder.pointee.speed = AVIF_SPEED_SLOWEST
    encoder.pointee.maxThreads = 2
    var output = avifRWData()
    defer { avifRWDataFree(&output) }
    let status = avifEncoderWrite(encoder, image, &output)
    guard status == AVIF_RESULT_OK, PixelBoothLibAvif.encoderUsesAOM(encoder) else {
      throw DisparityError.verificationFailed(
        "auxiliary AOM encode failed: \(String(cString: avifResultToString(status)))")
    }
    let encoded = Array(UnsafeBufferPointer(start: output.data, count: Int(output.size)))
    let decoded = try LosslessAVIF.decode(encoded: encoded)
    guard decoded.planes[0] == samples, decoded.depth == 8,
      decoded.yuvFormat == AVIF_PIXEL_FORMAT_YUV400.rawValue
    else { throw DisparityError.verificationFailed("auxiliary native samples differ") }
    return encoded
  }
}

/// Deliberately bounded still-image item-container support for pinned libavif output.
/// Unsupported construction methods, external data references, sequences, and
/// unknown structural boxes are refused rather than relocated speculatively.
private struct AVIFItemContainer {
  struct Box {
    var type: String
    var payload: [UInt8]
    var start: Int = 0
    var headerSize: Int = 8

    var bytes: [UInt8] { AVIFBytes.u32(payload.count + 8) + Array(type.utf8) + payload }
  }

  struct Item {
    var id: Int
    var type: String
    var info: Box
    var payload: [UInt8]
  }

  struct Reference: Equatable {
    var type: String
    var from: Int
    var to: [Int]
  }

  var fileType = Box(type: "ftyp", payload: [])
  var metaChildren: [Box] = []
  var primaryID = 0
  var items: [Item] = []
  var propertyBoxes: [Box] = []
  var associations: [Int: [Int]] = [:]
  var references: [Reference] = []

  var hasDepthAuxiliary: Bool {
    items.contains { item in
      properties(for: item.id).contains {
        $0.type == "auxC"
          && $0.payload == [0, 0, 0, 0] + Array(AVIFDisparity.auxiliaryType.utf8) + [0]
      }
    }
  }

  init(_ bytes: [UInt8]) throws {
    guard bytes.count <= Int(UInt32.max) else { throw invalid("file exceeds 32-bit bound") }
    let top = try Self.boxes(bytes)
    guard top.allSatisfy({ ["ftyp", "meta", "mdat", "free", "skip"].contains($0.type) }),
      top.filter({ $0.type == "ftyp" }).count == 1,
      top.filter({ $0.type == "meta" }).count == 1,
      let fileType = top.first(where: { $0.type == "ftyp" }),
      fileType.payload.count >= 8, fileType.payload.count % 4 == 0,
      stride(from: 0, to: fileType.payload.count, by: 4).contains(where: {
        Array(fileType.payload[$0..<($0 + 4)]) == Array("avif".utf8)
      }), let meta = top.first(where: { $0.type == "meta" }),
      meta.payload.starts(with: [0, 0, 0, 0])
    else { throw invalid("requires an AVIF still-image container") }
    self.fileType = fileType
    metaChildren = try Self.boxes(Array(meta.payload.dropFirst(4)))
    let allowed = ["hdlr", "pitm", "iloc", "iinf", "iref", "iprp"]
    guard metaChildren.allSatisfy({ allowed.contains($0.type) }),
      Set(metaChildren.map(\.type)).count == metaChildren.count
    else { throw invalid("unsupported or duplicate structural metadata box") }
    func required(_ type: String) throws -> Box {
      guard let box = metaChildren.first(where: { $0.type == type }) else {
        throw invalid("missing \(type)")
      }
      return box
    }
    var primary = AVIFBytes(try required("pitm").payload)
    guard try primary.read(4) == 0 else { throw invalid("unsupported pitm version") }
    primaryID = try primary.read(2)
    try primary.finish()

    var info = AVIFBytes(try required("iinf").payload)
    guard try info.read(4) == 0 else { throw invalid("unsupported iinf version") }
    let itemCount = try info.read(2)
    let infoBoxes = try Self.boxes(try info.remaining())
    guard infoBoxes.count == itemCount, itemCount > 0, itemCount <= 65_533 else {
      throw invalid("invalid item count")
    }
    items = try infoBoxes.map { box in
      var reader = AVIFBytes(box.payload)
      let versionFlags = try reader.read(4)
      guard box.type == "infe", versionFlags >> 24 == 2,
        versionFlags & 0x00FF_FFFE == 0
      else { throw invalid("unsupported item information") }
      let id = try reader.read(2)
      guard id > 0, try reader.read(2) == 0 else { throw invalid("protected or invalid item") }
      let type = String(bytes: try reader.readBytes(4), encoding: .ascii) ?? ""
      guard ["av01", "Exif", "mime"].contains(type) else {
        throw invalid("unsupported item type \(type)")
      }
      return Item(id: id, type: type, info: box, payload: [])
    }
    guard Set(items.map(\.id)).count == items.count,
      items.contains(where: { $0.id == primaryID && $0.type == "av01" })
    else { throw invalid("duplicate item IDs or invalid primary") }

    var location = AVIFBytes(try required("iloc").payload)
    guard try location.read(4) == 0 else { throw invalid("unsupported iloc version") }
    let sizes = try location.read(2)
    let offsetSize = sizes >> 12
    let lengthSize = (sizes >> 8) & 15
    let baseSize = (sizes >> 4) & 15
    guard [0, 4, 8].contains(offsetSize), [4, 8].contains(lengthSize),
      [0, 4, 8].contains(baseSize), sizes & 15 == 0, try location.read(2) == items.count
    else { throw invalid("unsupported extent representation") }
    var located: Set<Int> = []
    let mediaRanges = top.filter { $0.type == "mdat" }.map {
      ($0.start + $0.headerSize)..<($0.start + $0.headerSize + $0.payload.count)
    }
    var materializedBytes = 0
    for _ in items.indices {
      let id = try location.read(2)
      guard located.insert(id).inserted, let index = items.firstIndex(where: { $0.id == id }),
        try location.read(2) == 0
      else { throw invalid("invalid location item or external reference") }
      let base = try location.read(baseSize)
      let extents = try location.read(2)
      guard extents > 0, extents <= 4_096 else { throw invalid("invalid extent count") }
      var payload: [UInt8] = []
      for _ in 0..<extents {
        let offset = try location.read(offsetSize)
        let length = try location.read(lengthSize)
        let (start, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, start <= bytes.count, length <= bytes.count - start,
          length <= bytes.count - materializedBytes,
          mediaRanges.contains(where: { start >= $0.lowerBound && start + length <= $0.upperBound })
        else { throw invalid("item extent exceeds media data") }
        materializedBytes += length
        payload.append(contentsOf: bytes[start..<(start + length)])
      }
      items[index].payload = payload
    }
    try location.finish()

    let propertyChildren = try Self.boxes(try required("iprp").payload)
    guard propertyChildren.count == 2, propertyChildren[0].type == "ipco",
      propertyChildren[1].type == "ipma"
    else { throw invalid("unsupported property container") }
    propertyBoxes = try Self.boxes(propertyChildren[0].payload)
    guard propertyBoxes.count <= 32_760 else { throw invalid("too many properties") }
    var associationReader = AVIFBytes(propertyChildren[1].payload)
    let associationFlags = try associationReader.read(4)
    guard associationFlags == 0 || associationFlags == 1,
      try associationReader.read(4) <= items.count
    else { throw invalid("unsupported property associations") }
    // Read entry_count separately from the fixed header, after checking its bound.
    var countReader = AVIFBytes(propertyChildren[1].payload)
    _ = try countReader.read(4)
    let associationCount = try countReader.read(4)
    associations = [:]
    for _ in 0..<associationCount {
      let id = try associationReader.read(2)
      guard items.contains(where: { $0.id == id }), associations[id] == nil else {
        throw invalid("invalid association item")
      }
      let count = try associationReader.read(1)
      var values: [Int] = []
      for _ in 0..<count {
        let raw = try associationReader.read(associationFlags == 1 ? 2 : 1)
        let index = raw & (associationFlags == 1 ? 0x7FFF : 0x7F)
        guard index > 0, index <= propertyBoxes.count else {
          throw invalid("invalid property index")
        }
        values.append(index | ((raw & (associationFlags == 1 ? 0x8000 : 0x80)) != 0 ? 0x8000 : 0))
      }
      associations[id] = values
    }
    try associationReader.finish()
    references = []
    if let referenceBox = metaChildren.first(where: { $0.type == "iref" }) {
      var reader = AVIFBytes(referenceBox.payload)
      guard try reader.read(4) == 0 else { throw invalid("unsupported reference version") }
      for box in try Self.boxes(try reader.remaining()) {
        var fields = AVIFBytes(box.payload)
        let from = try fields.read(2)
        let count = try fields.read(2)
        var to: [Int] = []
        for _ in 0..<count { to.append(try fields.read(2)) }
        try fields.finish()
        guard items.contains(where: { $0.id == from }),
          to.allSatisfy({ id in items.contains(where: { $0.id == id }) })
        else { throw invalid("reference names nonexistent item") }
        references.append(Reference(type: box.type, from: from, to: to))
      }
    }
  }

  func properties(for itemID: Int) -> [Box] {
    (associations[itemID] ?? []).map { propertyBoxes[($0 & 0x7FFF) - 1] }
  }

  mutating func addDisparity(_ source: Self, xmp: [UInt8]) throws {
    guard let auxiliary = source.items.first(where: { $0.id == source.primaryID }),
      let largestID = items.map(\.id).max(), largestID <= 65_533
    else { throw invalid("cannot allocate auxiliary IDs") }
    let depthID = largestID + 1
    let metadataID = largestID + 2
    let sourceProperties = source.properties(for: source.primaryID)
    guard sourceProperties.allSatisfy({ ["ispe", "pixi", "av1C", "colr"].contains($0.type) }),
      sourceProperties.filter({ $0.type == "av1C" }).count == 1,
      sourceProperties.filter({ $0.type == "ispe" }).count == 1
    else { throw invalid("unsupported auxiliary properties") }
    let depthProperties =
      sourceProperties + [
        Box(type: "auxC", payload: [0, 0, 0, 0] + Array(AVIFDisparity.auxiliaryType.utf8) + [0])
      ]
    associations[depthID] = depthProperties.enumerated().map { offset, box in
      let index = propertyBoxes.count + offset + 1
      return index | (["av1C", "auxC"].contains(box.type) ? 0x8000 : 0)
    }
    propertyBoxes.append(contentsOf: depthProperties)
    items.append(
      Item(
        id: depthID, type: "av01", info: Self.itemInfo(depthID, type: "av01", hidden: true),
        payload: auxiliary.payload))
    items.append(
      Item(
        id: metadataID, type: "mime", info: Self.itemInfo(metadataID, type: "mime", hidden: false),
        payload: xmp))
    references.append(Reference(type: "auxl", from: depthID, to: [primaryID]))
    references.append(Reference(type: "cdsc", from: metadataID, to: [depthID]))
  }

  func standalone(itemID: Int) throws -> [UInt8] {
    guard let item = items.first(where: { $0.id == itemID }) else {
      throw invalid("missing auxiliary item")
    }
    var copy = self
    copy.primaryID = 1
    copy.items = [
      Item(
        id: 1, type: "av01", info: Self.itemInfo(1, type: "av01", hidden: false),
        payload: item.payload)
    ]
    copy.propertyBoxes = properties(for: itemID).filter { $0.type != "auxC" }
    copy.associations = [1: copy.propertyBoxes.indices.map { ($0 + 1) | 0x8000 }]
    copy.references = []
    copy.metaChildren.removeAll { $0.type == "iref" }
    return try copy.serialize()
  }

  func serialize() throws -> [UInt8] {
    let payloadCount = items.reduce(0) { $0 + $1.payload.count }
    guard payloadCount <= Int(UInt32.max) - 8, items.count <= 65_535,
      propertyBoxes.count <= 32_767
    else { throw invalid("container exceeds supported size") }
    func meta(mediaOffset: Int) -> Box {
      var extentOffset = mediaOffset
      var locations =
        [UInt8](arrayLiteral: 0, 0, 0, 0, 0x44, 0)
        + AVIFBytes.u16(items.count)
      for item in items {
        locations +=
          AVIFBytes.u16(item.id) + [0, 0, 0, 1]
          + AVIFBytes.u32(extentOffset) + AVIFBytes.u32(item.payload.count)
        extentOffset += item.payload.count
      }
      let information =
        [UInt8](repeating: 0, count: 4) + AVIFBytes.u16(items.count)
        + items.flatMap { $0.info.bytes }
      var propertyAssociations =
        [UInt8](arrayLiteral: 0, 0, 0, 1)
        + AVIFBytes.u32(associations.count)
      for id in associations.keys.sorted() {
        let values = associations[id]!
        propertyAssociations +=
          AVIFBytes.u16(id) + [UInt8(values.count)]
          + values.flatMap { AVIFBytes.u16($0) }
      }
      let properties =
        Box(type: "ipco", payload: propertyBoxes.flatMap(\.bytes)).bytes
        + Box(type: "ipma", payload: propertyAssociations).bytes
      let referenceData =
        [UInt8](repeating: 0, count: 4)
        + references.flatMap { reference in
          Box(
            type: reference.type,
            payload: AVIFBytes.u16(reference.from)
              + AVIFBytes.u16(reference.to.count) + reference.to.flatMap { AVIFBytes.u16($0) }
          ).bytes
        }
      let replacements: [String: Box] = [
        "pitm": Box(type: "pitm", payload: [0, 0, 0, 0] + AVIFBytes.u16(primaryID)),
        "iloc": Box(type: "iloc", payload: locations),
        "iinf": Box(type: "iinf", payload: information),
        "iprp": Box(type: "iprp", payload: properties),
        "iref": Box(type: "iref", payload: referenceData),
      ]
      var children = metaChildren.map { replacements[$0.type] ?? $0 }
      if !references.isEmpty, !children.contains(where: { $0.type == "iref" }) {
        children.append(replacements["iref"]!)
      }
      return Box(type: "meta", payload: [0, 0, 0, 0] + children.flatMap(\.bytes))
    }
    let firstMeta = meta(mediaOffset: 0)
    let offset = fileType.bytes.count + firstMeta.bytes.count + 8
    guard offset <= Int(UInt32.max) - payloadCount else { throw invalid("file too large") }
    return fileType.bytes + meta(mediaOffset: offset).bytes
      + Box(type: "mdat", payload: items.flatMap(\.payload)).bytes
  }

  private static func itemInfo(_ id: Int, type: String, hidden: Bool) -> Box {
    var payload =
      [UInt8](arrayLiteral: 2, 0, 0, hidden ? 1 : 0)
      + AVIFBytes.u16(id) + [0, 0] + Array(type.utf8) + [0]
    if type == "mime" { payload += Array("application/rdf+xml".utf8) + [0, 0] }
    return Box(type: "infe", payload: payload)
  }

  private static func boxes(_ bytes: [UInt8]) throws -> [Box] {
    var reader = AVIFBytes(bytes)
    var result: [Box] = []
    while reader.offset < bytes.count {
      guard result.count < 65_536 else { throw invalid("too many boxes") }
      let start = reader.offset
      let shortSize = try reader.read(4)
      guard let type = String(bytes: try reader.readBytes(4), encoding: .ascii) else {
        throw invalid("non-ASCII box type")
      }
      let size = shortSize == 1 ? try reader.read(8) : shortSize
      let headerSize = shortSize == 1 ? 16 : 8
      guard size >= headerSize else { throw invalid("invalid or unbounded box size") }
      result.append(
        Box(
          type: type, payload: try reader.readBytes(size - headerSize), start: start,
          headerSize: headerSize))
    }
    return result
  }
}

private struct AVIFBytes {
  let bytes: [UInt8]
  var offset = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  mutating func read(_ count: Int) throws -> Int {
    guard count >= 0, count <= 8 else { throw invalid("unsupported integer field width") }
    let values = try readBytes(count)
    var value: UInt64 = 0
    for byte in values { value = value << 8 | UInt64(byte) }
    guard value <= UInt64(Int.max) else { throw invalid("integer exceeds addressable range") }
    return Int(value)
  }

  mutating func readBytes(_ count: Int) throws -> [UInt8] {
    guard count >= 0, offset <= bytes.count, count <= bytes.count - offset else {
      throw invalid("truncated box or field")
    }
    defer { offset += count }
    return Array(bytes[offset..<(offset + count)])
  }

  mutating func remaining() throws -> [UInt8] { try readBytes(bytes.count - offset) }

  func finish() throws {
    guard offset == bytes.count else { throw invalid("trailing structural bytes") }
  }

  static func u16(_ value: Int) -> [UInt8] {
    [UInt8((value >> 8) & 255), UInt8(value & 255)]
  }

  static func u32(_ value: Int) -> [UInt8] {
    [
      UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
      UInt8((value >> 8) & 255), UInt8(value & 255),
    ]
  }
}

private func invalid(_ reason: String) -> AVIFDisparity.DisparityError {
  .invalidContainer(reason)
}
