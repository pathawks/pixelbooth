// swift-tools-version:6.0
// PixelBooth — a macOS camera application focused on preserving
// camera-delivered image data and explaining exactly what was saved.
import Foundation
import PackageDescription

let cliInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("Support/CLIInfo.plist").path

let package = Package(
  name: "PixelBooth",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "PixelBooth", targets: ["PixelBoothApp"]),
    // Distinct from PixelBooth on case-insensitive macOS filesystems.
    .executable(name: "PixelBoothCLI", targets: ["PixelBoothCLI"]),
    .library(name: "PixelBoothCore", targets: ["PixelBoothCore"]),
    .library(name: "PixelBoothAdapters", targets: ["PixelBoothAdapters"]),
    .library(name: "PixelBoothJPEG", targets: ["PixelBoothJPEG"]),
    .library(name: "PixelBoothAVIF", targets: ["PixelBoothAVIF"]),
    .library(name: "PixelBoothDepth", targets: ["PixelBoothDepth"]),
    .library(name: "PixelBoothMetadata", targets: ["PixelBoothMetadata"]),
    .library(name: "PixelBoothCapture", targets: ["PixelBoothCapture"]),
    .library(name: "PixelBoothLibrary", targets: ["PixelBoothLibrary"]),
  ],
  targets: [
    // C shim exposing the pinned libavif 1.3.0 API surface to Swift.
    .target(
      name: "PixelBoothCAvifShim",
      path: "Tools/PixelBoothCAvif",
      publicHeadersPath: "include",
      cSettings: [
        .headerSearchPath("include"),
        .unsafeFlags([
          "-I", "vendor/build/avif-install/include",
          "-I", "vendor/build/aom-install/include",
          "-target", "arm64-apple-macos27.0",
        ]),
      ],
      linkerSettings: [
        .unsafeFlags([
          "-L", "vendor/build/avif",
          "-lavif",
          "-L", "vendor/build/aom",
          "-laom",
          "-target", "arm64-apple-macos27.0",
        ]),
      ]
    ),
    // Domain models: capture formats, provenance, mode selection, readiness.
    .target(name: "PixelBoothCore", path: "Sources/PixelBoothCore"),
    // Pure-Swift sample-layout adapters (YUY2/UYVY/NV12/RGB, 10-bit bi-planar).
    .target(name: "PixelBoothAdapters", dependencies: ["PixelBoothCore"], path: "Sources/PixelBoothAdapters"),
    // JPEG preservation (segment parsing + metadata-only re-insertion).
    .target(name: "PixelBoothJPEG", dependencies: ["PixelBoothCore"], path: "Sources/PixelBoothJPEG"),
    // AVIF lossless encoding via pinned libavif+libaom, plus round-trip verification.
    .target(name: "PixelBoothAVIF", dependencies: ["PixelBoothCore", "PixelBoothAdapters", "PixelBoothCAvifShim", "PixelBoothMetadata"], path: "Sources/PixelBoothAVIF"),
    // On-device estimated disparity, isolated from the archival sample path.
    .target(name: "PixelBoothDepth", path: "Sources/PixelBoothDepth"),
    // Metadata collection/serialization: Exif, XMP, ICC, HDR, location, provenance.
    .target(name: "PixelBoothMetadata", dependencies: ["PixelBoothCore"], path: "Sources/PixelBoothMetadata"),
    // AVFoundation capture: discovery, configuration, sample delivery, provenance.
    .target(name: "PixelBoothCapture", dependencies: ["PixelBoothCore", "PixelBoothAdapters"], path: "Sources/PixelBoothCapture"),
    // Destination: staging, journal, Photos-first import, recovery.
    .target(name: "PixelBoothLibrary", dependencies: ["PixelBoothCore", "PixelBoothAVIF", "PixelBoothDepth", "PixelBoothAdapters", "PixelBoothCapture", "PixelBoothMetadata", "PixelBoothJPEG"], path: "Sources/PixelBoothLibrary"),
    // Command-line policy and streaming output, shared with synthetic tests.
    .target(name: "PixelBoothCommand", path: "Sources/PixelBoothCommand"),
    .executableTarget(
      name: "PixelBoothCLI",
      dependencies: ["PixelBoothCore", "PixelBoothCommand", "PixelBoothLibrary"],
      path: "Sources/PixelBoothCLI",
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist,
          "-target", "arm64-apple-macos27.0",
        ])
      ]
    ),
    // SwiftUI application.
    .executableTarget(
      name: "PixelBoothApp",
      dependencies: ["PixelBoothCore", "PixelBoothCapture", "PixelBoothLibrary", "PixelBoothAVIF", "PixelBoothJPEG", "PixelBoothMetadata"],
      path: "Sources/PixelBoothApp"
    ),
    // Headless hardware probe for real-camera verification (tests only).
    .executableTarget(
      name: "HardwareProbe",
      dependencies: ["PixelBoothCore", "PixelBoothAdapters", "PixelBoothAVIF", "PixelBoothJPEG", "PixelBoothCapture", "PixelBoothLibrary"],
      path: "Tools/HardwareProbe"
    ),
    // Synthetic mouse-event driver (tests only): exercises tooltip and
    // hit-testing paths without a human.
    .executableTarget(
      name: "MouseDriver",
      path: "Tools/MouseDriver"
    ),
    // Self-contained test runner (SwiftPM under Command Line Tools cannot
    // load the SDK Testing macro plugin, and XCTest requires full Xcode).
    .executableTarget(
      name: "PixelBoothTestRunner",
      dependencies: ["PixelBoothCore", "PixelBoothAdapters", "PixelBoothJPEG", "PixelBoothAVIF", "PixelBoothDepth", "PixelBoothMetadata", "PixelBoothLibrary", "PixelBoothCapture", "PixelBoothCommand"],
      path: "Tests/PixelBoothTestRunner",
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
