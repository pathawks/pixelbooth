# TN3121 verification log (installed SDK evidence)

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
compatibility label applies and requires explicit user acknowledgment.

## Consequences for the runtime classification

- The capture service computes fidelity from **observed delivered sample
  buffers** against the **negotiated device format**, not from the
  videoSettings dictionary alone.
- On this machine, uncompressed capture is truthfully classified
  `macDeliveredConverted` with the conversion recorded
  (e.g. "UYVY → NV12 conversion known, samples preserved after macOS").
- MJPEG capture (when exposed) is decoded by VideoToolbox and archived as
  lossless AVIF; no claim of untouched USB-level acquisition is made.

## Re-verification

Re-run `.build/out/Products/Debug/HardwareProbe` after SDK updates; record
results in this file with the OS build.
