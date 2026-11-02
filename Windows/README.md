# PixelBooth for Windows

This is a Windows desktop implementation of PixelBooth using C#, WinUI 3, and
Media Foundation. It is an early implementation, not yet a release-ready
replacement for every feature of the macOS app.

## Build and run

Use x64 Windows 10 2004 (build 19041) or later, the .NET 10 SDK, the Windows
SDK, and Visual Studio's desktop development tools. A camera must be enabled
for desktop apps in Windows camera privacy settings. From the repository root:

```powershell
dotnet build Windows\PixelBooth\PixelBooth.csproj -c Debug -p:Platform=x64
.\Windows\PixelBooth\bin\x64\Debug\net10.0-windows10.0.19041.0\win-x64\PixelBooth.exe
dotnet run --project Windows\PixelBooth.Tests\PixelBooth.Tests.csproj -c Debug
```

To make an unpackaged, framework-dependent folder using an installed .NET 10
runtime:

```powershell
dotnet publish Windows\PixelBooth\PixelBooth.csproj -c Release -r win-x64 --self-contained false -p:Platform=x64
.\Windows\PixelBooth\bin\x64\Release\net10.0-windows10.0.19041.0\win-x64\publish\PixelBooth.exe
```

A self-contained publish can be requested with `--self-contained true`; it
needs the matching .NET runtime packs. That publish was not verified in this
environment because NuGet DNS resolution was unavailable. The application is
not yet signed or packaged as an installer. The Windows App SDK is included in
both builds.

Choose a camera from the **Capture** menu and open **Capture format…** to select
a format from the scrollable list. Wait for **Ready**,
and use **Take photo** or the space bar. The **View** menu contains preview
mirroring and capture details; the **File** menu contains save-folder actions.
Mirroring affects the preview only. The self-timer, camera and format selection,
and save folder are remembered. Photos default to
`Pictures\PixelBooth`; a different directory can be selected in the app.

## Preservation boundary and supported modes

The preserved input is the sample delivered by the Media Foundation source
reader using a camera-reported native media type. The app cannot establish what
the camera, driver, or system did upstream. Preview decoding, conversion, and
mirroring do not modify the captured sample.

- **MJPEG**: stores a JPEG frame without recompressing its coding data. Existing
  EXIF and non-XMP JPEG segments are retained; PixelBooth capture information is
  added as XMP, merging an existing standard XMP packet when present.
- **H.264**: Annex B access units with an independently decodable IDR picture,
  supported parameter sets, and a Windows-decodable picture can be wrapped in a
  HEIF `.avci` image without recompression. The next IDR after the shutter is
  used, with a ten-second timeout. This path has synthetic fixture coverage but
  has not been exercised with a physical H.264 webcam; compatibility with
  image viewers also needs real-world validation. Length-prefixed samples and
  non-IDR I pictures are not supported.
- **Raw**: explicitly progressive, tightly packed 8-bit NV12 and YUY2 can be
  stored as lossless AVIF or Deflate-compressed YCbCr TIFF. All native Y, Cb,
  and Cr samples are compared with the encoded result. NV12 with co-sited
  chroma (Media Foundation flags 7 or 15) uses AVIF, with its AV1
  sequence header and container chroma position checked before saving. NV12
  with centered chroma uses TIFF; NV12 with an unknown position uses AVIF.
  Media Foundation's reported matrix, range, and supported color information
  are stored in image tags and XMP. Unrepresentable NV12 positioning, missing
  required matrix/range, unsupported color attributes, other pixel layouts, and
  ambiguous strides are refused rather than guessed.

  YUY2 is treated as co-sited and encoded as 4:2:2 AVIF, including when the
  Media Foundation reports a conflicting or unspecified chroma-siting flag. The
  original Media Foundation flag and PixelBooth's interpretation are recorded separately
  in XMP. The 4:2:2 AV1 bitstream has no explicit chroma-position field, so
  viewers may not use that application metadata. The policy is an interpretation
  of the delivered samples, not a verified camera measurement.
  [YUY2 chroma evidence](Docs/YUY2-Chroma-Siting.md) records the BRIO probe,
  relevant documentation, and the remaining uncertainty.

  TIFF has a gamma-2.2 default when no transfer function is present. When
  Media Foundation reports an unknown transfer function, the TIFF instead
  records Media Foundation's specified BT.709 fallback and labels that choice
  as a fallback in XMP; it is not reported as a camera measurement. If the
  camera does not report color primaries, TIFF colorimetry remains unspecified.

