# TN3121 verification log (installed SDK evidence)

## Verified launch-crash finding (macOS 27.0)

Assigning `AVCaptureVideoPreviewLayer.connection.isVideoMirrored` during the
SwiftUI update cycle raises an NSException inside AVFCapture
(`-[AVCaptureConnection_Tundra isVideoRotationAngleSupported:]`, reached via
`_NSSetBoolValueAndNotify`) once the camera session is live; AppKit's
`+[NSApplication _crashOnException:]` escalates it to EXC_BREAKPOINT (SIGTRAP)
during `NSHostingView.updateConstraints`. Mirroring is therefore applied only
when `connection.isVideoMirroringSupported`, and re-applied on session attach
(`PreviewPreviewView.applyMirroring`).

## Environment

- OS: macOS 27.0 (Build 26A428), Apple M1 Max
- SDK: MacOSX27.0 (Command Line Tools and Xcode 27.0 toolchain both present)
- Probe: `Tools/HardwareProbe` (headless, no XCTest dependency)

## Cameras actually discovered

| Device | Unique ID | Manufacturer | Advertised formats (first 12) |
|--------|-----------|--------------|-------------------------------|
| FaceTime HD Camera (built-in) | 47B4B64B-… | Apple Inc. | 1920×1080/1280×720/640×480 … fourCC `420v`, 30 fps max |
| USB3 Video (UVC) | 0x210000345f2130 | UltraSemi | 640×480 … 1280×720 fourCC `yuvs` (UYVY) and `420v` (NV12), 60 fps |

## Verified finding 1: empty videoSettings dictionary is normalized to nil

Setting `output.videoSettings = [:]` (explicitly empty, non-nil) was observed
to be **normalized to nil** by the installed SDK. Consequence: requesting
"native-format delivery via an empty dictionary" does not change the delivery
on this system; the data output instead uses the **default uncompressed
output**, which is a documented conversion relative to what the UVC camera
advertises natively (`yuvs`/UYVY).

This is exactly the distinction the product spec requires us to verify
against the installed SDK rather than trust from configuration.

## Verified finding 2: delivered ≠ negotiated for the UVC camera

The UVC camera advertises UYVY (`yuvs`) natively, but the sample buffers
actually delivered were `420v` (NV12). Per the fidelity contract, the
acquisition-fidelity classification must be:

- `macDeliveredConverted` — macOS performed a known conversion (UYVY → NV12).

The app must not label this path `nativePreserved`. When the camera's
advertised FourCC matches the delivered FourCC *and* evidence supports no
upstream conversion, `nativePreserved` is reported; otherwise the
compatibility label applies and the evidence records that upstream behavior is
unknown. Unknown upstream behavior does not block capture.

## Consequences for the runtime classification

- The capture service computes fidelity from **observed delivered sample
  buffers** against the **negotiated device format**, not from the
  videoSettings dictionary alone.
- On this machine, uncompressed capture is truthfully classified
  `macDeliveredConverted` with the conversion recorded
  (e.g. "UYVY → NV12 conversion known, samples preserved after macOS").
- MJPEG capture (when exposed) is decoded by VideoToolbox and archived as
  lossless AVIF; no claim of untouched USB-level acquisition is made.

## Verified finding 3: macOS 27 ignores negotiated mode selection

Observed on macOS 27.0 (Build 26A428), built-in FaceTime HD Camera
(47B4B64B-7067-4B9C-AD2B-AE273A71F4B5). The device advertises seven formats
(1920×1080, 1280×720, 1080×1920, 1760×1328, 640×480, 1328×1760, 1552×1552;
all `420v` NV12, 30 fps). Regardless of configuration, the sample buffers
delivered were **always 1920×1080 `420v`**:

- `device.activeFormat` set while the input is attached and the session is
  stopped: the readback adopts the selected format, `session.sessionPreset`
  stays `AVCaptureSessionPresetHigh` (the documented automatic flip to
  `inputPriority` does not occur), and delivery is still 1920×1080.
- Every settable session preset — `.high`, `.vga640x480`,
  `.iFrame1280x720` — is accepted by `canSetSessionPreset` yet delivery
  remains 1920×1080. `.hd4K3840x2160` is not supported by the session.
