import Darwin
import Foundation

public enum CommandOutput {
  /// A downstream pipe may stop reading indefinitely. Nonblocking writes and
  /// bounded poll waits keep interruption observable without dropping bytes.
  /// The caller ignores SIGPIPE so a closed pipe is reported as an error.
  public static func write(_ data: Data, to output: FileHandle) throws {
    let descriptor = output.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { _ = fcntl(descriptor, F_SETFL, flags) }
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        try Task.checkCancellation()
        let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
        if written > 0 {
          offset += written
        } else if written == -1, errno == EINTR {
          continue
        } else if written == -1, errno == EAGAIN || errno == EWOULDBLOCK {
          var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
          let result = poll(&pending, 1, 50)
          if result < 0, errno != EINTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
        } else {
          throw POSIXError(POSIXErrorCode(rawValue: written == 0 ? EIO : errno) ?? .EIO)
        }
      }
    }
  }
}
