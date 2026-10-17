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

private enum CaptureStatusScene {
  static let id = "pixelbooth-status"
}

private enum CaptureDetailsScene {
  static let id = "pixelbooth-details"
}

@MainActor
private final class CaptureStatusWindowState: ObservableObject {
  static let shared = CaptureStatusWindowState()
  @Published private(set) var isOpen = false

  func windowDidOpen() { isOpen = true }
  func windowDidClose() { isOpen = false }
}

@MainActor
private final class CaptureDetailsWindowState: ObservableObject {
  static let shared = CaptureDetailsWindowState()
  @Published private(set) var isOpen = false

  func windowDidOpen() { isOpen = true }
  func windowDidClose() { isOpen = false }
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
    Window("Capture Status", id: CaptureStatusScene.id) {
      CaptureStatusWindowView()
    }
    .defaultSize(width: 760, height: 620)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    Window("Capture Details", id: CaptureDetailsScene.id) {
      CaptureDetailsWindowView()
    }
    .defaultSize(width: 760, height: 500)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    Settings {
      SettingsView()
    }
  }
}

struct PixelBoothCommands: Commands {
  @AppStorage("mirrorPreview") private var mirrorPreview = false
  @AppStorage("countdownSeconds") private var countdownSeconds = 0.0
  @AppStorage("actualSizePreview") private var actualSizePreview = false
  @AppStorage("showControls") private var showControls = true
  @ObservedObject private var saveQueue = SaveQueueHolder.shared
  @ObservedObject private var captureMenuState = CaptureCommandMenuState.shared
  @ObservedObject private var statusWindowState = CaptureStatusWindowState.shared
  @ObservedObject private var detailsWindowState = CaptureDetailsWindowState.shared
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Take Photo") {
        CaptureViewModel.shared.requestCapture()
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!captureMenuState.shutterEnabled)
    }

    CommandMenu("Capture") {
      Picker("Self-Timer", selection: $countdownSeconds) {
        Text("Off").tag(0.0)
        Text("3 Seconds").tag(3.0)
        Text("10 Seconds").tag(10.0)
      }

      Divider()

      Menu("Camera") {
        if captureMenuState.cameras.isEmpty {
          Button(captureMenuState.cameraAccessDenied ? "Camera Access Off" : "No Cameras Found") {}
            .disabled(true)
        } else {
          Picker(
            "Camera",
            selection: Binding(
              get: { captureMenuState.selectedCameraID },
              set: { selectedID in
                if let selectedID {
                  CaptureViewModel.shared.selectedCameraID = selectedID
                }
              })
          ) {
            ForEach(captureMenuState.cameras) { camera in
              Text(camera.localizedName).tag(Optional(camera.uniqueID))
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .disabled(captureMenuState.cameraAccessDenied)
        }
      }

      Menu("Mode") {
        if captureMenuState.availableModes.isEmpty {
          Button("No Modes Available") {}
            .disabled(true)
        } else {
          Picker(
            "Mode",
            selection: Binding(
              get: { captureMenuState.selectedModeID },
              set: { selectedID in
                if let selectedID {
                  CaptureViewModel.shared.selectedModeID = selectedID
                }
              })
          ) {
            ForEach(captureMenuState.availableModes) { mode in
              Text(mode.descriptiveLabel).tag(Optional(mode.id))
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
          .disabled(captureMenuState.cameraAccessDenied)
        }
      }
    }
    CommandGroup(after: .sidebar) {
      Toggle("Show Controls", isOn: $showControls)

      Toggle("Mirror Preview", isOn: $mirrorPreview)
        .keyboardShortcut("m", modifiers: [.command])
        .accessibilityLabel("Mirror preview")

      Picker("Preview Size", selection: $actualSizePreview) {
        Text("Fit to Window").tag(false)
        Text("Actual Size").tag(true)
      }
    }
    CommandGroup(after: .windowList) {
      Toggle(
        "Capture Details",
        isOn: Binding(
          get: { detailsWindowState.isOpen },
          set: { shouldOpen in
            if shouldOpen {
              openWindow(id: CaptureDetailsScene.id)
            } else {
              dismissWindow(id: CaptureDetailsScene.id)
            }
          }
        ))
      Toggle(
        statusMenuTitle,
        isOn: Binding(
          get: { statusWindowState.isOpen },
          set: { shouldOpen in
            if shouldOpen {
              openWindow(id: CaptureStatusScene.id)
            } else {
              dismissWindow(id: CaptureStatusScene.id)
            }
          }
        ))
    }
  }

  private var statusMenuTitle: String {
    hasStatusAttention ? "Capture Status — Needs Attention" : "Capture Status"
  }

  private var hasStatusAttention: Bool {
    saveQueue.progressItems.contains(where: \.needsAttention)
      || !saveQueue.retainedItems.isEmpty
      || !saveQueue.dismissedRetainedItems.isEmpty
      || saveQueue.recoveryError != nil
      || saveQueue.capacityError != nil
      || photosAuthorizationNeedsAttention
  }

  private var photosAuthorizationNeedsAttention: Bool {
    switch saveQueue.photosAuthorizationState {
    case .denied, .restricted, .unknown: true
    case .notDetermined, .authorized, .limited: false
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
      do {
        _ = try await queue.discardDismissedCapturesOnTermination()
      } catch {
        let alert = NSAlert()
        alert.messageText = "Could not remove dismissed captures"
        alert.informativeText =
          "They remain recoverable on this Mac. \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        _ = alert.runModal()
      }
      sender.reply(toApplicationShouldTerminate: true)
      self?.terminationTask = nil
    }
    return .terminateLater
  }
}

struct CaptureWindowView: View {
  @StateObject private var viewModel = CaptureViewModel.shared
  @ObservedObject private var saveQueue = SaveQueueHolder.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("mirrorPreview") private var mirrorPreview = false
  @AppStorage("actualSizePreview") private var actualSizePreview = false
  @AppStorage("showControls") private var showControls = true

  var body: some View {
    ZStack(alignment: .topLeading) {
      previewSurface
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if showControls && mirrorPreview {
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

      if showControls {
        captureControlsOverlay
      }
    }
    .frame(minWidth: 700, minHeight: 560)
    .overlay(alignment: .bottomTrailing) {
      if activePendingCount > 0 {
        PendingSaveIndicator(count: activePendingCount)
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(.ultraThinMaterial, in: Capsule())
          .padding(16)
          .transition(reduceMotion ? .identity : .opacity)
          .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: activePendingCount)
      }
    }
    .onAppear {
      viewModel.activate()
      Task { await saveQueue.refreshPhotosAuthorizationStatus() }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      Task { await saveQueue.refreshPhotosAuthorizationStatus() }
    }
    .onDisappear { viewModel.deactivate() }
    .background {
      SpaceShutterMonitor { viewModel.requestCapture() }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }

  private var activePendingCount: Int {
    saveQueue.progressItems.filter { !$0.needsAttention && !$0.isComplete }.count
  }

  private var captureControlsOverlay: some View {
    VStack(spacing: 12) {
      Spacer(minLength: 0)

      if viewModel.canOverrideAdjustment {
        HStack(spacing: 12) {
          Text("The camera is still adjusting. You can wait or continue now.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Button("Capture while adjusting") { viewModel.allowCaptureWhileAdjusting() }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 620)
      }

      ShutterButton(state: viewModel.shutterEnabled ? .enabled : .disabled) {
        viewModel.requestCapture()
      }

      HStack(spacing: 10) {
        let latestResult = viewModel.lastResultText
        Text(
          latestResult
            ?? (viewModel.shutterEnabled ? "Ready" : viewModel.captureStateText)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityLabel(latestResult == nil ? "Capture readiness" : "Latest capture result")
        .accessibilityValue(latestResult ?? viewModel.captureStateText)
        .accessibilityAddTraits(.updatesFrequently)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())

        Spacer(minLength: 0)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
      if viewModel.availableModes.isEmpty {
        CameraStateCard(
          symbol: "video.slash", title: "No supported mode is available",
          detail: "Choose another camera or refresh the camera list.",
          actionTitle: "Refresh Cameras", action: viewModel.refreshCameras)
      } else {
        CameraStateCard(
          symbol: "video", title: "Choose a camera mode",
          detail:
            "This camera has \(viewModel.availableModes.count) available formats. Choose one from the Mode menu to start capture.",
          actionTitle: nil, action: {})
      }
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

}

private struct PendingSaveIndicator: View {
  let count: Int

  private var label: String {
    count == 1 ? "1 capture is being saved" : "\(count) captures are being saved"
  }

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityAddTraits(.updatesFrequently)
  }
}

private struct CaptureStatusWindowView: View {
  @ObservedObject private var saveQueue = SaveQueueHolder.shared
  @ObservedObject private var windowState = CaptureStatusWindowState.shared
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isProgressExpanded = false
  @State private var actionMessage: String?
  @State private var deletionRequest: CaptureDeletionRequest?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if !saveQueue.photosAuthorizationState.canAddPhotos {
          PhotosAuthorizationBanner(
            state: saveQueue.photosAuthorizationState,
            requestAccess: saveQueue.requestPhotosAuthorization,
            openSettings: openPhotosSettings)
        }
        if let recoveryError = saveQueue.recoveryError {
          RecoveryErrorBanner(
            message: recoveryError, retry: saveQueue.retryRecovery,
            dismiss: saveQueue.dismissRecoveryError)
        }
        if let capacityError = saveQueue.capacityError {
          QueueCapacityBanner(message: capacityError) { saveQueue.dismissCapacityError() }
        }
        if let actionMessage {
          Text(actionMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .accessibilityLabel("Capture status action result: \(actionMessage)")
        }
        if !saveQueue.progressItems.isEmpty {
          CaptureProgressSection(
            items: saveQueue.progressItems,
            isExpanded: $isProgressExpanded,
            onRetry: retryCapture,
            onSaveOriginal: saveOriginal,
            onDismiss: dismissCapture
          )
          .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
        }
        if !saveQueue.retainedItems.isEmpty {
          RetainedCapturesSection(
            items: saveQueue.retainedItems,
            onRetry: retryCapture,
            onSaveOriginal: saveOriginal,
            onDismiss: saveQueue.dismissRetainedCapture,
            onDelete: requestDeletion)
        }
        if !saveQueue.dismissedRetainedItems.isEmpty {
          DismissedCapturesSection(
            items: saveQueue.dismissedRetainedItems,
            onRetry: retryCapture,
            onSaveOriginal: saveOriginal,
            onRestore: saveQueue.restoreRetainedCapture,
            onDelete: requestDeletion)
        }
        if hasNoStatusContent {
          VStack(alignment: .leading, spacing: 6) {
            Label("No recent capture activity", systemImage: "checkmark.circle")
              .font(.headline)
            Text("Active saves, failures and retained originals will appear here.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(18)
          .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
    }
    .frame(minWidth: 620, minHeight: 420)
    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: saveQueue.progressItems)
    .onAppear {
      windowState.windowDidOpen()
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
    .onDisappear { windowState.windowDidClose() }
    .confirmationDialog(
      "Delete retained capture?",
      isPresented: Binding(
        get: { deletionRequest != nil },
        set: { if !$0 { deletionRequest = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete Capture", role: .destructive) { confirmDeletion() }
      Button("Cancel", role: .cancel) { deletionRequest = nil }
    } message: {
      if let deletionRequest {
        if deletionRequest.fileNames.isEmpty {
          Text(
            "No staged image or source files remain. This removes only the recovery journal entry for \(deletionRequest.item.title). No Photos asset or exported file is affected."
          )
        } else {
          Text(
            "This permanently deletes \(deletionRequest.fileNames.joined(separator: ", ")) from PixelBooth's private staging folder for \(deletionRequest.item.title). It does not delete a Photos asset or any file saved with Save Original."
          )
        }
      }
    }
  }

  private var attentionCaptureIDs: [UUID] {
    saveQueue.progressItems.filter(\.needsAttention).map(\.uuid)
  }

  private var hasNoStatusContent: Bool {
    saveQueue.photosAuthorizationState.canAddPhotos
      && saveQueue.recoveryError == nil
      && saveQueue.capacityError == nil
      && actionMessage == nil
      && saveQueue.progressItems.isEmpty
      && saveQueue.retainedItems.isEmpty
      && saveQueue.dismissedRetainedItems.isEmpty
  }

  private func openPhotosSettings() {
    let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    NSWorkspace.shared.open(settingsApp)
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

    actionMessage = nil
    Task {
      do {
        try await saveQueue.queue.retry(
          uuid: item.uuid, confirmingPossibleDuplicate: confirmedPossibleDuplicate)
      } catch {
        actionMessage = "Retry failed: \(error.localizedDescription)"
      }
    }
  }

  private func saveOriginal(_ item: CaptureProgressItem) {
    actionMessage = nil
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
        actionMessage = "Original saved to \(destination.lastPathComponent)"
      } catch {
        actionMessage = "Could not save original: \(error.localizedDescription)"
      }
    }
  }

  private func dismissCapture(_ item: CaptureProgressItem) {
    actionMessage = nil
    Task(priority: .userInitiated) {
      do {
        try await saveQueue.queue.dismissFailedCaptureFromProgress(uuid: item.uuid)
      } catch {
        actionMessage = "Could not dismiss capture: \(error.localizedDescription)"
      }
    }
  }

  private func requestDeletion(_ item: CaptureProgressItem) {
    actionMessage = nil
    Task {
      do {
        let fileNames = try await saveQueue.queue.retainedFilesForDeletion(uuid: item.uuid)
        deletionRequest = CaptureDeletionRequest(item: item, fileNames: fileNames)
      } catch {
        actionMessage = "Could not prepare capture deletion: \(error.localizedDescription)"
      }
    }
  }

  private func confirmDeletion() {
    guard let request = deletionRequest else { return }
    deletionRequest = nil
    Task(priority: .userInitiated) {
      do {
        try await saveQueue.queue.deleteRetainedCapture(uuid: request.item.uuid)
        await saveQueue.reconcileAndRefresh()
        actionMessage = "Deleted retained capture and released its staging capacity."
      } catch {
        actionMessage = "Could not delete retained capture: \(error.localizedDescription)"
      }
    }
  }
}

private struct CaptureDeletionRequest {
  let item: CaptureProgressItem
  let fileNames: [String]
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
  let dismiss: () -> Void

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
      Button("Dismiss", action: dismiss)
        .buttonStyle(.bordered)
        .accessibilityLabel("Dismiss recovery error message")
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
  let onRetry: (CaptureProgressItem, Bool) -> Void
  let onSaveOriginal: (CaptureProgressItem) -> Void
  let onDismiss: (CaptureProgressItem) -> Void
  let onDelete: (CaptureProgressItem) -> Void
  @State private var isExpanded = true

  var body: some View {
    DisclosureGroup("Retained captures (\(items.count))", isExpanded: $isExpanded) {
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
              if !item.isPermanentlyUnencodable {
                Button("Retry") { onRetry(item, false) }
                Button("Save Original…") { onSaveOriginal(item) }
                  .accessibilityLabel("Save retained original for \(item.title)")
              }
              Button("Dismiss") { onDismiss(item) }
                .accessibilityLabel("Dismiss retained capture \(item.title)")
              Button("Delete Capture", role: .destructive) { onDelete(item) }
                .accessibilityLabel("Delete retained capture \(item.title)")
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
  let onRetry: (CaptureProgressItem, Bool) -> Void
  let onSaveOriginal: (CaptureProgressItem) -> Void
  let onRestore: (CaptureProgressItem) -> Void
  let onDelete: (CaptureProgressItem) -> Void
  @State private var isExpanded = true

  var body: some View {
    DisclosureGroup("Dismissed captures (\(items.count))", isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "These captures are removed when PixelBooth quits. Restore one to keep it recoverable."
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
                Button("Delete Capture", role: .destructive) { onDelete(item) }
                  .accessibilityLabel("Delete dismissed capture \(item.title)")
                if !item.isPermanentlyUnencodable {
                  Button("Retry") { onRetry(item, false) }
                  Button("Save Original…") { onSaveOriginal(item) }
                }
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

private struct CaptureDetailsWindowView: View {
  @ObservedObject private var viewModel = CaptureViewModel.shared
  @ObservedObject private var windowState = CaptureDetailsWindowState.shared

  var body: some View {
    ScrollView {
      CaptureInspectorView(viewModel: viewModel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
    .frame(minWidth: 620, minHeight: 360)
    .onAppear { windowState.windowDidOpen() }
    .onDisappear { windowState.windowDidClose() }
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
            if !item.isPermanentlyUnencodable {
              Button("Retry") { onRetry(false) }
                .accessibilityLabel("Retry \(item.title)")
              Button("Save Original…", action: onSaveOriginal)
                .accessibilityLabel("Save original for \(item.title)")
            }
            Button("Dismiss", action: onDismiss)
              .accessibilityLabel("Dismiss \(item.title) from capture progress")
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
  @State private var isAdvancedExpanded = false

  var body: some View {
    Form {
      Section {
        LabeledContent("Save captures to") {
          Label("System Photo Library", systemImage: "photo.on.rectangle.angled")
            .foregroundStyle(.secondary)
        }

        LabeledContent("Self-timer") {
          Picker("Self-timer", selection: $countdownSeconds) {
            Text("Off").tag(0.0)
            Text("3 seconds").tag(3.0)
            Text("10 seconds").tag(10.0)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .frame(maxWidth: 280)
          .accessibilityLabel("Self-timer")
        }
      } header: {
        Text("Capture")
      } footer: {
        Text("Captures are added directly to Photos.")
      }

      Section("Preview") {
        Toggle("Mirror Preview", isOn: $mirrorPreview)
        Text(
          "Mirroring changes the live view only. Saved image samples and orientation are unchanged."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Include Location", isOn: $includeLocation)

        Stepper(value: $locationMaximumAge, in: 10...600, step: 10) {
          LabeledContent("Maximum location age") {
            Text("\(Int(locationMaximumAge)) seconds")
              .monospacedDigit()
          }
        }
        .disabled(!includeLocation)
        .accessibilityHint("The maximum age of the Mac location that can be added to a capture")
      } header: {
        Text("Location")
      } footer: {
        Text(
          "When enabled, PixelBooth requests while-in-use location access and uses this Mac's location. Capturing never waits for a location fix, and camera metadata remains unchanged."
        )
      }

      DisclosureGroup(isExpanded: $isAdvancedExpanded) {
        VStack(alignment: .leading, spacing: 12) {
          LabeledContent("Maximum frame rate") {
            Picker("Maximum frame rate", selection: $frameRateOverride) {
              Text("Mode maximum").tag(0.0)
              Text("Up to 15 fps").tag(15.0)
              Text("Up to 30 fps").tag(30.0)
              Text("Up to 60 fps").tag(60.0)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Maximum frame rate")
          }

          Text(
            "Limits the requested rate for the selected mode. Resolution and image precision stay unchanged."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)

          Divider()

          Text("Readiness")
            .font(.subheadline.weight(.semibold))

          Stepper(value: $minimumFreshFrames, in: 1...60) {
            LabeledContent("Minimum fresh frames") {
              Text("\(minimumFreshFrames) frames").monospacedDigit()
            }
          }

          Stepper(value: $minimumMillisecondsSinceValidStart, in: 100...5000, step: 100) {
            LabeledContent("Minimum time after stream start") {
              Text("\(minimumMillisecondsSinceValidStart) milliseconds").monospacedDigit()
            }
          }

          Stepper(value: $maximumAdjustingWaitMilliseconds, in: 1000...20000, step: 500) {
            LabeledContent("Maximum adjusting wait") {
              Text("\(maximumAdjustingWaitMilliseconds) milliseconds").monospacedDigit()
            }
          }

          Text("Readiness uses fresh frames and a bounded wait while the camera adjusts.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
      } label: {
        Label("Advanced", systemImage: "slider.horizontal.3")
          .font(.headline)
      }
    }
    .frame(
      minWidth: 520, idealWidth: 620,
      minHeight: 540, idealHeight: 660
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
