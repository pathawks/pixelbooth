// Synthetic fixtures for persistence/recovery tests (tests only; never
// default application behavior).

import PixelBoothLibrary

/// Deterministic NV12-like plane snapshot (4:2:0, 8-bit, full range).
func syntheticNV12Snapshot(width: Int, height: Int) -> CapturedCapture.PlaneSnapshot {
  var contiguous: [[UInt8]] = []
  contiguous.append((0..<(width * height)).map { UInt8(($0 * 71) % 256) })
  let chromaCount = (width / 2) * (height / 2)
  var u = [UInt8](repeating: 0, count: chromaCount)
  var v = [UInt8](repeating: 0, count: chromaCount)
  for i in u.indices { u[i] = UInt8((i * 97) % 256) }
  for i in v.indices { v[i] = UInt8((i * 131) % 256) }
  contiguous.append(u)
  contiguous.append(v)
  return CapturedCapture.PlaneSnapshot(
    bytesPerRow: [width, width / 2, width / 2],
    rows: [height, height / 2, height / 2],
    bytesPerSample: 1,
    chromaWidth: width / 2, chromaHeight: height / 2,
    contiguous: contiguous)
}
