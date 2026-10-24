# Brio color metadata investigation, 2026-10-23–24

Observed on macOS 27.0.1 (26A434), macOS 27.0 SDK, Apple Silicon, with one
Logitech BRIO, USB `046d:085e`. These are point-in-time observations, not a
model-wide compatibility guarantee. No Photos library was accessed and the
supplied AVIF originals were not rewritten.

## Result

The USB camera explicitly declares a BT.601 YCbCr matrix. Actual macOS
delivery can report BT.709 instead, or report BT.601 on an early frame and
omit the matrix on later frames. A camera-wide override is insufficient.
PixelBooth preserves each photograph's explicit delivered metadata and records
a missing matrix as a diagnostic while continuing supported image saves.

Bounded color observations from the stream are retained separately for
reports. An earlier observation is not a replacement for missing shutter-frame
metadata. Identical ICC bytes and geometry do not establish YUV matrix identity.

## USB declarations

The public `IOUSBDeviceInterface.GetConfigurationDescriptorPtr` API returned
the selected configuration without `USBDeviceOpen`, seize, reset, interface
claiming, or control writes. Its public header permits reads without opening
the device. The configuration is value 1 of one configuration, 3,502 bytes,
UVC version `0x0100`, SHA-256
`1a942e5cd605d3b065ed598bc7ee63a7fe79e3323d9654f3b07dd741300b42bd`.

Each Color Matching descriptor contains `06 24 0d 01 01 04`: length 6,
class-specific interface, Color Matching subtype, BT.709 primaries, BT.709
transfer, SMPTE170M/BT.601 matrix. UVC matrix **4** maps to CICP/AVIF matrix
**6**; the numbering systems are not interchangeable.

| Interface / format | Representation | Advertised frames | Color descriptor offset |
| --- | --- | --- | --- |
| 1 / 1 | YUY2 | 19; up to 1920×1080, about 30 fps | `0x548` |
| 1 / 2 | MJPEG | 20; includes 4096×2160 at about 30 fps, 1080p60, 720p90 | `0x9a9` |
| 1 / 3 | NV12 | 640×480, 640×360, 1280×720, 1920×1080; up to about 30 fps | `0xaa2` |
| 2 / 4 | Frame-based GUID `00000032-0002-0010-8000-00aa00389b71` | 340×340, 8-bit, about 30 fps | `0xc2d` |

These are per-format declarations. USB-IF UVC 1.1 and 1.5 section 3.9.2.6
define the same six-byte layout and values. Original UVC 1.0 text was not
directly recovered. No default-value assumption is needed here: all three
components are explicit.

There is no H.264 format in this configuration. A macOS registry rule to hide
H.264 does not prove support. The registry also hides YUY2 640×360, consistent
with 18 macOS `yuvs` formats from 19 USB YUY2 frames.

Only USB MJPEG advertises 4K in this configuration. macOS 4K `420v` delivery
is consistent with platform JPEG decoding, not evidence of native camera
NV12. At 1080p30, USB NV12 and decoded MJPEG are both possible. The selected
USB payload and any processing were not traced at the bus level.

## Delivered metadata

Both APIs advertised BT.709 primaries, SMPTE240M transfer, and BT.709 matrix.
Some actual samples disagree, so advertised values are unsafe as a fallback.

Two ICC profiles were observed:

- Composite NTSC, 616 bytes, SHA-256
  `53c68a082acdf0d8dc84da6fbe7662b68f560fd1af2610a3c61ca2123acb67dd`.
- The profile accompanying BT.709/SMPTE240M/BT.709 delivery, 632 bytes, SHA-256
  `5c43e821fd8c7143e90c57725a100ec429390e3097faa88d97a6d64a6acdc637`.

| Probe | Frames | Observed matrix |
| --- | --- | --- |
| Raw CMIO, current 1080p `420v`, before AVFoundation session | 120 | First BT.601; remaining 119 missing. Composite NTSC ICC throughout. |
| Same CMIO path with Core Image preview | 120 | 65 BT.601, 55 missing. No inspected frame's attachments changed after `CIImage` creation or `CIContext` rendering. |
| AVFoundation, empty non-nil `videoSettings`, 1080p `420v` | 120 | All BT.709, with 632-byte ICC. No output color override requested. |
| Raw CMIO after the AVFoundation session stopped | 120 | All BT.709, 632-byte ICC. State can persist across clients. |
| Production CMIO backend, 1080p `yuvs`, requested 30 fps | 90 | All BT.709, 632-byte ICC. |
| Production CMIO backend, 1080p `420v` 30-fps representation | 90 | All BT.709, 632-byte ICC. |
| Production CMIO backend, 1080p `420v` 60-fps representation | 90 | First BT.601; remaining 89 missing. Composite NTSC ICC. |
| Production CMIO backend, 3840×2160 `420v`, requested 30 fps | 90 | First BT.601; remaining 89 missing. Composite NTSC ICC. |
| Production CMIO backend, 4096×2160 `420v`, requested 30 fps | 90 | First BT.601; remaining 89 missing. Composite NTSC ICC. |

