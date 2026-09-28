// PixelBoothApp entry point. The SwiftUI UI is minimal: camera preview,
// camera/mode dropdowns, shutter, and readiness status. A capture saves
// directly to the System Photo Library.

import AVFoundation
import AppKit
import PixelBoothCapture
import PixelBoothCore
import PixelBoothLibrary
import SwiftUI

extension Notification.Name {
  static let pixelBoothLocationPreferencesChanged =
    Notification.Name("PixelBoothLocationPreferencesChanged")
  static let pixelBoothReadinessPreferencesChanged =
    Notification.Name("PixelBoothReadinessPreferencesChanged")
  static let pixelBoothFrameRatePreferencesChanged =
    Notification.Name("PixelBoothFrameRatePreferencesChanged")
}

@main
struct PixelBoothApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  init() {
    // Surface layout/usage exceptions with their reason before the crash
    // handler replaces them; aids diagnosing launch-time layout crashes.
    NSSetUncaughtExceptionHandler { exception in
      let reason = exception.reason ?? "unknown"
      let stack = exception.callStackSymbols.prefix(20).joined(separator: "\n")
      FileHandle.standardError.write(
        Data(
          """
          NSException: \(exception.name.rawValue): \(reason)
          \(stack)

          """.utf8))
    }
  }

  var body: some Scene {
    Window("PixelBooth", id: "pixelbooth-capture") {
      CaptureWindowView()
        .frame(minWidth: 700, minHeight: 560)
    }
    .defaultSize(width: 1100, height: 800)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var terminationTask: Task<Void, Never>?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }

    terminationTask = Task { @MainActor [weak self] in
      let queue = SaveQueueHolder.shared.queue
      let hasActiveWork = await queue.beginTermination()
      if hasActiveWork {
        let alert = NSAlert()
        alert.messageText = "Finishing captures before quitting"
        alert.informativeText =
          "PixelBooth will finish active encoding and saving before it quits. This may take a while."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        _ = alert.runModal()
        await queue.waitForTerminationWorkToFinish()
      }
      sender.reply(toApplicationShouldTerminate: true)
      self?.terminationTask = nil
    }
    return .terminateLater
  }
}

struct CaptureWindowView: View {
  @StateObject private var viewModel = CaptureViewModel()
  @ObservedObject private var saveQueue = SaveQueueHolder.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("mirrorPreview") private var mirrorPreview = false
  @AppStorage("countdownSeconds") private var countdownSeconds = 0.0
  @State private var isProgressExpanded = false
  @State private var isInspectorExpanded = false
  @State private var actualSizePreview = false

