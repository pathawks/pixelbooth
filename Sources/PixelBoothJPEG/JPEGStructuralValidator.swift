import Foundation

/// Validates the image-coding tables and scan structure without decoding the
/// compressed image data. Only Huffman DCT baseline, extended sequential and
/// progressive processes are accepted by the archival path.
enum JPEGStructuralValidator {
  private struct Component {
    var quantizationTable: Int
  }

  private struct Frame {
    var marker: UInt8
    var components: [UInt8: Component]
  }

  private struct Tables {
    var quantization: Set<Int> = []
    var dcHuffman: Set<Int> = []
    var acHuffman: Set<Int> = []
    var restartInterval = 0
  }

  private struct ScanState {
    var sequentialComponents: Set<UInt8> = []
    var progressiveAl: [UInt8: [Int]]

    init(frame: Frame) {
      progressiveAl = Dictionary(
        uniqueKeysWithValues: frame.components.keys.map {
          ($0, Array(repeating: -1, count: 64))
        })
    }
  }

  private struct Scan {
    var offset: Int
    var componentSelectors: [(id: UInt8, dc: Int, ac: Int)]
    var spectralStart: Int
    var spectralEnd: Int
    var successiveHigh: Int
    var successiveLow: Int
  }

  static func validate(_ data: [UInt8]) throws {
    guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else {
      throw JPEGError.notAJPEG
    }
    var index = 2
    var frame: Frame?
    var tables = Tables()
    while index < data.count {
      let markerStart = index
      let markerIndex = try readMarker(data, from: &index)
      let marker = data[markerIndex]
      switch marker {
      case 0xD8, 0xD9, 0xD0...0xD7:
        throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
      case 0x01:
        throw JPEGError.unsupportedCodingProcess(marker: marker)
      case 0xDA:
        guard let frame else {
          throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
        }
        let end = try segmentEnd(data, markerIndex: markerIndex, marker: marker, start: markerStart)
        let scan = try parseScan(data, markerIndex: markerIndex, endIndex: end, frame: frame)
        var state = ScanState(frame: frame)
        try validateAndRecord(scan, frame: frame, tables: tables, state: &state)
        try validateEntropyAndFollowingScans(
          data, from: end, frame: frame, tables: &tables, state: &state)
        return
      default:
        let end = try segmentEnd(data, markerIndex: markerIndex, marker: marker, start: markerStart)
        if isStartOfFrame(marker) {
          guard marker == 0xC0 || marker == 0xC1 || marker == 0xC2 else {
            throw JPEGError.unsupportedCodingProcess(marker: marker)
          }
          guard frame == nil else {
            throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
          }
          frame = try parseFrame(data, markerIndex: markerIndex, endIndex: end, start: markerStart)
        } else if marker == 0xDB {
          try parseQuantizationTables(
            data, markerIndex: markerIndex, endIndex: end, tables: &tables)
        } else if marker == 0xC4 {
          try parseHuffmanTables(data, markerIndex: markerIndex, endIndex: end, tables: &tables)
        } else if marker == 0xCC {
          throw JPEGError.unsupportedCodingProcess(marker: marker)
        } else if marker == 0xDD {
          try parseRestartInterval(data, markerIndex: markerIndex, endIndex: end, tables: &tables)
        } else if isStartOfFrame(marker) {
          throw JPEGError.unsupportedCodingProcess(marker: marker)
        }
        index = end
      }
    }
    throw JPEGError.truncated
  }

