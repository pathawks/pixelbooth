// PixelBoothCAvif — Swift wrapper around the pinned libavif 1.3.0 C API.
// Only what the AVIF encoder/decoder core needs; no automatic codec substitution.

import Foundation
@_exported import PixelBoothCAvifShim

public enum PixelBoothLibAvif {
  /// Pinned libavif version string, e.g. "1.3.0".
  public static var version: String {
    String(cString: pixelbooth_avif_version())
  }

  /// AOM codec was explicitly selected (never auto-substituted).
  public static func encoderUsesAOM(_ encoder: UnsafeMutablePointer<avifEncoder>) -> Bool {
    let name = pixelbooth_avif_encoder_codec_name(encoder)
    return name.map { strcmp($0, "aom") == 0 } ?? false
  }
}