  var body: some View {
    VStack(spacing: 12) {
      cameraModeToolbar

      ZStack(alignment: .topLeading) {
        previewSurface
        if mirrorPreview {
          Label("Mirrored preview", systemImage: "arrow.left.and.right")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
            .accessibilityLabel("Preview is mirrored; saved image is unchanged")
        }
        if let remaining = viewModel.countdownRemaining {
          countdownOverlay(remaining)
        } else if viewModel.cameraWindowStatus != .ready {
          cameraStateCard
        }
      }
      .frame(minHeight: 250, maxHeight: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(.quaternary, lineWidth: 1)
      }

      captureBar
      if !saveQueue.photosAuthorizationState.canAddPhotos {
        PhotosAuthorizationBanner(
          state: saveQueue.photosAuthorizationState,
          requestAccess: saveQueue.requestPhotosAuthorization,
          openSettings: openPhotosSettings)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(viewModel.captureStateText)
          .font(.callout.weight(.medium))
          .accessibilityLabel("Capture readiness")
          .accessibilityValue(viewModel.captureStateText)
          .accessibilityAddTraits(.updatesFrequently)

        if viewModel.canOverrideAdjustment {
          HStack {
            Text("The camera is still adjusting. You can wait or continue now.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Capture while adjusting") { viewModel.allowCaptureWhileAdjusting() }
              .buttonStyle(.bordered)
          }
        }

        if let result = viewModel.lastResultText {
          Text(result)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityLabel("Latest capture result: \(result)")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let recoveryError = saveQueue.recoveryError {
        RecoveryErrorBanner(message: recoveryError) { saveQueue.retryRecovery() }
      }
      if let capacityError = saveQueue.capacityError {
        QueueCapacityBanner(message: capacityError) { saveQueue.dismissCapacityError() }
      }

      if !saveQueue.progressItems.isEmpty {
        CaptureProgressSection(
          items: saveQueue.progressItems,
          isExpanded: $isProgressExpanded,
          onRetry: retryCapture,
          onSaveOriginal: saveOriginal,
          onDismiss: dismissCapture
        )
        .transition(
          reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
      }
      if !saveQueue.retainedItems.isEmpty {
        RetainedCapturesSection(
          items: saveQueue.retainedItems,
          onSaveOriginal: saveOriginal,
          onDismiss: saveQueue.dismissRetainedCapture)
      }
      if !saveQueue.dismissedRetainedItems.isEmpty {
        DismissedCapturesSection(
          items: saveQueue.dismissedRetainedItems,
          onSaveOriginal: saveOriginal,
          onRestore: saveQueue.restoreRetainedCapture)
      }
      if isInspectorExpanded {
        CaptureInspectorView(viewModel: viewModel)
      }
    }
    .padding(16)
    .frame(minWidth: 700, minHeight: 560)
    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: saveQueue.progressItems)
    .onAppear {
      viewModel.activate()
      Task { await saveQueue.refreshPhotosAuthorizationStatus() }
      if !attentionCaptureIDs.isEmpty { isProgressExpanded = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await saveQueue.refreshPhotosAuthorizationStatus() }
    }
    .onChange(of: attentionCaptureIDs) { oldValue, newValue in
      if newValue.isEmpty {
        if !oldValue.isEmpty { isProgressExpanded = false }
      } else {
        isProgressExpanded = true
      }
    }
    .onDisappear { viewModel.deactivate() }
    .background {
      SpaceShutterMonitor { viewModel.requestCapture() }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }

  private var attentionCaptureIDs: [UUID] {
    saveQueue.progressItems.filter(\.needsAttention).map(\.uuid)
  }

  private func openPhotosSettings() {
    let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    NSWorkspace.shared.open(settingsApp)
  }

  private var cameraModeToolbar: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Camera").font(.caption).foregroundStyle(.secondary)
        Picker("Camera", selection: $viewModel.selectedCameraID) {
          ForEach(viewModel.cameras) { camera in
            Text(camera.localizedName).tag(Optional(camera.uniqueID))
          }
        }
        .disabled(viewModel.cameras.isEmpty || viewModel.cameraAccessDenied)
        .accessibilityLabel("Camera")
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        Text("Mode").font(.caption).foregroundStyle(.secondary)
        Picker("Mode", selection: $viewModel.selectedModeID) {
          ForEach(viewModel.availableModes) { mode in
            Text(
              "\(mode.dimensionsWidth)×\(mode.dimensionsHeight) · \(Int(mode.maxFrameRate)) fps · \(CaptureFormat.fourCCString(mode.pixelFormat))"
            )
            .tag(Optional(mode.id))
          }
        }
        .disabled(viewModel.availableModes.isEmpty || viewModel.cameraAccessDenied)
        .accessibilityLabel("Camera mode")
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        isInspectorExpanded.toggle()
      } label: {
        Label("Details", systemImage: isInspectorExpanded ? "info.circle.fill" : "info.circle")
      }
      .buttonStyle(.borderless)
      .accessibilityValue(isInspectorExpanded ? "Shown" : "Hidden")
      Menu {
        Button("Fit to Window") { actualSizePreview = false }
        Button("Actual Size") { actualSizePreview = true }
      } label: {
        Label(actualSizePreview ? "Actual Size" : "Fit", systemImage: "viewfinder")
      }
      .accessibilityLabel("Preview scale")
      .accessibilityValue(actualSizePreview ? "Actual Size" : "Fit to Window")
    }
  }