  private static func validateEntropyAndFollowingScans(
    _ data: [UInt8], from start: Int, frame: Frame,
    tables: inout Tables, state: inout ScanState
  ) throws {
    var index = start
    var scanHasEntropy = false
    var betweenScans = false
    var nextRestartMarker: UInt8 = 0xD0
    while index < data.count {
      guard data[index] == 0xFF else {
        scanHasEntropy = true
        index += 1
        continue
      }

      let markerStart = index
      let markerIndex = try readMarker(data, from: &index)
      let marker = data[markerIndex]
      switch marker {
      case 0x00:
        scanHasEntropy = true
        index = markerIndex + 1
      case 0xD0...0xD7:
        guard tables.restartInterval > 0, scanHasEntropy, marker == nextRestartMarker else {
          throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
        }
        nextRestartMarker = marker == 0xD7 ? 0xD0 : marker + 1
        scanHasEntropy = false
        index = markerIndex + 1
      case 0xD9:
        guard scanHasEntropy, markerIndex == data.count - 1 else {
          throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
        }
        try validateCompleteImage(frame: frame, state: state, marker: marker, offset: markerStart)
        return
      case 0xD8:
        throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
      case 0xDA:
        guard scanHasEntropy || betweenScans else {
          throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
        }
        let end = try segmentEnd(data, markerIndex: markerIndex, marker: marker, start: markerStart)
        let scan = try parseScan(data, markerIndex: markerIndex, endIndex: end, frame: frame)
        try validateAndRecord(scan, frame: frame, tables: tables, state: &state)
        scanHasEntropy = false
        betweenScans = false
        nextRestartMarker = 0xD0
        index = end
      case 0xDB, 0xC4, 0xDD:
        guard scanHasEntropy || betweenScans else {
          throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
        }
        if scanHasEntropy {
          scanHasEntropy = false
          betweenScans = true
        }
        let end = try segmentEnd(data, markerIndex: markerIndex, marker: marker, start: markerStart)
        if marker == 0xDB {
          try parseQuantizationTables(
            data, markerIndex: markerIndex, endIndex: end, tables: &tables)
        } else if marker == 0xC4 {
          try parseHuffmanTables(data, markerIndex: markerIndex, endIndex: end, tables: &tables)
        } else {
          try parseRestartInterval(data, markerIndex: markerIndex, endIndex: end, tables: &tables)
        }
        index = end
      case 0xE0...0xEF, 0xFE:
        guard scanHasEntropy || betweenScans else {
          throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
        }
        if scanHasEntropy {
          scanHasEntropy = false
          betweenScans = true
        }
        let end = try segmentEnd(data, markerIndex: markerIndex, marker: marker, start: markerStart)
        index = end
      case 0x01:
        throw JPEGError.unsupportedCodingProcess(marker: marker)
      default:
        if isStartOfFrame(marker) || marker == 0xCC {
          throw JPEGError.unsupportedCodingProcess(marker: marker)
        }
        throw JPEGError.malformedSegment(marker: marker, offset: markerStart)
      }
    }
    throw JPEGError.truncated
  }

  private static func validateCompleteImage(
    frame: Frame, state: ScanState, marker: UInt8, offset: Int
  ) throws {
    if frame.marker == 0xC2 {
      guard frame.components.keys.allSatisfy({ (state.progressiveAl[$0]?[0] ?? -1) >= 0 }) else {
        throw JPEGError.malformedSegment(marker: marker, offset: offset)
      }
    } else {
      guard state.sequentialComponents == Set(frame.components.keys) else {
        throw JPEGError.malformedSegment(marker: marker, offset: offset)
      }
    }
  }

