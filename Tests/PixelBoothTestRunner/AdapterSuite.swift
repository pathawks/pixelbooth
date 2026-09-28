// Sample-layout adapter tests: random and edge-value fixtures, channel
// ordering, padded strides, packed/bi-planar adapters, 10-bit values.
// Exact native-sample comparisons only.

import PixelBoothCore
import PixelBoothAdapters

func randomFixture(_ count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> [UInt8] {
  var state = seed
  return (0..<count).map { _ in
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return UInt8(truncatingIfNeeded: state >> 33)
  }
}

func runAdapterSuite() {
  suite("Adapters")

  test("yuy2DeinterleaveExact") {
    let w = 8, h = 4
    let rowBytes = w * 2
    var packed = [UInt8]()
    for y in 0..<h {
      for pair in 0..<(w / 2) {
        packed.append(0x10 + UInt8(y))             // Y0
        packed.append(0x40 + UInt8(pair))          // U
        packed.append(0x80 + UInt8(y * 3 + pair))  // Y1
        packed.append(0xC0 + UInt8(pair))          // V
      }
    }
    let planar = try! packed.withUnsafeMutableBytes { raw in
      try SampleLayoutAdapter.adaptYUY2(
        data: raw.baseAddress!, bytesPerRow: rowBytes, width: w, height: h)
    }
    for y in 0..<h {
      let yRow = UnsafeRawPointer(planar.planes[0]).advanced(by: y * planar.bytesPerRow[0])
      let uRow = UnsafeRawPointer(planar.planes[1]).advanced(by: y * planar.bytesPerRow[1])
      let vRow = UnsafeRawPointer(planar.planes[2]).advanced(by: y * planar.bytesPerRow[2])
      for x in 0..<w {
        check(yRow.load(fromByteOffset: x, as: UInt8.self) == packed[y * rowBytes + x * 2],
              "Y mismatch at \(x),\(y)")
      }
      for x in 0..<(w / 2) {
        check(uRow.load(fromByteOffset: x, as: UInt8.self) == 0x40 + UInt8(x), "U mismatch")
        check(vRow.load(fromByteOffset: x, as: UInt8.self) == 0xC0 + UInt8(x), "V mismatch")
      }
    }
  }

  test("uyvyDeinterleaveExact") {
    let w = 4, h = 2
    let rowBytes = w * 2
    var packed: [UInt8] = [
      0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
      0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x0F, 0x10,
    ]
    let planar = try! packed.withUnsafeMutableBytes { raw in
      try SampleLayoutAdapter.adaptUYVY(
        data: raw.baseAddress!, bytesPerRow: rowBytes, width: w, height: h)
    }
    check(UnsafeRawPointer(planar.planes[0]).load(as: UInt8.self) == 0x22, "UYVY Y first")
    check(UnsafeRawPointer(planar.planes[1]).load(as: UInt8.self) == 0x11, "UYVY U first")
    check(UnsafeRawPointer(planar.planes[2]).load(as: UInt8.self) == 0x33, "UYVY V first")
  }

  test("nv12FullAndLimitedRangePreserved") {
    let w = 8, h = 4
    let yRow = w, cRow = w
    var yPlane = [UInt8](repeating: 0, count: yRow * h)
    var chromaPlane = [UInt8](repeating: 0, count: cRow * (h / 2))
    // Legal full-range values incl. superblack(0)/superwhite(255).
    for i in yPlane.indices { yPlane[i] = UInt8((i * 37) % 256) }
    for i in chromaPlane.indices { chromaPlane[i] = UInt8((i * 53) % 256) }
    let planar = try! yPlane.withUnsafeBytes { yp in
      try chromaPlane.withUnsafeBytes { cp in
        try SampleLayoutAdapter.adaptNV12(
          yPlane: yp.baseAddress!, yBytesPerRow: yRow,
          chromaPlane: cp.baseAddress!, chromaBytesPerRow: cRow,
          width: w, height: h)
      }
    }
    for row in 0..<(h / 2) {
      for x in 0..<(w / 2) {
        let srcU = chromaPlane[row * cRow + 2 * x]
        let srcV = chromaPlane[row * cRow + 2 * x + 1]
        let uRow = UnsafeRawPointer(planar.planes[1]).advanced(by: row * planar.bytesPerRow[1])
        let vRow = UnsafeRawPointer(planar.planes[2]).advanced(by: row * planar.bytesPerRow[2])
        check(uRow.load(fromByteOffset: x, as: UInt8.self) == srcU, "U mismatch")
        check(vRow.load(fromByteOffset: x, as: UInt8.self) == srcV, "V mismatch")
      }
    }
    for row in 0..<h {
      let yRowPtr = UnsafeRawPointer(planar.planes[0]).advanced(by: row * planar.bytesPerRow[0])
      for x in 0..<w {
        check(yRowPtr.load(fromByteOffset: x, as: UInt8.self) == yPlane[row * yRow + x],
              "Y passthrough mismatch")
      }
    }
  }

  test("bgraAlphaIsMeaningfulPlane") {
    let w = 4, h = 2
    let rowBytes = w * 4
    var pixels: [UInt8] = []
    for i in 0..<(w * h) {
      pixels.append(UInt8(i))                       // B
      pixels.append(UInt8(255 - i))                 // G
      pixels.append(0xAA)                           // R
      pixels.append(i % 2 == 0 ? 0x00 : 0xFF)       // A (meaningful, not padding)
    }
    let planar = try! pixels.withUnsafeBytes { raw in
      try SampleLayoutAdapter.adaptBGRA32(
        data: raw.baseAddress!, bytesPerRow: rowBytes, width: w, height: h)
    }
    check(planar.planes.count == 4, "BGRA exposes fourth plane")
    for i in 0..<(w * h) {
      let b = UnsafeRawPointer(planar.planes[1]).load(fromByteOffset: i, as: UInt8.self)
      let r = UnsafeRawPointer(planar.planes[2]).load(fromByteOffset: i, as: UInt8.self)
      let a = UnsafeRawPointer(planar.planes[3]).load(fromByteOffset: i, as: UInt8.self)
      check(b == pixels[4 * i], "B in U slot")
      check(r == 0xAA, "R in V slot")
      check(a == pixels[4 * i + 3], "alpha preserved")
    }
  }

  test("paddedStridesPreserveSamples") {
    let w = 4, h = 2
    let realRow = w * 3
    let paddedRow = realRow + 8
    var padded = [UInt8](repeating: 0xEE, count: paddedRow * h)
    for y in 0..<h {
      for x in 0..<w {
        padded[y * paddedRow + x * 3 + 0] = UInt8(x * 3)
        padded[y * paddedRow + x * 3 + 1] = UInt8(y * 7)
        padded[y * paddedRow + x * 3 + 2] = UInt8(x * y)
      }
    }
    let planar = try! padded.withUnsafeMutableBytes { raw in
      try SampleLayoutAdapter.adaptBGR24(
        data: raw.baseAddress!, bytesPerRow: paddedRow, width: w, height: h)
    }
    for y in 0..<h {
      // Plane layout: [G, B, R] in Y,U,V slots; B carries x*3 here.
      let bRowPtr = UnsafeRawPointer(planar.planes[1]).advanced(by: y * planar.bytesPerRow[1])
      let gRowPtr = UnsafeRawPointer(planar.planes[0]).advanced(by: y * planar.bytesPerRow[0])
      let rRowPtr = UnsafeRawPointer(planar.planes[2]).advanced(by: y * planar.bytesPerRow[2])
      for x in 0..<w {
        check(bRowPtr.load(fromByteOffset: x, as: UInt8.self) == UInt8(x * 3),
              "stride padding must not corrupt samples (B)")
        check(gRowPtr.load(fromByteOffset: x, as: UInt8.self) == UInt8(y * 7),
              "stride padding must not corrupt samples (G)")
        check(rRowPtr.load(fromByteOffset: x, as: UInt8.self) == UInt8(x * y),
              "stride padding must not corrupt samples (R)")
      }
    }
  }

  test("oddHeightRejectedFor420") {
    var yPlane = [UInt8](repeating: 0, count: 8 * 3)
    var chroma = [UInt8](repeating: 0, count: 4 * 2)
    var thrown = false
    do {
      _ = try yPlane.withUnsafeBytes { yp -> PlanarImage in
        try chroma.withUnsafeBytes { cp -> PlanarImage in
          try SampleLayoutAdapter.adaptNV12(
            yPlane: yp.baseAddress!, yBytesPerRow: 8,
            chromaPlane: cp.baseAddress!, chromaBytesPerRow: 4,
            width: 8, height: 3)
        }
      }
    } catch {
      thrown = true
    }
    check(thrown, "odd height must be rejected, not converted")
  }

  test("tenBitBiPlanarPreservesValues") {
    let w = 4, h = 2
    var yPlane = [UInt16](repeating: 0, count: w * h)
    var chroma = [UInt16](repeating: 0, count: w * h / 2)
    for i in yPlane.indices { yPlane[i] = UInt16((i * 173) % 1024) }
    for i in chroma.indices { chroma[i] = UInt16((i * 331) % 1024) }
    let planar = try! yPlane.withUnsafeBytes { yp in
      try chroma.withUnsafeBytes { cp in
        try SampleLayoutAdapter.adaptBiPlanar10BitYUV(
          yPlane: yp.baseAddress!, yBytesPerRow: w * 2,
          chromaPlane: cp.baseAddress!, chromaBytesPerRow: w * 2,
          width: w, height: h)
      }
    }
    check(planar.bitsPerChannel == 10, "10-bit depth reported")
    for row in 0..<(h / 2) {
      for x in 0..<(w / 2) {
        let uRow = UnsafeRawPointer(planar.planes[1]).advanced(by: row * planar.bytesPerRow[1])
        let vRow = UnsafeRawPointer(planar.planes[2]).advanced(by: row * planar.bytesPerRow[2])
        check(uRow.load(fromByteOffset: 2 * x, as: UInt16.self) == chroma[row * w + 2 * x], "U mismatch")
        check(vRow.load(fromByteOffset: 2 * x, as: UInt16.self) == chroma[row * w + 2 * x + 1], "V mismatch")
      }
    }
  }
}
