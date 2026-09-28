// Minimal assertion harness for the PixelBooth test runner.
// SwiftPM under Command Line Tools cannot load the SDK's Testing macro
// plugin, and XCTest requires a full Xcode install; this harness is the
// honest, runnable alternative. Output mimics standard test reporting.

import Foundation

/// Test state confined to the single-threaded runner main.
final class HarnessState: @unchecked Sendable {
  // Documented narrow exception: the runner is single-threaded; all access
  // happens on that one thread, guarded by a lock for safety.
  static let shared = HarnessState()
  let lock = NSLock()
  var passed = 0
  var failed = 0
  var currentSuite = "unknown"
  var currentTest = "unknown"
  var failures: [String] = []
}

func suite(_ name: String) {
  let state = HarnessState.shared
  state.lock.lock()
  state.currentSuite = name
  state.lock.unlock()
}

func recordFailure(_ message: String, file: String = #fileID, line: Int = #line) {
  let state = HarnessState.shared
  state.lock.lock()
  state.failed += 1
  let entry = "FAIL \(state.currentSuite).\(state.currentTest): \(message) (\(file):\(line))"
  state.failures.append(entry)
  state.lock.unlock()
  print(entry)
}

func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
  if !condition {
    recordFailure("check failed: \(message)", file: file, line: line)
  }
}

/// Run one named test; a body signals failures via `check`/`recordFailure`.
func test(_ name: String, _ body: () throws -> Void) {
  let state = HarnessState.shared
  state.lock.lock()
  state.currentTest = name
  let failuresBefore = state.failed
  state.lock.unlock()
  do {
    try body()
  } catch {
    recordFailure("threw: \(error)")
  }
  state.lock.lock()
  let nowFailed = state.failed
  state.lock.unlock()
  if nowFailed == failuresBefore {
    state.lock.lock()
    state.passed += 1
    state.lock.unlock()
    state.lock.lock()
    let currentSuite = state.currentSuite
    state.lock.unlock()
    print("PASS \(currentSuite).\(name)")
  }
}

func expectThrows<T>(_ body: () throws -> T, _ message: String, file: String = #fileID, line: Int = #line) {
  do {
    _ = try body()
    recordFailure("expected throw: \(message)", file: file, line: line)
  } catch {
    // expected
  }
}

func reportSummary() -> Int {
  let state = HarnessState.shared
  state.lock.lock()
  let passed = state.passed, failed = state.failed, failures = state.failures
  state.lock.unlock()
  print("---")
  print("PASSED: \(passed)")
  print("FAILED: \(failed)")
  for f in failures { print(f) }
  return failed == 0 ? 0 : 1
}
