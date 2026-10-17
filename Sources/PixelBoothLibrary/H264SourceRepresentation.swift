import CoreMedia
import Foundation
import PixelBoothCore

/// H.264 representation facts recovered from the active sequence parameter
/// set. The archival decoder currently accepts only progressive 8-bit 4:2:0.
public struct H264SourceRepresentation: Equatable, Sendable {
  public enum Range: String, Equatable, Sendable {
    case full
    case limited
  }

  public let profileIDC: UInt8
  public let chromaFormatIDC: UInt32
  public let bitDepthLuma: UInt32
  public let bitDepthChroma: UInt32
  public let isProgressive: Bool
  public let range: Range

  public var outputPixelFormat: UInt32 {
    range == .full ? PixelFormatFourCC.fourTwentyF : PixelFormatFourCC.fourTwentyV
  }

  public enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
    case parameterSetsUnavailable
    case malformedSequenceParameterSet
    case conflictingSequenceParameterSets
    case unsupportedRepresentation(String)

    public var errorDescription: String? {
      switch self {
      case .parameterSetsUnavailable:
        return
          "The H.264 format does not expose its sequence parameter set, so source precision and sampling cannot be verified."
      case .malformedSequenceParameterSet:
        return
          "The H.264 sequence parameter set is malformed; PixelBooth cannot verify the source representation."
      case .conflictingSequenceParameterSets:
        return
          "The H.264 format contains conflicting sequence parameter sets; PixelBooth cannot verify which representation applies."
      case .unsupportedRepresentation(let details):
        return "PixelBooth cannot preserve this H.264 source representation: \(details)."
      }
    }
  }

  /// Reads all SPS NAL units in the Core Media format description. Apple
  /// documents that this API returns the parameter sets from the AVC decoder
  /// configuration record without copying the owning format description.
  public static func inspect(formatDescription: CMFormatDescription) throws -> Self {
    guard CMFormatDescriptionGetMediaSubType(formatDescription) == PixelFormatFourCC.avc1 else {
      throw Error.parameterSetsUnavailable
    }

    var firstPointer: UnsafePointer<UInt8>?
    var firstSize = 0
    var parameterSetCount = 0
    var nalUnitHeaderLength: Int32 = 0
    let firstStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
      formatDescription, parameterSetIndex: 0, parameterSetPointerOut: &firstPointer,
      parameterSetSizeOut: &firstSize, parameterSetCountOut: &parameterSetCount,
      nalUnitHeaderLengthOut: &nalUnitHeaderLength)
    guard firstStatus == noErr, parameterSetCount > 0, parameterSetCount <= 256,
      nalUnitHeaderLength > 0
    else { throw Error.parameterSetsUnavailable }

    var representations: [Self] = []
    for index in 0..<parameterSetCount {
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer,
        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
      guard status == noErr, let pointer, size > 0, size <= 1_048_576 else {
        throw Error.parameterSetsUnavailable
      }
      let bytes = Array(UnsafeBufferPointer(start: pointer, count: size))
      guard bytes.first.map({ $0 & 0x1f }) == 7 else { continue }
      representations.append(try parseSequenceParameterSet(bytes))
    }

    guard let first = representations.first else { throw Error.parameterSetsUnavailable }
    guard representations.dropFirst().allSatisfy({ $0 == first }) else {
      throw Error.conflictingSequenceParameterSets
    }
    return first
  }

  /// Parses only source-representation fields needed by the archival gate.
  /// Parameter-set pointers and arrays are bounded before any bit reads.
  public static func parseSequenceParameterSet(_ nalUnit: [UInt8]) throws -> Self {
    guard nalUnit.count >= 4, nalUnit.count <= 1_048_576,
      nalUnit[0] & 0x80 == 0, nalUnit[0] & 0x1f == 7
    else { throw Error.malformedSequenceParameterSet }

    let rbsp = try removeEmulationPreventionBytes(Array(nalUnit.dropFirst()))
    var bits = try H264BitReader(bytes: rbsp)
    let profile = UInt8(try bits.readBits(8))
    _ = try bits.readBits(8)  // constraint flags and reserved bits
    _ = try bits.readBits(8)  // level_idc
    _ = try bits.readUnsignedExpGolomb()  // seq_parameter_set_id

    var chromaFormatIDC: UInt32 = 1
    var bitDepthLuma: UInt32 = 8
    var bitDepthChroma: UInt32 = 8
    var separateColourPlane = false
    if highProfileIDs.contains(profile) {
      chromaFormatIDC = try bits.readUnsignedExpGolomb()
      guard chromaFormatIDC <= 3 else { throw Error.malformedSequenceParameterSet }
      if chromaFormatIDC == 3 { separateColourPlane = try bits.readBit() == 1 }
      let lumaMinus8 = try bits.readUnsignedExpGolomb()
      let chromaMinus8 = try bits.readUnsignedExpGolomb()
      guard lumaMinus8 <= 8, chromaMinus8 <= 8 else {
        throw Error.malformedSequenceParameterSet
      }
      bitDepthLuma = lumaMinus8 + 8
      bitDepthChroma = chromaMinus8 + 8
      _ = try bits.readBit()  // qpprime_y_zero_transform_bypass_flag
      if try bits.readBit() == 1 {
        let listCount = chromaFormatIDC == 3 ? 12 : 8
        for listIndex in 0..<listCount where try bits.readBit() == 1 {
          try bits.skipScalingList(listIndex < 6 ? 16 : 64)
        }
      }
    }

    _ = try bits.readUnsignedExpGolomb()  // log2_max_frame_num_minus4
    let picOrderCountType = try bits.readUnsignedExpGolomb()
    switch picOrderCountType {
    case 0:
      _ = try bits.readUnsignedExpGolomb()
    case 1:
      _ = try bits.readBit()
      _ = try bits.readSignedExpGolomb()
      _ = try bits.readSignedExpGolomb()
      let cycleCount = try bits.readUnsignedExpGolomb()
      guard cycleCount <= 255 else { throw Error.malformedSequenceParameterSet }
      for _ in 0..<cycleCount { _ = try bits.readSignedExpGolomb() }
    case 2:
      break
    default:
      throw Error.malformedSequenceParameterSet
    }
    _ = try bits.readUnsignedExpGolomb()  // max_num_ref_frames
    _ = try bits.readBit()  // gaps_in_frame_num_value_allowed_flag
    _ = try bits.readUnsignedExpGolomb()  // pic_width_in_mbs_minus1
    _ = try bits.readUnsignedExpGolomb()  // pic_height_in_map_units_minus1
    let frameMbsOnly = try bits.readBit() == 1
    if !frameMbsOnly { _ = try bits.readBit() }  // mb_adaptive_frame_field_flag
    _ = try bits.readBit()  // direct_8x8_inference_flag
    if try bits.readBit() == 1 {
      _ = try bits.readUnsignedExpGolomb()
      _ = try bits.readUnsignedExpGolomb()
      _ = try bits.readUnsignedExpGolomb()
      _ = try bits.readUnsignedExpGolomb()
    }

    // H.264 infers video_full_range_flag to zero when absent.
    var range: Range = .limited
    if try bits.readBit() == 1 {  // vui_parameters_present_flag
      if try bits.readBit() == 1 {  // aspect_ratio_info_present_flag
        let aspectRatioIDC = try bits.readBits(8)
        if aspectRatioIDC == 255 { _ = try bits.readBits(32) }
      }
      if try bits.readBit() == 1 { _ = try bits.readBit() }  // overscan_info
      if try bits.readBit() == 1 {  // video_signal_type_present_flag
        _ = try bits.readBits(3)  // video_format
        range = try bits.readBit() == 1 ? .full : .limited
        if try bits.readBit() == 1 { _ = try bits.readBits(24) }  // colour_description
      }
    }

    return Self(
      profileIDC: profile, chromaFormatIDC: separateColourPlane ? 4 : chromaFormatIDC,
      bitDepthLuma: bitDepthLuma, bitDepthChroma: bitDepthChroma,
      isProgressive: frameMbsOnly, range: range)
  }

  /// Throws unless every representation property matches the currently tested
  /// lossless sample adapter and requested VideoToolbox output pixel format.
  public func validateForArchival() throws {
    guard isProgressive else {
      throw Error.unsupportedRepresentation("interlaced or field-coded pictures")
    }
    guard chromaFormatIDC == 1 else {
      throw Error.unsupportedRepresentation("chroma_format_idc=\(chromaFormatIDC), not 4:2:0")
    }
    guard bitDepthLuma == 8, bitDepthChroma == 8 else {
      throw Error.unsupportedRepresentation(
        "\(bitDepthLuma)-bit luma and \(bitDepthChroma)-bit chroma; only 8-bit is currently verified"
      )
    }
  }

  private init(
    profileIDC: UInt8, chromaFormatIDC: UInt32, bitDepthLuma: UInt32,
    bitDepthChroma: UInt32, isProgressive: Bool, range: Range
  ) {
    self.profileIDC = profileIDC
    self.chromaFormatIDC = chromaFormatIDC
    self.bitDepthLuma = bitDepthLuma
    self.bitDepthChroma = bitDepthChroma
    self.isProgressive = isProgressive
    self.range = range
  }

  private static let highProfileIDs: Set<UInt8> = [
    44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 144, 244,
  ]

  private static func removeEmulationPreventionBytes(_ bytes: [UInt8]) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count)
    var zeroCount = 0
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if zeroCount >= 2, byte == 3 {
        guard index + 1 < bytes.count, bytes[index + 1] <= 3 else {
          throw Error.malformedSequenceParameterSet
        }
        zeroCount = 0
        index += 1
        continue
      }
      result.append(byte)
      zeroCount = byte == 0 ? zeroCount + 1 : 0
      index += 1
    }
    return result
  }
}