The XMP records the host receive time, Media Foundation timestamp, camera and
mode, and reported color properties. It does not claim a hardware exposure
timestamp or record location. The warm-up indication is a frame-count/time
heuristic, not a measurement of exposure convergence. This edition does not
yet implement the macOS app's depth estimation or Photos integration.

### Camera settings in photographs

At the shutter, PixelBooth asks the active camera source for its readable
Windows camera and video-processing controls. Successful reads, their raw
values, flags, capabilities, property identifiers and individual observation
times are saved in the `https://pixelbooth.app/ns/capture/1.0/` XMP namespace.
Depending on the driver, they can include exposure, white balance, focus,
iris, zoom, gain, brightness, contrast, saturation, sharpness, anti-flicker
and other controls. Auto/manual flags are retained when provided. Exposure is
reported as the Windows control's log-base-two seconds; white balance uses
kelvin. Some controls use driver-defined values, so their raw values are
retained without inventing units.

These are **host observations near the selected frame**, not synchronized
measurements of that frame. In particular, a control read while automatic
exposure or focus is enabled does not prove the exposure or focus used for the
photo. PixelBooth does not change or lock camera controls to collect them.
Unsupported, unsuccessful, or timed-out reads do not prevent capture. The
camera's settings may change before the reads complete.

Separately, when Windows attaches documented capture-statistics attributes to
the selected Media Foundation sample, PixelBooth records those as frame
metadata with their original types and values. These may include exposure
time, ISO, white balance, logical lens position, focus state, gains, and
source EXIF. Blobs are retained as base64 up to 256 KiB each; an oversized
blob is recorded as omitted with its original size. The app does not collect
arbitrary vendor-specific or face-detection metadata. Source EXIF provided in
a sample attribute is archived in application XMP; it is not reinterpreted.
Where frame metadata provides a correctly typed exposure time or ISO, the app
also writes the corresponding standard EXIF-in-XMP field when this cannot
conflict with camera-supplied EXIF/XMP. Focus position is not focal length,
gain is not ISO, and white-balance temperature is not the EXIF auto/manual
white-balance field. Existing JPEG EXIF and XMP take precedence.