  @ViewBuilder
  private var previewSurface: some View {
    if actualSizePreview {
      let format =
        viewModel.currentEvidence?.deliveredFormat
        ?? viewModel.selectedMode?.asCaptureFormat
      ScrollView([.horizontal, .vertical]) {
        CameraPreviewViewRepresentable(viewModel: viewModel, actualSize: true)
          .frame(
            width: CGFloat(format?.width ?? 640),
            height: CGFloat(format?.height ?? 480))
      }
      .accessibilityLabel("Actual size camera preview; scroll to inspect the full frame")
    } else {
      CameraPreviewViewRepresentable(viewModel: viewModel, actualSize: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Live camera preview, fit to window")
    }
  }

  private var captureBar: some View {
    HStack(spacing: 16) {
      Picker("Timer", selection: $countdownSeconds) {
        Text("Timer Off").tag(0.0)
        Text("3 seconds").tag(3.0)
        Text("10 seconds").tag(10.0)
      }
      .pickerStyle(.segmented)
      .frame(width: 210)
      .accessibilityLabel("Self timer")

      Spacer(minLength: 8)
      ShutterButton(state: viewModel.shutterEnabled ? .enabled : .disabled) {
        viewModel.requestCapture()
      }
      Spacer(minLength: 8)

      Toggle(isOn: $mirrorPreview) {
        Label("Mirror", systemImage: "arrow.left.and.right")
      }
      .toggleStyle(.switch)
      .accessibilityLabel("Mirror preview only")
      .accessibilityHint("Does not change the saved image")
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var cameraStateCard: some View {
    switch viewModel.cameraWindowStatus {
    case .permissionDenied:
      CameraStateCard(
        symbol: "camera.fill", title: "Camera access is off",
        detail: "Allow PixelBooth to use the camera in System Settings, then check again.",
        actionTitle: "Open Camera Settings", action: openCameraSettings,
        secondaryActionTitle: "Check Again", secondaryAction: viewModel.refreshCameras)
    case .noCamera:
      CameraStateCard(
        symbol: "camera", title: "No camera found",
        detail: "Connect a camera or check its connection, then look again.",
        actionTitle: "Refresh Cameras", action: viewModel.refreshCameras)
    case .noSupportedMode:
      CameraStateCard(
        symbol: "video.slash", title: "No supported mode is available",
        detail: "Choose another camera or refresh the camera list.",
        actionTitle: "Refresh Cameras", action: viewModel.refreshCameras)
    case .connecting:
      CameraStateCard(
        symbol: "camera.aperture", title: "Starting camera",
        detail: viewModel.readinessText, actionTitle: nil, action: {})
    case .ready:
      EmptyView()
    case .disconnected:
      CameraStateCard(
        symbol: "video.slash.fill", title: "Camera disconnected",
        detail:
          "Reconnect it or select another camera. PixelBooth will not switch cameras on its own.",
        actionTitle: "Refresh Cameras", action: viewModel.refreshCameras)
    case .failed(let message):
      CameraStateCard(
        symbol: "exclamationmark.triangle.fill", title: "Capture stopped",
        detail: message, actionTitle: "Refresh Cameras", action: viewModel.refreshCameras)
    }
  }

  private func countdownOverlay(_ remaining: Int) -> some View {
    VStack(spacing: 10) {
      Text("\(remaining)")
        .font(.system(size: 112, weight: .semibold, design: .rounded).monospacedDigit())
        .contentTransition(reduceMotion ? .identity : .numericText())
        .accessibilityLabel("Taking photo in \(remaining) seconds")
      Button("Cancel timer") { viewModel.cancelCountdown() }
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Cancel capture countdown")
    }
    .padding(28)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }

  private func openCameraSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    {
      NSWorkspace.shared.open(url)
    }
  }

  private func retryCapture(_ item: CaptureProgressItem, confirmingPossibleDuplicate: Bool) {
    var confirmedPossibleDuplicate = confirmingPossibleDuplicate
    if item.needsDuplicateConfirmation && !confirmedPossibleDuplicate {
      let alert = NSAlert()
      alert.messageText = "Photos may already contain this capture"
      alert.informativeText =
        "The previous Photos request may have completed. Retrying could add a duplicate; confirm only if you want to proceed."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Retry Anyway")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      confirmedPossibleDuplicate = true
    }

    Task {
      do {
        try await saveQueue.queue.retry(
          uuid: item.uuid, confirmingPossibleDuplicate: confirmedPossibleDuplicate)
      } catch {
        viewModel.lastResultText = "Retry failed: \(error.localizedDescription)"
      }
    }
  }

  private func saveOriginal(_ item: CaptureProgressItem) {
    Task(priority: .userInitiated) {
      do {
        let fileName = try await saveQueue.queue.suggestedOriginalFileName(uuid: item.uuid)
        let panel = NSSavePanel()
        panel.title = "Save Original"
        panel.prompt = "Save Original"
        panel.nameFieldStringValue = fileName
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        _ = try await saveQueue.queue.saveOriginal(uuid: item.uuid, to: destination)
        viewModel.lastResultText = "Original saved to \(destination.lastPathComponent)"
      } catch {
        viewModel.lastResultText = "Could not save original: \(error.localizedDescription)"
      }
    }
  }

  private func dismissCapture(_ item: CaptureProgressItem) {
    Task(priority: .userInitiated) {
      do {
        try await saveQueue.queue.dismissUnsupportedCaptureFromProgress(uuid: item.uuid)
      } catch {
        viewModel.lastResultText = "Could not dismiss capture: \(error.localizedDescription)"
      }
    }
  }
}

private struct CaptureProgressSection: View {
  let items: [CaptureProgressItem]
  @Binding var isExpanded: Bool
  let onRetry: (CaptureProgressItem, Bool) -> Void
  let onSaveOriginal: (CaptureProgressItem) -> Void
  let onDismiss: (CaptureProgressItem) -> Void

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(items) { item in
            CaptureProgressRow(
              item: item,
              onRetry: { onRetry(item, $0) },
              onSaveOriginal: { onSaveOriginal(item) },
              onDismiss: { onDismiss(item) }
            )
            .padding(.vertical, 5)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            if item.id != items.last?.id {
              Divider()
            }
          }
        }
      }
      .frame(maxHeight: 150)
      .padding(.top, 8)
    } label: {
      HStack(spacing: 8) {
        summaryIndicator
          .frame(width: 18, height: 18)
          .accessibilityHidden(true)
        Text(summaryText)
          .font(.callout.weight(.medium))
        Spacer()
        Text("\(items.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("\(items.count) captures")
      }
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(.quaternary, lineWidth: 1)
    }
    .accessibilityLabel("Capture progress: \(summaryText)")
  }

  private var needsAttentionCount: Int {
    items.filter(\.needsAttention).count
  }

  private var activeCount: Int {
    items.filter { !$0.needsAttention && !$0.isComplete }.count
  }

  private var summaryText: String {
    if needsAttentionCount > 0 {
      return needsAttentionCount == 1
        ? "1 capture needs attention" : "\(needsAttentionCount) captures need attention"
    }
    if activeCount > 0 {
      return activeCount == 1
        ? "1 capture in progress" : "\(activeCount) captures in progress"
    }
    return items.count == 1 ? "Capture saved" : "\(items.count) captures saved"
  }

  @ViewBuilder
  private var summaryIndicator: some View {
    if needsAttentionCount > 0 {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    } else if activeCount > 0 {
      ProgressView()
        .controlSize(.small)
    } else {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    }
  }
}

