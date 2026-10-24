import Foundation

public struct CaptureCommandError: Error, LocalizedError, Equatable, Sendable {
  public let message: String
  public var errorDescription: String? { message }

  public init(_ message: String) { self.message = message }
}

public struct CaptureCommandOptions: Equatable, Sendable {
  public enum Action: Equatable, Sendable {
    case capture
    case help
    case version
  }

  public enum Output: Equatable, Sendable {
    case pictures
    case directory(String)
    case file(String)
    case standardOutput
  }

  public static let maximumTimeoutSeconds = Int(Int64.max / 1_000_000_000)
  public private(set) var action: Action = .capture
  public private(set) var output: Output = .pictures
  public private(set) var timeoutSeconds = 10
  public private(set) var includeEstimatedDisparity = false
  public private(set) var recoveryDirectory: String?

  public init(arguments: [String]) throws {
    var index = 0
    var hasOutput = false
    var hasTimeout = false
    while index < arguments.count {
      let argument = arguments[index]
      let pieces = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let option = String(pieces[0])
      let inlineValue = pieces.count == 2 ? String(pieces[1]) : nil
      switch option {
      case "--help", "-h":
        guard inlineValue == nil else { throw CaptureCommandError("\(option) takes no value") }
        action = .help
      case "--version":
        guard inlineValue == nil else { throw CaptureCommandError("\(option) takes no value") }
        if action != .help { action = .version }
      case "--estimated-disparity":
        guard inlineValue == nil else { throw CaptureCommandError("\(option) takes no value") }
        includeEstimatedDisparity = true
      case "--timeout":
        guard !hasTimeout else {
          throw CaptureCommandError("--timeout was supplied more than once")
        }
        let value = try Self.value(inlineValue, option: option, arguments: arguments, index: &index)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
          let seconds = Int(value), (1...Self.maximumTimeoutSeconds).contains(seconds)
        else {
          throw CaptureCommandError(
            "--timeout requires integer seconds from 1 through \(Self.maximumTimeoutSeconds)")
        }
        timeoutSeconds = seconds
        hasTimeout = true
      case "--recover":
        guard recoveryDirectory == nil else {
          throw CaptureCommandError("--recover was supplied more than once")
        }
        let value = try Self.value(inlineValue, option: option, arguments: arguments, index: &index)
        guard !value.isEmpty, !value.contains("\0") else {
          throw CaptureCommandError("--recover requires a recovery directory")
        }
        recoveryDirectory = value
      case "--output", "-o", "--output-dir":
        guard !hasOutput else {
          throw CaptureCommandError("choose one --output or --output-dir destination")
        }
        let value = try Self.value(inlineValue, option: option, arguments: arguments, index: &index)
        guard !value.isEmpty, !value.contains("\0") else {
          throw CaptureCommandError("\(option) requires a nonempty filesystem path")
        }
        if option == "--output-dir" {
          output = .directory(value)
        } else if value == "-" {
          output = .standardOutput
        } else {
          guard !value.hasSuffix("/") else {
            throw CaptureCommandError("use --output-dir for a directory")
          }
          let suffix = URL(fileURLWithPath: value).pathExtension.lowercased()
          guard suffix.isEmpty || ["jpg", "jpeg", "avif"].contains(suffix) else {
            throw CaptureCommandError(
              "output filename must use .jpg, .jpeg, .avif, or no extension")
          }
          output = .file(value)
        }
        hasOutput = true
      default:
        throw CaptureCommandError("unknown argument: \(argument)")
      }
      index += 1
    }
  }

  public func recoveryURL(
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) -> URL? {
    recoveryDirectory.map { Self.resolve($0, workingDirectory: workingDirectory) }
  }

  /// Resolve names only after the preservation pipeline determines the actual codec.
  /// An explicit extensionless filename is used verbatim.
  public func destination(
    fileExtension: String, captureUUID: UUID,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws -> URL? {
    guard ["jpg", "avif"].contains(fileExtension) else {
      throw CaptureCommandError("unsupported finalized image extension: \(fileExtension)")
    }
    let generatedName = "capture-\(captureUUID.uuidString.lowercased()).\(fileExtension)"
    switch output {
    case .standardOutput: return nil
    case .pictures:
      return homeDirectory.appendingPathComponent("Pictures", isDirectory: true)
        .appendingPathComponent(generatedName)
    case .directory(let path):
      return Self.resolve(path, workingDirectory: workingDirectory)
        .appendingPathComponent(generatedName)
    case .file(let path):
      let url = Self.resolve(path, workingDirectory: workingDirectory)
      let suffix = url.pathExtension.lowercased()
      let matches =
        suffix.isEmpty || suffix == fileExtension || (fileExtension == "jpg" && suffix == "jpeg")
      guard matches else {
        throw CaptureCommandError(
          "selected camera mode produces .\(fileExtension); output filename has .\(suffix)")
      }
      return url
    }
  }

  private static func value(
    _ inlineValue: String?, option: String, arguments: [String], index: inout Int
  ) throws -> String {
    if let inlineValue { return inlineValue }
    index += 1
    guard index < arguments.count else { throw CaptureCommandError("\(option) requires a value") }
    return arguments[index]
  }

  private static func resolve(_ path: String, workingDirectory: URL) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
  }

  public static let help = """
    Usage: pixelbooth [--output-dir DIRECTORY | --output FILE] [--timeout SECONDS]
                      [--estimated-disparity]

    Take one photograph and exit. Prefer the highest supported mode across
    external USB cameras; use the built-in camera only when no USB camera exists.
    Preserve camera JPEG coding data, or encode and verify native samples as AVIF.

      --output-dir DIRECTORY  Save with a unique filename (default: ~/Pictures).
      --output FILE, -o FILE  Use this exact filename. Never overwrite a file.
                             An extension, if present, must match the actual codec.
      --output -, -o -       Write the finalized image as one line of base64.
      --timeout SECONDS      Positive integer acquisition timeout (default: 10).
                             Starts after camera authorization; excludes encoding.
      --estimated-disparity  Include estimated disparity for AVIF. Requires resources
                             prepared by scripts/build_cli.sh --with-disparity.
      --recover DIRECTORY    Retry a retained photograph without accessing a camera.
                             Uses the metadata and disparity choice saved at capture.
      --help, -h             Show this help without accessing a camera.
      --version             Print the CLI version.

    File output prints only its absolute path to stdout. Diagnostics and recovery
    paths use stderr. Host location is disabled. Camera-supplied metadata is retained.
    Camera authorization may require an interactive first run. Exit codes: 0 success,
    2 invalid arguments, 3 permission failure, 1 capture/processing/output failure,
    or 128 plus the signal number when interrupted. No Photos access is requested.
    """
}