Microsoft documents the [per-frame capture statistics](https://learn.microsoft.com/en-us/windows-hardware/drivers/stream/mf-capture-metadata)
and the [exposure-control units](https://learn.microsoft.com/en-us/windows-hardware/drivers/stream/ksproperty-cameracontrol-exposure)
used by these observations.

Normally the observations are embedded in the image. If a JPEG's combined
metadata will not fit in its XMP marker, or existing XMP cannot safely be
merged, PixelBooth retains the camera JPEG unchanged and saves the new
metadata in a same-named `.xmp` sidecar. Keep the
two files together. The recovery queue retains both until the image and
sidecar have been saved successfully.

## Recovery and validation

The source sample is written to `%LOCALAPPDATA%\PixelBooth\Queue` before
encoding. An output is staged and integrity-checked before it is saved, and the
source is removed only after the final file is in place. Failed or interrupted
captures remain in the queue. Use **Retry pending captures** to save them to the
currently selected destination; unsupported sources remain available in the
queue for future versions. **Open recovery folder** exposes retained files,
including incomplete items that cannot be retried automatically. Queue admission is limited to 200 captures and
512 MiB. A capacity failure retains existing samples.

The test runner uses generated H.264 IDR and existing progressive JPEG fixtures,
checks preservation and malformed inputs, verifies raw sample round trips, and
exercises failed-save recovery. Optional hardware probes are explicit:

```powershell
dotnet run --project Windows\PixelBooth.Tests\PixelBooth.Tests.csproj -- --camera
dotnet run --project Windows\PixelBooth.Tests\PixelBooth.Tests.csproj -- --camera-capture
dotnet run --project Windows\PixelBooth.Tests\PixelBooth.Tests.csproj -- --camera-settings --brio
dotnet run --project Windows\PixelBooth.Tests\PixelBooth.Tests.csproj -- --yuy2-probe --brio
```

The first lists camera-reported formats; the second opens the first camera and
checks a sample of each supported format. The third reads the BRIO's controls
and checks an encoded image in memory; omit `--brio` for the first camera.
Neither probe writes a photo to the user's library. Camera tests do not
establish the camera's upstream behavior.

The optional YUY2 probe compares a synthetic edge through Windows'
`SoftwareBitmap.Convert` with several simple reconstruction models. It also
opens the selected camera via Media Foundation and then via `MediaCapture`,
requesting a 640×480 YUY2 source. Two `MediaFrameReader` instances request
YUY2 and BGRA frames from the same source and compare frames that have matching
system-relative timestamps. It fits the RGB conversion separately from the
chroma reconstruction model, reporting both all-pixel and chroma-edge errors.
It also encodes the matched YUY2 frame to AVIF and compares Windows' decoded
RGB with the matched `MediaCapture` RGB. For this in-memory encoding, it uses
color attributes from the separately enumerated Media Foundation mode with the
same dimensions and frame rate; it reports any attributes that `MediaCapture`
itself exposes. The probe holds frames only in memory and does not save photos.
Omit `--brio` to use the first detected camera.

The models cover nearest-neighbor and two linear interpolation choices, not
every possible Windows, driver, or hardware conversion. A low score describes
that particular capture path; it does not establish where the camera sampled
chroma. Flat scenes may not contain enough information to compare the models.

For a one-time USB-level investigation, the optional
[`Capture-UvcProbe.ps1`](Tools/Capture-UvcProbe.ps1) requires an elevated
PowerShell window and an existing USBPcap installation. It locates the BRIO,
captures only that physical USB device, and records SHA-256 hashes of sixty
640×480 YUY2 frames delivered by Media Foundation while the trace is active.
It writes the USB trace and hashes under `%LOCALAPPDATA%\PixelBooth\UvcProbes`.
The trace may contain camera images and traffic from other BRIO interfaces,
including its microphone; close other applications using the device first.
The capture must still be analyzed and UVC payloads reconstructed before a
USB frame can be compared with a reference hash. Do not treat a successful
capture or a matching hash alone as proof about the camera's sensor pipeline.
The script stops its dedicated USBPcap process after the reference frames are
collected, so the final record may be incomplete and buffered transfers may be
lost. It reports basic PCAP framing, but does not establish that a full UVC
frame was captured.

To analyze an existing trace, pass its directory and the USB device address
and video endpoint from that capture:

```powershell
dotnet run --project Windows\PixelBooth.Tests\PixelBooth.Tests.csproj -- --uvc-analyze '<probe-directory>' --device 1 --endpoint 0x81
```

The analyzer currently handles isochronous UVC input. It checks packet bounds,
errors and frame boundaries, removes UVC packet headers, and matches SHA-256
hashes against the recorded Media Foundation frames. It also reports the UVC
format and frame size when the trace contains their descriptors and commit.
The device address and endpoint may differ on a later capture.

## Dependencies

The application uses Windows App SDK, MediaFoundation.NetCore, and a native
libheif runtime with libaom for AVIF. See [ThirdPartyNotices](ThirdPartyNotices/)
for notices, source links, and a release-blocking provenance limitation on the
current native package. The generated `h264-idr.264` test fixture was made from
FFmpeg's `testsrc2` source with libx264, one 128 × 96 8-bit 4:2:0 IDR frame.