private struct CameraStateCard: View {
  let symbol: String
  let title: String
  let detail: String
  let actionTitle: String?
  let action: () -> Void
  var secondaryActionTitle: String? = nil
  var secondaryAction: () -> Void = {}

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title).font(.title3.weight(.semibold))
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
      if let actionTitle {
        Button(actionTitle, action: action)
          .buttonStyle(.borderedProminent)
      }
      if let secondaryActionTitle {
        Button(secondaryActionTitle, action: secondaryAction)
          .buttonStyle(.bordered)
      }
    }
    .padding(24)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

private struct RecoveryErrorBanner: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Capture recovery needs attention")
          .font(.callout.weight(.semibold))
        Text(message)
          .font(.caption)
          .textSelection(.enabled)
      }
      Spacer(minLength: 8)
      Button("Retry Recovery", action: retry)
        .buttonStyle(.bordered)
        .accessibilityLabel("Retry capture recovery")
    }
    .padding(12)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }
}

private struct QueueCapacityBanner: View {
  let message: String
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Capture staging limit reached")
          .font(.callout.weight(.semibold))
        Text(message)
          .font(.caption)
          .textSelection(.enabled)
      }
      Spacer(minLength: 8)
      Button("Dismiss", action: dismiss)
        .buttonStyle(.bordered)
    }
    .padding(12)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }
}

