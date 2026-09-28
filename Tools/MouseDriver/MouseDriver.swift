// MouseDriver — posts synthetic mouse events over the PixelBooth window
// (tests only) so tooltip tracking and hit-testing run without a human.
// Usage: MouseDriver <seconds>

import CoreGraphics
import Foundation

guard let arg = CommandLine.arguments.dropFirst().first, let seconds = Double(arg) else {
  print("usage: MouseDriver <seconds> [noclick]")
  exit(2)
}
let clicking = CommandLine.arguments.count < 3 || CommandLine.arguments[2] != "noclick"

func windowBounds() -> CGRect? {
  guard
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
      as? [[String: Any]]
  else { return nil }
  for win in list {
    let ownerKey = kCGWindowOwnerName as String
    guard let owner = win[ownerKey] as? String, owner.contains("PixelBooth") else { continue }
    guard let d = win[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let b = CGRect(x: d["X"] ?? 0, y: d["Y"] ?? 0, width: d["Width"] ?? 0, height: d["Height"] ?? 0)
    guard b.width > 100, b.height > 100 else { continue }
    return b
  }
  return nil
}

guard let bounds = windowBounds() else {
  print("PixelBooth window not found on screen")
  exit(2)
}
print("Window bounds: \(bounds)")

func post(_ type: CGEventType, at point: CGPoint) {
  if let e = CGEvent(
    mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
  {
    e.post(tap: .cghidEventTap)
  }
}

let deadline = Date().addingTimeInterval(seconds)
var t: CGFloat = 0
var lastClick = Date().addingTimeInterval(-10)
while Date() < deadline {
  let sweep = sin(Double(t) * 0.15) * bounds.width * 0.3
  let p = CGPoint(x: bounds.midX + sweep, y: bounds.midY + bounds.height * 0.3)
  let move = CGEventType.mouseMoved
  if let e = CGEvent(
    mouseEventSource: nil, mouseType: move, mouseCursorPosition: p, mouseButton: .left)
  {
    e.post(tap: .cghidEventTap)
  }
  // Occasional click to exercise the pressure-latch hit-test path
  // (suppressed in "noclick" mode so system permission prompts are safe).
  if clicking && Date().timeIntervalSince(lastClick) > 4 {
    if let down = CGEvent(
      mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left),
      let up = CGEvent(
        mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
    {
      down.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.05)
      up.post(tap: .cghidEventTap)
    }
    lastClick = Date()
  }
  t += 1
  Thread.sleep(forTimeInterval: 0.05)
}
print("MouseDriver done")
