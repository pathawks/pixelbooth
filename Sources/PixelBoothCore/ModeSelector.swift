import Foundation

/// Deterministic camera/mode selection ranking, per the product spec:
/// 1. largest pixel area; 2. greatest width; 3. uncompressed > MJPEG > H.264;
/// 4. higher supported bit depth and chroma detail; 5. maximum frame rate;
/// 6. stable identifier as final tie-breaker. Area and width always dominate.
public enum ModeSelector {
  /// Bits per channel we can derive from the FourCC; nil = unknown.
  public static func bitsPerChannel(of f: CaptureFormat) -> Int? {
    if let b = f.bitsPerChannel { return b }
    switch f.fourCC {
    case 0x3231_3276: return 10  // v210
    case 0x3236_3179: return 10  // y216 container, 10-bit meaningful
    default: return 8  // 8-bit layouts
    }
  }

  /// Chroma sampling we can derive from the FourCC; nil = unknown/not applicable.
  public static func chromaSampling(of f: CaptureFormat) -> CaptureFormat.ChromaSampling? {
    if let c = f.chromaSampling { return c }
    switch f.fourCC {
    case 0x4e56_3132, 0x6630_3234, 0x7630_3234: return .yuv420  // NV12, 420f, 420v
    case 0x3275_7976, 0x7375_7679: return .yuv422  // YUY2, UYVY
    case 0x3830_3476: return .yuv444  // v408
    default: return nil
    }
  }

  /// Rank a list of modes; returns the mode the spec says to pick on first
  /// selection or explicit reset.
  public static func preferredMode(_ modes: [CameraMode]) -> CameraMode? {
    modes.max { a, b in
      compare(a, b) == .orderedAscending
    }
  }

  /// Resolve a remembered selection, migrating the former rate-based ID only
  /// when it identifies one unambiguous representation in the current list.
  public static func rememberedMode(id: String, in modes: [CameraMode]) -> CameraMode? {
    if let exact = modes.first(where: { $0.id == id }) {
      return exact
    }
    let matches = modes.filter { $0.matchesLegacyRateBasedID(id) }
    let identities = Set(matches.map(\.id))
    guard identities.count == 1 else { return nil }
    return matches.first
  }

  /// The CLI can rank full per-pixel RGB components alongside YUV444 detail.
  /// This affects ordering only; actual RGB sampling metadata remains unchanged.
  /// The default retains the GUI's established mode-selection behavior.
  public static func compare(
    _ a: CameraMode, _ b: CameraMode, rankRGBAsFullColor: Bool = false
  ) -> ComparisonResult {
    let areaA = a.dimensions.width * a.dimensions.height
    let areaB = b.dimensions.width * b.dimensions.height
    if areaA != areaB { return areaA < areaB ? .orderedAscending : .orderedDescending }
    if a.dimensions.width != b.dimensions.width {
      return a.dimensions.width < b.dimensions.width ? .orderedAscending : .orderedDescending
    }
    // Same dimensions: prefer uncompressed > MJPEG > H.264. Lower rank is
    // better, so the better mode sorts as "greater" for max-selection.
    let rankA = codecRank(a.codecFamily)
    let rankB = codecRank(b.codecFamily)
    if rankA != rankB { return rankA < rankB ? .orderedDescending : .orderedAscending }
    // Higher supported bit depth.
    let depthA = a.bitsPerChannel ?? 8
    let depthB = b.bitsPerChannel ?? 8
    if depthA != depthB { return depthA < depthB ? .orderedAscending : .orderedDescending }
    // Higher chroma detail (444 > 422 > 420).
    let detailA =
      rankRGBAsFullColor && a.codecFamily == .uncompressedRGB ? 3 : chromaDetail(a.chromaSampling)
    let detailB =
      rankRGBAsFullColor && b.codecFamily == .uncompressedRGB ? 3 : chromaDetail(b.chromaSampling)
    if detailA != detailB { return detailA < detailB ? .orderedAscending : .orderedDescending }
    // Maximum frame rate.
    if a.maxFrameRate != b.maxFrameRate {
      return a.maxFrameRate < b.maxFrameRate ? .orderedAscending : .orderedDescending
    }
    // Stable identifier as final deterministic tie-breaker; the
    // lexicographically smaller stableID wins.
    if a.stableID != b.stableID {
      return a.stableID < b.stableID ? .orderedDescending : .orderedAscending
    }
    return .orderedSame
  }

  static func codecRank(_ family: CaptureCodecFamily) -> Int {
    switch family {
    case .uncompressedRGB, .uncompressedYUV: return 0
    case .nativeJPEG: return 1
    case .h264: return 2
    case .unknown: return 3
    }
  }

  /// Chroma detail preference value; higher = more detail.
  static func chromaDetail(_ cs: CaptureFormat.ChromaSampling?) -> Int {
    switch cs {
    case .yuv444: return 3
    case .yuv422: return 2
    case .yuv420: return 1
    case .monochrome, nil: return 0
    }
  }
}