private struct PhotosAuthorizationBanner: View {
  let state: SaveQueueActor.PhotosAuthorizationState
  let requestAccess: () -> Void
  let openSettings: () -> Void

  private var actionTitle: String {
    state == .notDetermined ? "Allow Photos Access" : "Open System Settings"
  }

  private var message: String {
    state.recoveryMessage ?? "Allow PixelBooth to add captures to Photos."
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "photo.badge.exclamationmark")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Photos access needs attention")
          .font(.callout.weight(.semibold))
        Text(message)
          .font(.caption)
          .textSelection(.enabled)
        if state != .notDetermined {
          Text("After changing access, return to PixelBooth and it will check again.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      Button(actionTitle) {
        state == .notDetermined ? requestAccess() : openSettings()
      }
      .buttonStyle(.bordered)
    }
    .padding(12)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
  }
}

private struct RetainedCapturesSection: View {
  let items: [CaptureProgressItem]
  let onSaveOriginal: (CaptureProgressItem) -> Void
  let onDismiss: (CaptureProgressItem) -> Void

  var body: some View {
    DisclosureGroup("Retained captures (\(items.count))") {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(items) { item in
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.callout.weight(.medium))
                Text("\(item.statusText) · retained on this Mac")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                if let error = item.lastError {
                  Text(error).font(.caption).textSelection(.enabled)
                }
              }
              Spacer(minLength: 8)
              Button("Save Original…") { onSaveOriginal(item) }
                .accessibilityLabel("Save retained original for \(item.title)")
              Button("Dismiss") { onDismiss(item) }
                .accessibilityLabel("Dismiss retained capture \(item.title)")
            }
            .padding(.vertical, 5)
            if item.id != items.last?.id { Divider() }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 180)
      .padding(.top, 8)
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct DismissedCapturesSection: View {
  let items: [CaptureProgressItem]
  let onSaveOriginal: (CaptureProgressItem) -> Void
  let onRestore: (CaptureProgressItem) -> Void

  var body: some View {
    DisclosureGroup("Dismissed captures (\(items.count))") {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "These captures remain on this Mac. Restore one to the retained list when you need it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
              HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(item.title).font(.callout.weight(.medium))
                  Text("\(item.statusText) · hidden from retained captures")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Restore") { onRestore(item) }
                Button("Save Original…") { onSaveOriginal(item) }
              }
              .padding(.vertical, 5)
              if item.id != items.last?.id { Divider() }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
      }
      .padding(.top, 8)
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
  }
}

private struct CaptureInspectorView: View {
  let viewModel: CaptureViewModel
  @State private var requestedRate = 0.0
  @State private var measuredRate = 0.0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Capture details").font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
        inspectorRow("Backend", viewModel.activeBackend?.rawValue ?? "Not running")
        inspectorRow(
          "Camera",
          viewModel.cameras.first { $0.uniqueID == viewModel.selectedCameraID }?.localizedName
            ?? "Unknown")
        inspectorRow(
          "Selected format", viewModel.selectedMode?.asCaptureFormat.descriptiveLabel ?? "Unknown")
        inspectorRow(
          "Delivered format",
          viewModel.currentEvidence?.deliveredFormat.descriptiveLabel ?? "No valid frame yet")
        inspectorRow(
          "Delivered range",
          viewModel.currentEvidence?.deliveredFormat.yuvRange?.rawValue.capitalized ?? "Unknown")
        inspectorRow(
          "Chroma location",
          viewModel.currentEvidence?.deliveredFormat.chromaLocation?.rawValue.capitalized
            ?? "Unknown / not applicable")
        inspectorRow(
          "Acquisition evidence",
          viewModel.currentEvidence.map { CaptureViewModel.fidelityLabel($0.fidelity) } ?? "Unknown"
        )
        inspectorRow(
          "Known conversions",
          viewModel.currentEvidence.map {
            $0.knownConversions.isEmpty
              ? "None reported" : $0.knownConversions.joined(separator: ", ")
          } ?? "Unknown")
        inspectorRow("Requested rate", rateDescription(requestedRate))
        inspectorRow(
          "Configured rate", viewModel.configuredFrameRate.map(rateDescription) ?? "Unknown")
        inspectorRow("Measured delivery rate", rateDescription(measuredRate))
        inspectorRow(
          "Generation", viewModel.currentEvidence.map { String($0.generation) } ?? "Unknown")
        inspectorRow("Archive output", "JPEG passthrough or lossless AVIF")
      }
      Text(viewModel.acquisitionStatus)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .task {
      while !Task.isCancelled {
        let rates = await viewModel.ingest.frameRates()
        requestedRate = rates.requested
        measuredRate = rates.measured
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
      }
    }
  }

  private func inspectorRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }

  private func rateDescription(_ value: Double) -> String {
    value.isFinite && value > 0 ? String(format: "%.2f fps", value) : "Unknown"
  }
}