BT.601-tagged samples also carried SMPTE_C primaries and BT.709 transfer.
BT.709-tagged samples carried BT.709 primaries and SMPTE240M transfer. Where
tags were absent, both sample-format extensions and pixel attachments omitted
them. The RGB `CGColorSpace` property list exposed profile data, not an
additional YUV matrix field. Captures 5 and 6 similarly archived the 616-byte
ICC without hidden matrix, `colr` atoms, or verbatim format metadata.

The mode probe inspected actual delivered dimensions/FourCC, not measured
delivery rates. It restored the original 1080p representation and approximately
24-fps rate and left the stream stopped. It used production AVFoundation
negotiation with CMIO verification, no direct CMIO format writes or qualified
rate queries.

These observations do not prove whether different tags reflect sample
conversion, metadata reconstruction, or a platform tagging defect. No
simultaneous USB/sample comparison or calibrated color-chart measurement was
performed. USB declarations alone cannot resolve this contradiction.

## General application changes

- Known per-frame matrices continue to be written to AVIF without sample
  conversion. Missing values remain code 2, unspecified, with a warning/report
  even when an ICC exists. This does not reject the shutter or final supported
  image save.
- Bounded stream observations preserve early tags and omission transitions
  with frame/time/generation/format/profile identity, separately from the
  photograph's color descriptor, in durable metadata and application XMP.
- Issue-only attachment archives and reports embed even without attachment
  entries.
- No camera-specific matrix table, ICC-name inference, advertised-format
  fallback, or temporal carry-forward into AVIF interpretation is added.

A future compatibility profile needs evidence for backend, mode, OS, device
revision, delivered color tags/profile and conversion behavior. USB VID/PID is
sufficient for an identity lookup, not for image color interpretation.

## Reproduction and primary references

The opt-in probe requires an explicit UID, refuses busy cameras, records only
metadata, and does not select formats or request output color overrides:

```sh
swift build --product HardwareProbe
.build/debug/HardwareProbe --color-metadata --device-uid '<AVFoundation UID>' --backend cmio --frames 120
.build/debug/HardwareProbe --color-metadata --device-uid '<AVFoundation UID>' --backend avfoundation --frames 120
```

An AVFoundation session can itself negotiate shared device configuration even
with empty output settings; the probe reports before/after stream geometry.

- [USB-IF UVC 1.1](https://www.usb.org/sites/default/files/USB_Video_Class_1_1_090711.zip), section 3.9.2.6/Table 3-18.
- [USB-IF UVC 1.5](https://www.usb.org/sites/default/files/USB_Video_Class_1_5.zip), section 3.9.2.6.
- [Apple YCbCr attachment](https://developer.apple.com/documentation/corevideo/kcvimagebufferycbcrmatrixkey).
- [Apple native-format settings](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/videosettings).
- [Apple video color tagging](https://developer.apple.com/documentation/avfoundation/tagging-media-with-video-color-information).
- [Apple format/image-buffer extension agreement](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptiongetextensionkeyscommonwithimagebuffers()).
- [libavif CICP and ICC](https://github.com/AOMediaCodec/libavif/wiki/CICP).

Raw local logs, descriptor bytes and temporary probes are under
`/private/tmp/pixelbooth-capture-review`; they are not bundled with the app.

## Validation of the change

- `scripts/validate.sh`: strict recursive Swift format/lint, debug application
  and test-runner builds, 201 Swift tests and 17 Python tests passed.
- `swift build --product HardwareProbe`: passed. Both checked-in diagnostic
  backends read 120 frames successfully on this Brio; malformed/missing UID
  arguments refused activation. These final current-mode runs reported BT.709.
- A separate live production-backend check of the new tracker read 90 actual
  4096×2160 frames. Frame 1 retained its BT.601 observation; frames 2–90 carried
  a second, separate missing-tag observation, with no per-frame substitution.
  Original 1080p/approximately 24-fps configuration was restored, stream stopped.
- `scripts/build_app.sh` and `codesign --verify --deep --strict
  build/PixelBooth.app`: passed for the arm64, macOS 27 application bundle.
- `git diff --check`: passed. Captures 5 and 6 retained their original hashes.
- Live Photos import, Photos original-resource equality, UI interactions and
  calibrated physical color accuracy were not tested by this investigation.