  private static func validateAndRecord(
    _ scan: Scan, frame: Frame, tables: Tables, state: inout ScanState
  ) throws {
    let marker: UInt8 = 0xDA
    let selectedIDs = scan.componentSelectors.map(\.id)
    guard !selectedIDs.isEmpty, Set(selectedIDs).count == selectedIDs.count,
      selectedIDs.allSatisfy({ frame.components[$0] != nil })
    else { throw JPEGError.malformedSegment(marker: marker, offset: scan.offset) }

    for selector in scan.componentSelectors {
      guard let component = frame.components[selector.id],
        tables.quantization.contains(component.quantizationTable)
      else { throw JPEGError.malformedSegment(marker: marker, offset: scan.offset) }
    }

    if frame.marker == 0xC2 {
      let dcScan = scan.spectralStart == 0
      guard scan.spectralStart <= scan.spectralEnd, scan.spectralEnd <= 63,
        scan.successiveHigh <= 13, scan.successiveLow <= 13,
        dcScan ? scan.spectralEnd == 0 : scan.componentSelectors.count == 1,
        scan.successiveHigh == 0 || scan.successiveHigh == scan.successiveLow + 1
      else { throw JPEGError.malformedSegment(marker: marker, offset: scan.offset) }

      for selector in scan.componentSelectors {
        guard var coefficients = state.progressiveAl[selector.id] else {
          throw JPEGError.malformedSegment(marker: marker, offset: scan.offset)
        }
        let spectralRange = scan.spectralStart...scan.spectralEnd
        if scan.successiveHigh == 0 {
          guard spectralRange.allSatisfy({ coefficients[$0] == -1 }) else {
            throw JPEGError.malformedSegment(marker: marker, offset: scan.offset)
          }
        } else {
          guard spectralRange.allSatisfy({ coefficients[$0] == scan.successiveHigh }) else {
            throw JPEGError.malformedSegment(marker: marker, offset: scan.offset)
          }
        }
        for coefficient in spectralRange { coefficients[coefficient] = scan.successiveLow }
        state.progressiveAl[selector.id] = coefficients

        if dcScan, scan.successiveHigh == 0 {
          guard tables.dcHuffman.contains(selector.dc) else {
            throw JPEGError.malformedSegment(marker: marker, offset: scan.offset)
          }
        } else if !dcScan {
          guard tables.acHuffman.contains(selector.ac) else {
            throw JPEGError.malformedSegment(marker: marker, offset: scan.offset)
          }
        }
      }
    } else {
      guard scan.spectralStart == 0, scan.spectralEnd == 63,
        scan.successiveHigh == 0, scan.successiveLow == 0,
        selectedIDs.allSatisfy({ !state.sequentialComponents.contains($0) })
      else { throw JPEGError.malformedSegment(marker: marker, offset: scan.offset) }
      for selector in scan.componentSelectors {
        guard tables.dcHuffman.contains(selector.dc), tables.acHuffman.contains(selector.ac) else {
          throw JPEGError.malformedSegment(marker: marker, offset: scan.offset)
        }
        state.sequentialComponents.insert(selector.id)
      }
    }
  }

  private static func parseFrame(
    _ data: [UInt8], markerIndex: Int, endIndex: Int, start: Int
  ) throws -> Frame {
    let marker = data[markerIndex]
    guard endIndex - markerIndex >= 9 else {
      throw JPEGError.malformedSegment(marker: marker, offset: start)
    }
    let precision = data[markerIndex + 3]
    let componentCount = Int(data[markerIndex + 8])
    let expectedPayload = 8 + 3 * componentCount
    guard componentCount > 0, componentCount <= 4,
      endIndex - markerIndex - 1 == expectedPayload,
      marker == 0xC0 ? precision == 8 : precision == 8 || precision == 12
    else { throw JPEGError.malformedSegment(marker: marker, offset: start) }

    var components: [UInt8: Component] = [:]
    for componentIndex in 0..<componentCount {
      let offset = markerIndex + 9 + 3 * componentIndex
      let id = data[offset]
      let sampling = data[offset + 1]
      let horizontal = sampling >> 4
      let vertical = sampling & 0x0F
      let quantizationTable = Int(data[offset + 2])
      guard components[id] == nil, (1...4).contains(horizontal), (1...4).contains(vertical),
        quantizationTable <= 3
      else { throw JPEGError.malformedSegment(marker: marker, offset: start) }
      components[id] = Component(quantizationTable: quantizationTable)
    }
    return Frame(marker: marker, components: components)
  }

  private static func parseScan(
    _ data: [UInt8], markerIndex: Int, endIndex: Int, frame: Frame
  ) throws -> Scan {
    let marker: UInt8 = 0xDA
    guard endIndex - markerIndex >= 8 else {
      throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
    }
    let scanComponentCount = Int(data[markerIndex + 3])
    guard scanComponentCount > 0, scanComponentCount <= 4,
      endIndex - markerIndex - 1 == 6 + 2 * scanComponentCount
    else { throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1) }