private struct CaptureProgressRow: View {
  let item: CaptureProgressItem
  let onRetry: (Bool) -> Void
  let onSaveOriginal: () -> Void
  let onDismiss: () -> Void
  @State private var detailsExpanded = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      statusIndicator
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(item.title)
            .font(.callout.weight(.medium))
          Text(item.statusText)
            .font(.callout)
            .foregroundStyle(item.needsAttention ? Color.orange : Color.secondary)
        }

        if item.needsAttention {
          if let error = item.lastError {
            DisclosureGroup("Full error details", isExpanded: $detailsExpanded) {
              Text(error)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.caption)
          } else {
            Text("This capture is safely stored on this Mac.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          HStack(spacing: 8) {
            if item.isPermanentlyUnencodable {
              Button("Dismiss", action: onDismiss)
                .accessibilityLabel("Dismiss \(item.title) from capture progress")
            } else {
              Button("Retry") { onRetry(false) }
                .accessibilityLabel("Retry \(item.title)")
              Button("Save Original…", action: onSaveOriginal)
                .accessibilityLabel("Save original for \(item.title)")
            }
          }
          .controlSize(.small)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var statusIndicator: some View {
    if item.isComplete {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    } else if item.needsAttention {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    } else {
      ProgressView()
        .controlSize(.small)
    }
  }
}

private struct SpaceShutterMonitor: NSViewRepresentable {
  let onPress: () -> Void

  func makeNSView(context: Context) -> SpaceMonitorNSView {
    let view = SpaceMonitorNSView()
    view.onPress = onPress
    return view
  }

  func updateNSView(_ view: SpaceMonitorNSView, context: Context) {
    view.onPress = onPress
  }

  static func dismantleNSView(_ view: SpaceMonitorNSView, coordinator: ()) {
    view.stopMonitoring()
  }
}

private final class SpaceMonitorNSView: NSView {
  var onPress: () -> Void = {}
  private var eventMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      removeEventMonitor()
      return
    }
    guard eventMonitor == nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.window === self.window, event.keyCode == 49,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
      else { return event }
      if let responder = self.window?.firstResponder,
        responder is NSControl || responder is NSTextView
      {
        return event
      }
      self.onPress()
      return nil
    }
  }

  fileprivate func stopMonitoring() { removeEventMonitor() }

  private func removeEventMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }
}

struct ShutterButton: View {
  enum ShutterState { case enabled, disabled }
  var state: ShutterState
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Take Photo", systemImage: "camera.fill")
        .font(.headline)
        .frame(minWidth: 156, minHeight: 48)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .disabled(state == .disabled)
    // Accessibility label carries the keyboard hint; no .help() tooltip.
    // Verified crash on macOS 27.0: SwiftUI's TooltipBridge
    // (NSViewDynamicToolTipManager movement-tracking timer) crashes in
    // MainActor.assumeIsolated while walking responders for a dynamic
    // tooltip rect — see docs/TN3121_VERIFICATION.md.
    .accessibilityLabel("Take photo")
    .accessibilityHint(
      "Press Space to take a photo when a text or camera control does not have focus.")
  }
}

