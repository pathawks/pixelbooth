// Camera preview view. The preview never feeds the archival encoder; it is
// display-only, and mirroring affects only what is shown. Mirroring writes
// go through the exception-safe ObjC shim (verified macOS 27.0 crash source).

import AVFoundation
import PixelBoothCAvifShim
import PixelBoothCapture
import SwiftUI

struct CameraPreviewViewRepresentable: NSViewRepresentable {
  let viewModel: CaptureViewModel
  let actualSize: Bool
  @AppStorage("mirrorPreview") private var mirrorPreview = false

  func makeNSView(context: Context) -> PreviewPreviewView {
    let v = PreviewPreviewView()
    v.setActualSize(actualSize)
    attach(v)
    return v
  }

  func updateNSView(_ view: PreviewPreviewView, context: Context) {
    view.setMirrored(mirrorPreview)
    view.setActualSize(actualSize)
    attach(view)
  }

  /// Cheap and idempotent: routes to whichever backend is active.
  private func attach(_ view: PreviewPreviewView) {
    switch viewModel.activeBackend {
    case .cmio:
      view.attachCMIO()
    case .avfoundation, nil:
      if let session = CaptureService.previewSession() {
        view.attach(session: session)
      }
    }
  }
}

/// Latest-frame holder for the CMIO preview path. The preview is display-only:
/// it renders the most recent CMIO-delivered pixel buffer at a fixed cadence
/// and never feeds the archival encoder (spec).
final class CMIOFrameBox: @unchecked Sendable {
  // @unchecked Sendable is a narrow, documented exception: `lock` protects the
  // only mutable state (`latest`); sinks store from capture queues while the
  // preview timer reads on the main thread — the buffer itself is never
  // written after delivery.
  static let shared = CMIOFrameBox()
  private let lock = NSLock()
  private var latest: CVPixelBuffer?

  func store(_ pb: CVPixelBuffer) {
    lock.lock()
    latest = pb
    lock.unlock()
  }

  func current() -> CVPixelBuffer? {
    lock.lock()
    defer { lock.unlock() }
    return latest
  }

  func clear() {
    lock.lock()
    latest = nil
    lock.unlock()
  }
}

/// Sink that publishes the most recent CMIO frame for preview rendering.
final class CMIOFrameBoxSink: FrameSink {
  func receive(_ frame: DeliveredFrame) {
    if let pb = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
      CMIOFrameBox.shared.store(pb)
    }
  }
}

/// NSView wrapper around AVCaptureVideoPreviewLayer; rendering only.
/// When the CMIO backend is active, frames render into an overlay sublayer
/// through CoreImage instead (an AVCaptureVideoPreviewLayer cannot attach to
/// a CMIO stream). Mirroring is preview-only either way.
final class PreviewPreviewView: NSView {
  var isMirrored: Bool = false
  private var actualSize = false
  private let cmioLayer = CALayer()
  private var cmioTimer: Timer?
  private let ciContext = CIContext(options: [.cacheIntermediates: false])

  func setMirrored(_ value: Bool) {
    isMirrored = value
    applyMirroring()
    if cmioTimer != nil { renderCMIOFrame() }
  }

  func setActualSize(_ value: Bool) {
    actualSize = value
    if cmioLayer.superlayer != nil {
      cmioLayer.contentsGravity = actualSize ? .center : .resizeAspect
      renderCMIOFrame()
    }
  }

  private var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }

  /// Mirroring is applied through the exception-safe ObjC shim: on macOS 27
  /// the KVO'd `isVideoMirrored` setter raises NSInvalidArgumentException
  /// via `isVideoRotationAngleSupported:` whenever the connection lacks an
  /// active source (permission prompt pending, mid-reconfigure). The shim's
  /// @try returns failure instead of crashing; a later update retries.
  func applyMirroring() {
    let raw = unsafeBitCast(previewLayer, to: UnsafeMutableRawPointer.self)
    _ = pixelbooth_apply_preview_mirroring(raw, isMirrored)
  }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    wantsLayer = true
    layer = AVCaptureVideoPreviewLayer()
    previewLayer.videoGravity = .resizeAspect  // full frame, no cropping
  }

  required init?(coder: NSCoder) { fatalError("unsupported") }

  func attach(session: AVCaptureSession) {
    if previewLayer.session !== session {
      previewLayer.session = session
    }
    // The AVFoundation preview path takes over: detach the CMIO overlay.
    stopCMIO()
    applyMirroring()
  }

  /// CMIO preview path: render the latest delivered frame into the overlay
  /// sublayer. Idempotent; a 30 Hz timer is display-only cadence.
  func attachCMIO() {
    if previewLayer.session != nil {
      previewLayer.session = nil
    }
    if cmioLayer.superlayer == nil {
      wantsLayer = true
      layer?.addSublayer(cmioLayer)
    }
    cmioLayer.contentsGravity = actualSize ? .center : .resizeAspect
    cmioLayer.frame = bounds
    if cmioTimer == nil {
      let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.renderCMIOFrame()
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      cmioTimer = timer
    }
    renderCMIOFrame()
  }

  private func stopCMIO() {
    cmioTimer?.invalidate()
    cmioTimer = nil
    cmioLayer.removeFromSuperlayer()
    cmioLayer.contents = nil
  }

  private func renderCMIOFrame() {
    guard let pb = CMIOFrameBox.shared.current() else { return }
    var image = CIImage(cvPixelBuffer: pb)
    if isMirrored {
      let width = CGFloat(CVPixelBufferGetWidth(pb))
      // Mirror horizontally around the frame center; preview-only (spec).
      image = image.transformed(
        by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -width, y: 0))
    }
    guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
    cmioLayer.contents = cg
  }

  override func layout() {
    super.layout()
    guard cmioLayer.superlayer != nil else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    cmioLayer.frame = bounds
    CATransaction.commit()
  }
}
