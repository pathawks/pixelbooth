// Camera preview view. The preview never feeds the archival encoder; it is
// display-only, and mirroring affects only what is shown.

import SwiftUI
import AVFoundation

struct CameraPreviewViewRepresentable: NSViewRepresentable {
  let viewModel: CaptureViewModel
  @AppStorage("mirrorPreview") private var mirrorPreview = false

  func makeNSView(context: Context) -> PreviewPreviewView {
    let v = PreviewPreviewView()
    return v
  }

  func updateNSView(_ view: PreviewPreviewView, context: Context) {
    view.setMirrored(mirrorPreview)
    Task { await viewModel.attachPreview(view) }
  }
}

/// NSView wrapper around AVCaptureVideoPreviewLayer; rendering only.
final class PreviewPreviewView: NSView {
  var isMirrored: Bool = false {
    didSet { previewLayer.connection?.isVideoMirrored = isMirrored }
  }

  func setMirrored(_ value: Bool) {
    isMirrored = value
  }

  private var previewLayer: AVCaptureVideoPreviewLayer {
    layer as! AVCaptureVideoPreviewLayer
  }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    wantsLayer = true
    layer = AVCaptureVideoPreviewLayer()
    previewLayer.videoGravity = .resizeAspect  // full frame, no cropping
  }

  required init?(coder: NSCoder) { fatalError("unsupported") }

  func attach(session: AVCaptureSession) {
    previewLayer.session = session
  }
}
