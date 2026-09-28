// MirroringShim.m — applies preview mirroring with ObjC exception safety.
// Verified on macOS 27.0 (AVFCapture "Tundra"): setting
// AVCaptureConnection.isVideoMirrored can raise NSInvalidArgumentException
// via isVideoRotationAngleSupported: while the session has no active source
// (e.g. permission prompt pending, device reconnecting, mid-reconfigure).
// AppKit escalates the uncaught exception to a crash. This shim isolates
// the write inside @try and reports success/failure.

#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>

bool pixelbooth_apply_preview_mirroring(void *layerVoid, bool mirrored) {
  CALayer *layer = (__bridge CALayer *)layerVoid;
  if (!layer || ![layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
    return false;
  }
  AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)layer;
  AVCaptureConnection *connection = previewLayer.connection;
  if (!connection || !connection.isVideoMirroringSupported) {
    return false;
  }
  @try {
    // Header-documented throw conditions: (1) mirroring unsupported, (2)
    // automaticallyAdjustsVideoMirroring == YES. Disable auto-adjust first,
    // then set — otherwise ANY write throws on macOS 27.
    if (connection.automaticallyAdjustsVideoMirroring) {
      [connection setAutomaticallyAdjustsVideoMirroring:NO];
    }
    if ([connection isVideoMirrored] != mirrored) {
      [connection setVideoMirrored:mirrored];
    }
    return true;
  } @catch (NSException *exception) {
    // Documented crash source on macOS 27.0: rotation-angle query throws
    // while the connection lacks an active source (permission pending,
    // reconfiguration in flight). Retry on a later update.
    return false;
  }
}

bool pixelbooth_preview_session_running(void *layerVoid) {
  CALayer *layer = (__bridge CALayer *)layerVoid;
  if (!layer || ![layer isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
    return false;
  }
  AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)layer;
  return previewLayer.session.isRunning;
}