struct SettingsView: View {
  @AppStorage("includeLocation") private var includeLocation = true
  @AppStorage("locationMaximumAge") private var locationMaximumAge = 60.0
  @AppStorage("countdownSeconds") private var countdownSeconds = 0.0
  @AppStorage("mirrorPreview") private var mirrorPreview = false
  @AppStorage("minimumFreshFrames") private var minimumFreshFrames = 8
  @AppStorage("minimumMillisecondsSinceValidStart") private var minimumMillisecondsSinceValidStart =
    500
  @AppStorage("maximumAdjustingWaitMilliseconds") private var maximumAdjustingWaitMilliseconds =
    5000
  @AppStorage("frameRateOverride") private var frameRateOverride = 0.0

  var body: some View {
    Form {
      Section("General") {
        Text("Captures are added to the System Photo Library.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Toggle("Include Location", isOn: $includeLocation)
        Stepper(value: $locationMaximumAge, in: 10...600, step: 10) {
          Text("Maximum location age: \(Int(locationMaximumAge)) s")
        }
        Text(
          "Host location is the Mac's location, not necessarily a remote camera's location. Disabling this does not scrub location metadata already supplied by the camera."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        Text(
          "When enabled, PixelBooth asks for while-in-use Location Services access. A photo is saved without a host geotag if access is denied or no sufficiently recent location is available; the shutter never waits for a location fix."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      Section("Capture") {
        Picker("Self-timer", selection: $countdownSeconds) {
          Text("Off").tag(0.0)
          Text("3 seconds").tag(3.0)
          Text("10 seconds").tag(10.0)
        }
        .pickerStyle(.segmented)
        Picker("Maximum frame rate", selection: $frameRateOverride) {
          Text("Mode maximum").tag(0.0)
          Text("Up to 15 fps").tag(15.0)
          Text("Up to 30 fps").tag(30.0)
          Text("Up to 60 fps").tag(60.0)
        }
        Text(
          "PixelBooth chooses the highest rate supported by this mode under the selected limit. Resolution and image precision stay unchanged."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      Section("Preview") {
        Toggle("Mirror Preview", isOn: $mirrorPreview)
      }
      Section("Advanced Readiness") {
        Stepper(
          "Minimum fresh frames: \(minimumFreshFrames)", value: $minimumFreshFrames, in: 1...60)
        Stepper(
          "Minimum ms since valid start: \(minimumMillisecondsSinceValidStart)",
          value: $minimumMillisecondsSinceValidStart, in: 100...5000, step: 100)
        Stepper(
          "Maximum adjusting wait: \(maximumAdjustingWaitMilliseconds) ms",
          value: $maximumAdjustingWaitMilliseconds, in: 1000...20000, step: 500)
      }
    }
    .padding()
    .frame(
      minWidth: 420, idealWidth: 520, maxWidth: 680,
      minHeight: 440, idealHeight: 560, maxHeight: 780
    )
    .onChange(of: includeLocation) { _, _ in
      NotificationCenter.default.post(name: .pixelBoothLocationPreferencesChanged, object: nil)
    }
    .onChange(of: locationMaximumAge) { _, _ in
      NotificationCenter.default.post(name: .pixelBoothLocationPreferencesChanged, object: nil)
    }
    .onChange(of: minimumFreshFrames) { _, _ in
      NotificationCenter.default.post(name: .pixelBoothReadinessPreferencesChanged, object: nil)
    }
    .onChange(of: minimumMillisecondsSinceValidStart) { _, _ in
      NotificationCenter.default.post(name: .pixelBoothReadinessPreferencesChanged, object: nil)
    }
    .onChange(of: maximumAdjustingWaitMilliseconds) { _, _ in
      NotificationCenter.default.post(name: .pixelBoothReadinessPreferencesChanged, object: nil)
    }
    .onChange(of: frameRateOverride) { _, _ in
      NotificationCenter.default.post(name: .pixelBoothFrameRatePreferencesChanged, object: nil)
    }
  }
}