private struct H264BitReader {
  private let bytes: [UInt8]
  private var bitOffset = 0

  init(bytes: [UInt8]) throws {
    guard !bytes.isEmpty, bytes.count <= 1_048_576 else {
      throw H264SourceRepresentation.Error.malformedSequenceParameterSet
    }
    self.bytes = bytes
  }

  mutating func readBit() throws -> UInt32 {
    guard bitOffset < bytes.count * 8 else {
      throw H264SourceRepresentation.Error.malformedSequenceParameterSet
    }
    let value = (bytes[bitOffset / 8] >> (7 - bitOffset % 8)) & 1
    bitOffset += 1
    return UInt32(value)
  }

  mutating func readBits(_ count: Int) throws -> UInt32 {
    guard (0...32).contains(count) else {
      throw H264SourceRepresentation.Error.malformedSequenceParameterSet
    }
    var result: UInt32 = 0
    for _ in 0..<count { result = (result << 1) | (try readBit()) }
    return result
  }

  mutating func readUnsignedExpGolomb() throws -> UInt32 {
    var leadingZeroBits = 0
    while try readBit() == 0 {
      leadingZeroBits += 1
      guard leadingZeroBits <= 31 else {
        throw H264SourceRepresentation.Error.malformedSequenceParameterSet
      }
    }
    guard leadingZeroBits > 0 else { return 0 }
    let suffix = try readBits(leadingZeroBits)
    let value = ((UInt64(1) << leadingZeroBits) - 1) + UInt64(suffix)
    guard value <= UInt64(UInt32.max) else {
      throw H264SourceRepresentation.Error.malformedSequenceParameterSet
    }
    return UInt32(value)
  }

  mutating func readSignedExpGolomb() throws -> Int32 {
    let codeNum = try readUnsignedExpGolomb()
    let magnitude = Int64((UInt64(codeNum) + 1) / 2)
    let value = codeNum.isMultiple(of: 2) ? -magnitude : magnitude
    guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
      throw H264SourceRepresentation.Error.malformedSequenceParameterSet
    }
    return Int32(value)
  }

  mutating func skipScalingList(_ size: Int) throws {
    var lastScale = 8
    var nextScale = 8
    for _ in 0..<size {
      if nextScale != 0 {
        let deltaScale = Int(try readSignedExpGolomb())
        nextScale = (lastScale + deltaScale + 256) % 256
      }
      if nextScale != 0 { lastScale = nextScale }
    }
  }
}
