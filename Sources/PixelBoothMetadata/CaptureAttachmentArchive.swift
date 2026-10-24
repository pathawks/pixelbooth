import Foundation

/// Versioned, lossless attachment payloads. Property-list data retains binary
/// values and nested dictionaries instead of converting them to descriptions.
public struct CaptureAttachmentArchive: Hashable, Sendable, Codable {
  public struct Entry: Hashable, Sendable, Codable {
    public var scope: String
    public var key: String
    public var encoding: String
    public var payload: Data
    public var exact: Bool

    public init(scope: String, key: String, encoding: String, payload: Data, exact: Bool = true) {
      self.scope = scope
      self.key = key
      self.encoding = encoding
      self.payload = payload
      self.exact = exact
    }
  }

  public var version = 1
  public var entries: [Entry]
  public var issues: [String]

  public init(entries: [Entry] = [], issues: [String] = []) {
    self.entries = entries
    self.issues = issues
  }
}
