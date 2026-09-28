// PixelBoothApp entry point. The SwiftUI UI is minimal: camera preview,
// camera/mode dropdowns, shutter, readiness status, and pending-save indicator.
// Diagnostics live in the inspector, not the main surface.

import SwiftUI
import AVFoundation
import PixelBoothCore
import PixelBoothCapture
import PixelBoothLibrary

@main
struct PixelBoothApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      CaptureWindowView()
        .frame(minWidth: 640, minHeight: 480)
    }
    .commands {
      PixelBoothCommands()
    }
    Settings {
      SettingsView()
    }
  }
}

struct PixelBoothCommands: Commands {
  @AppStorage("mirrorPreview") private var mirrorPreview = false

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Toggle("Mirror Preview", isOn: $mirrorPreview)
        .keyboardShortcut("m", modifiers: [.command])
        .accessibilityLabel("Mirror preview")
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

struct CaptureWindowView: View {
  @StateObject private var viewModel = CaptureViewModel()
  @AppStorage("mirrorPreview") private var mirrorPreview = false

  var body: some View {
    VStack(spacing: 8) {
      CameraPreviewViewRepresentable(viewModel: viewModel)
        .background(Color.black)
      HStack {
        Picker("Camera", selection: $viewModel.selectedCameraID) {
          ForEach(viewModel.cameras) { cam in
            Text(cam.localizedName).tag(Optional(cam.uniqueID))
          }
        }
        Picker("Mode", selection: $viewModel.selectedModeID) {
          ForEach(viewModel.availableModes, id: \.descriptiveLabel) { mode in
            Text(mode.descriptiveLabel).tag(Optional(mode.descriptiveLabel))
          }
        }
        Spacer()
        Text(viewModel.readinessText)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Capture readiness")
        ShutterButton(state: viewModel.shutterEnabled ? .enabled : .disabled) {
          viewModel.requestCapture()
        }
        .keyboardShortcut(.space, modifiers: [])
      }
      HStack {
        Text(viewModel.pendingSaveText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Pending saves")
        Spacer()
        if let last = viewModel.lastResultText {
          Text(last).font(.caption)
        }
      }
    }
    .padding()
    .onAppear { viewModel.activate() }
    .onDisappear { viewModel.deactivate() }
  }
}

struct ShutterButton: View {
  enum ShutterState { case enabled, disabled }
  var state: ShutterState
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "camera.circle.fill")
        .font(.system(size: 36))
        .symbolRenderingMode(.hierarchical)
    }
    .disabled(state == .disabled)
    .accessibilityLabel("Take photo")
    .help("Take photo (Space)")
  }
}

struct SettingsView: View {
  @AppStorage("includeLocation") private var includeLocation = true
  @AppStorage("locationMaximumAge") private var locationMaximumAge = 60.0
  @AppStorage("countdownSeconds") private var countdownSeconds = 0.0
  @AppStorage("mirrorPreview") private var mirrorPreview = false
  @AppStorage("minimumFreshFrames") private var minimumFreshFrames = 8
  @AppStorage("minimumMillisecondsSinceValidStart") private var minimumMillisecondsSinceValidStart = 500
  @AppStorage("maximumAdjustingWaitMilliseconds") private var maximumAdjustingWaitMilliseconds = 5000

  var body: some View {
    Form {
      Section("Destination") {
        Text("Completed originals are added to the System Photo Library by default. Use File > Save Original… to choose a folder instead.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Section("Location") {
        Toggle("Include Location", isOn: $includeLocation)
        Stepper(value: $locationMaximumAge, in: 10...600, step: 10) {
          Text("Maximum location age: \(Int(locationMaximumAge)) s")
        }
        Text("Host location is the Mac's location, not necessarily a remote camera's location. Disabling this does not scrub location metadata already supplied by the camera.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Section("Countdown") {
        Picker("Self-timer", selection: $countdownSeconds) {
          Text("Off").tag(0.0)
          Text("3 seconds").tag(3.0)
          Text("10 seconds").tag(10.0)
        }
        .pickerStyle(.segmented)
      }
      Section("Preview") {
        Toggle("Mirror Preview", isOn: $mirrorPreview)
      }
      Section("Readiness Heuristic (advanced)") {
        Stepper("Minimum fresh frames: \(minimumFreshFrames)", value: $minimumFreshFrames, in: 1...60)
        Stepper("Minimum ms since valid start: \(minimumMillisecondsSinceValidStart)", value: $minimumMillisecondsSinceValidStart, in: 100...5000, step: 100)
        Stepper("Maximum adjusting wait: \(maximumAdjustingWaitMilliseconds) ms", value: $maximumAdjustingWaitMilliseconds, in: 1000...20000, step: 500)
      }
    }
    .padding()
    .frame(width: 460, height: 520)
  }
}