    var selectors: [(id: UInt8, dc: Int, ac: Int)] = []
    for index in 0..<scanComponentCount {
      let id = data[markerIndex + 4 + 2 * index]
      let tableSelector = data[markerIndex + 5 + 2 * index]
      let dc = Int(tableSelector >> 4)
      let ac = Int(tableSelector & 0x0F)
      guard frame.components[id] != nil, dc <= 3, ac <= 3 else {
        throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
      }
      selectors.append((id, dc, ac))
    }
    let tail = markerIndex + 4 + 2 * scanComponentCount
    let spectralStart = Int(data[tail])
    let spectralEnd = Int(data[tail + 1])
    let successive = data[tail + 2]
    return Scan(
      offset: markerIndex - 1, componentSelectors: selectors,
      spectralStart: spectralStart, spectralEnd: spectralEnd,
      successiveHigh: Int(successive >> 4), successiveLow: Int(successive & 0x0F))
  }

  private static func parseQuantizationTables(
    _ data: [UInt8], markerIndex: Int, endIndex: Int, tables: inout Tables
  ) throws {
    let marker: UInt8 = 0xDB
    var cursor = markerIndex + 3
    while cursor < endIndex {
      let info = data[cursor]
      cursor += 1
      let precision = Int(info >> 4)
      let identifier = Int(info & 0x0F)
      guard precision <= 1, identifier <= 3 else {
        throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
      }
      let bytesPerValue = precision + 1
      let tableBytes = 64 * bytesPerValue
      guard tableBytes <= endIndex - cursor else {
        throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
      }
      for valueIndex in 0..<64 {
        let valueOffset = cursor + valueIndex * bytesPerValue
        let value =
          precision == 0
          ? Int(data[valueOffset])
          : (Int(data[valueOffset]) << 8) | Int(data[valueOffset + 1])
        guard value > 0 else {
          throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
        }
      }
      cursor += tableBytes
      tables.quantization.insert(identifier)
    }
  }

  private static func parseHuffmanTables(
    _ data: [UInt8], markerIndex: Int, endIndex: Int, tables: inout Tables
  ) throws {
    let marker: UInt8 = 0xC4
    var cursor = markerIndex + 3
    while cursor < endIndex {
      guard endIndex - cursor >= 17 else {
        throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
      }
      let info = data[cursor]
      cursor += 1
      let tableClass = Int(info >> 4)
      let identifier = Int(info & 0x0F)
      guard tableClass <= 1, identifier <= 3 else {
        throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
      }
      let counts = Array(data[cursor..<(cursor + 16)]).map(Int.init)
      cursor += 16
      let symbolCount = counts.reduce(0, +)
      guard symbolCount > 0, symbolCount <= 256, symbolCount <= endIndex - cursor else {
        throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
      }
      var availableCodes = 1
      for count in counts {
        availableCodes = availableCodes * 2 - count
        guard availableCodes >= 0 else {
          throw JPEGError.malformedSegment(marker: marker, offset: markerIndex - 1)
        }
      }
      cursor += symbolCount
      if tableClass == 0 {
        tables.dcHuffman.insert(identifier)
      } else {
        tables.acHuffman.insert(identifier)
      }
    }
  }

  private static func parseRestartInterval(
    _ data: [UInt8], markerIndex: Int, endIndex: Int, tables: inout Tables
  ) throws {
    guard endIndex - markerIndex == 5 else {
      throw JPEGError.malformedSegment(marker: 0xDD, offset: markerIndex - 1)
    }
    tables.restartInterval = (Int(data[markerIndex + 3]) << 8) | Int(data[markerIndex + 4])
  }

  private static func readMarker(_ data: [UInt8], from index: inout Int) throws -> Int {
    guard index < data.count, data[index] == 0xFF else {
      throw JPEGError.malformedSegment(marker: 0, offset: index)
    }
    while index < data.count, data[index] == 0xFF { index += 1 }
    guard index < data.count else { throw JPEGError.truncated }
    let markerIndex = index
    index += 1
    return markerIndex
  }

  private static func segmentEnd(
    _ data: [UInt8], markerIndex: Int, marker: UInt8, start: Int
  ) throws -> Int {
    guard markerIndex < data.count, data.count - markerIndex >= 3 else { throw JPEGError.truncated }
    let length = (Int(data[markerIndex + 1]) << 8) | Int(data[markerIndex + 2])
    guard length >= 2 else { throw JPEGError.malformedSegment(marker: marker, offset: start) }
    let bytesFromLength = data.count - (markerIndex + 1)
    guard length <= bytesFromLength else { throw JPEGError.truncated }
    return markerIndex + 1 + length
  }

  private static func isStartOfFrame(_ marker: UInt8) -> Bool {
    switch marker {
    case 0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF: true
    default: false
    }
  }
}
