// Minimal deterministic assertion harness for the PixelBooth test runner.
// Suite and test bodies execute sequentially; the lock protects the small
// amount of shared reporting state without detached assertion Tasks.

import Foundation

final class HarnessState: @unchecked Sendable {
  static let shared = HarnessState()

  private let lock = NSLock()
  private var passedCount = 0
  private var failedCount = 0
  private var skippedCount = 0
  private var currentSuite = "unknown"
  private var currentTest = "unknown"
  private var failureMessages: [String] = []

  var passed: Int { withLock { passedCount } }
  var failed: Int { withLock { failedCount } }
  var skipped: Int { withLock { skippedCount } }
  var failures: [String] { withLock { failureMessages } }

  func setSuite(_ name: String) { withLock { currentSuite = name } }
  func setTest(_ name: String) { withLock { currentTest = name } }

  func record(_ message: String, file: String, line: Int) {
    withLock {
      failedCount += 1
      let entry = "FAIL \(currentSuite).\(currentTest): \(message) (\(file):\(line))"
      failureMessages.append(entry)
      print(entry)
    }
  }

  func complete(name: String, failedBefore: Int) -> Bool {
    withLock {
      guard failedCount == failedBefore else { return false }
      passedCount += 1
      print("PASS \(currentSuite).\(name)")
      return true
    }
  }

  func skip(name: String, reason: String) {
    withLock {
      skippedCount += 1
      print("NOT RUN \(currentSuite).\(name): \(reason)")
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

func suite(_ name: String) {
  HarnessState.shared.setSuite(name)
}

func test(_ name: String, _ body: () throws -> Void) async {
  await runTest(name, body)
}

func test(_ name: String, _ body: () async throws -> Void) async {
  await runTest(name, body)
}

struct TestSkipped: Error {
  var reason: String
}

func skipTest(_ reason: String) throws -> Never {
  throw TestSkipped(reason: reason)
}

private func runTest(_ name: String, _ body: () throws -> Void) async {
  HarnessState.shared.setTest(name)
  let before = HarnessState.shared.failed
  do {
    try body()
  } catch let skipped as TestSkipped {
    HarnessState.shared.skip(name: name, reason: skipped.reason)
    return
  } catch {
    recordFailure("threw: \(error)")
  }
  _ = HarnessState.shared.complete(name: name, failedBefore: before)
}

private func runTest(_ name: String, _ body: () async throws -> Void) async {
  HarnessState.shared.setTest(name)
  let before = HarnessState.shared.failed
  do {
    try await body()
  } catch let skipped as TestSkipped {
    HarnessState.shared.skip(name: name, reason: skipped.reason)
    return
  } catch {
    recordFailure("threw: \(error)")
  }
  _ = HarnessState.shared.complete(name: name, failedBefore: before)
}

func recordFailure(_ message: String, file: String = #fileID, line: Int = #line) {
  HarnessState.shared.record(message, file: file, line: line)
}

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
  if !condition {
    HarnessState.shared.record("check failed: \(message)", file: file, line: line)
  }
}

func expectThrows<T>(
  _ body: () throws -> T, _ message: String, file: String = #fileID, line: Int = #line
) {
  do {
    _ = try body()
    recordFailure("expected throw: \(message)", file: file, line: line)
  } catch {
    // expected
  }
}

func reportSummary() -> Int {
  let state = HarnessState.shared
  print("---")
  print("PASSED: \(state.passed)")
  print("FAILED: \(state.failed)")
  print("NOT RUN: \(state.skipped)")
  for failure in state.failures { print(failure) }
  return state.failed == 0 ? 0 : 1
}
