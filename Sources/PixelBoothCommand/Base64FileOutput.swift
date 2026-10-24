import CryptoKit
import Foundation

public enum Base64FileOutput {
  /// Stream the finalized file without line wrapping or an image-sized text allocation.
  public static func write(file: URL, to output: FileHandle, expectedSHA256: String? = nil) throws {
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    var pending = Data()
    var hasher = SHA256()
    while let chunk = try input.read(upToCount: 48 * 1_024), !chunk.isEmpty {
      try Task.checkCancellation()
      hasher.update(data: chunk)
      pending.append(chunk)
      let completeBytes = pending.count - pending.count % 3
      if completeBytes > 0 {
        try CommandOutput.write(pending.prefix(completeBytes).base64EncodedData(), to: output)
        pending.removeFirst(completeBytes)
      }
    }
    try Task.checkCancellation()
    if let expectedSHA256 {
      let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      guard actual == expectedSHA256 else {
        throw CaptureCommandError(
          "the streamed image failed its integrity check; output is incomplete")
      }
    }
    if !pending.isEmpty { try CommandOutput.write(pending.base64EncodedData(), to: output) }
    try CommandOutput.write(Data([10]), to: output)
  }
}