- `activeFormat` set before the input joins the session is reverted by the
  session at input attachment (readback returns to 1920×1080).
- `activeFormat` set while the session is running: readback sticks, but
  delivery stops (no further frames observed).
- `AVCaptureSessionPresetInputPriority` is `API_UNAVAILABLE(macos)` in the
  installed SDK (AVCaptureSessionPreset.h; verified by compile rejection).

Consequence: on this OS build the negotiated mode cannot be honored through
AVCaptureSession public APIs; the system delivers only the camera's default
stream. The delivered-buffer evidence (not the configuration) is therefore
the only valid acquisition-fidelity input, and mode dimensions that differ
from delivery are reported as a mismatch rather than silently accepted.
Re-verify after OS or SDK updates.

## Verified finding 4: the square mode IS deliverable at the CMIO layer

Observed on macOS 27.0 (Build 26A428), built-in FaceTime HD Camera. The
public CoreMediaIO HAL (the layer beneath AVFoundation) exposes the same
seven formats on the device's single video stream, and the stream format
property (`kCMIOStreamPropertyFormatDescription`) is settable:

- With no AVFoundation session active, the CMIO stream's current format was
  1552×1552 `420v`, and streaming directly through CMIO
  (`CMIODeviceStartStream` + `CMSimpleQueue`) delivered **1552×1552
  `420v`** — the camera's native square stream.
- After an AVFoundation session had run, the CMIO stream's current format
  was overridden to 1920×1080 `420v`, and CMIO streaming then delivered
  1920×1080. I.e., `AVCaptureSession` (default `.high` preset) pins the
  CMIO stream format at its default and never honors `activeFormat`.
- Observed proof that another app can obtain 1552×1552 output on this
  machine (user-provided AVIF file, 1552×1552, consistent with CMIO-level
  format selection).
- Attempting CMIO property access on the same device while an AVFoundation
  session is running is unstable: the camera plugin crashed
  (`EXC_BAD_ACCESS` in `objc_msgSend`) during property enumeration in an
  ad-hoc SwiftPM-built CLI process. Device ownership was ruled out: hog mode
  was unheld (-1) and `runningSomewhere` false during the failures.
- Consequence: obtaining the square mode requires a CMIO-direct capture
  client (no AVFoundation session on the device), or an OS/AVFoundation
  update that honors mode selection. The two paths cannot be mixed on this
  OS build. Re-verify after OS or SDK updates.
- **Verified amendment:** the format-switch write itself
  (`CMIOObjectSetPropertyData` on `kCMIOStreamPropertyFormatDescription`)
  crashes the camera plugin (`EXC_BAD_ACCESS` inside
  `CMIOExtension::Stream::SetPropertyData → CFEqual`, constant fault
  address) even from a clean process with no AVFoundation loaded and a
  properly retained argument. Streaming with the stream's *current* format
  is stable and delivers that format natively. The app therefore refuses
  the format-switch write on this OS build: CMIO streams a mode only when
  the device's current stream format already matches it; otherwise it falls
  back to AVFoundation. The built-in camera's stream was observed at
  1552×1552 while idle (its natural state) and at 1920×1080 after an
  AVFoundation session had stomped it; the state persists across processes.
  Re-verify after OS or SDK updates, and after a reboot with no camera
  client running.
- **Verified amendment 2 (working mode switch):** the device's stream
  format CAN be changed through AVFoundation's configuration path: setting
  `device.activeFormat` to the requested format while a session is running
  re-negotiates the device (AVFoundation's own delivery then breaks — it is
  not used), the negotiation survives the session stopping, and the direct
  CMIO stream subsequently delivers the selected format. The app implements
  this recipe in `CMIOCaptureService.renegotiateViaAVFoundation` with
  post-renegotiation verification at the CMIO layer; verified live on
  macOS 27.0 Build 26A428 (app log: renegotiated device format to
  1552×1552).

## Re-verification

Re-run `.build/out/Products/Debug/HardwareProbe` after SDK updates; record
results in this file with the OS build. The probe restricts delivery
experiments to built-in cameras so external devices (e.g. Continuity iPhone
cameras) are never activated by the probe.
