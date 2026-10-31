# Camera metadata mapping

## PixelBooth implementation

PixelBooth collects optical values from delivered sample and image attachments,
including nested `MetadataDictionary` values. Generated Exif uses valid positive
reported values; the original attachment archive and provenance remain separate.
Existing source Exif continues to take precedence.

USB control observations run independently after streaming starts. Failed or
unavailable reads do not delay warm-up or the shutter. Results belong to a
specific device and configuration generation; delayed results from an obsolete
configuration are discarded. These observations are timestamped host readings,
not proof of the settings used for a particular exposure.

Exposure time is encoded as a rational with enough precision for UVC's
100-microsecond units. Priority exposure modes retain their original UVC value
in application XMP and use the standard automatic Exif `ExposureMode` value.
`BodySerialNumber` is written in the Exif sub-IFD, and 35-mm-equivalent focal
length uses `FocalLengthIn35mmFilm` (`0xA405`). Captures staged before these
metadata additions remain decodable for recovery.

The sections below retain the source research and neighboring-tool comparison;
they do not establish live-camera or Photos compatibility for PixelBooth.

## UVC mapping research

Candidate mappings for values exposed by CameraController's UVC controls.
Availability and trustworthy reporting depend on the camera.

| Camera value | Sensible metadata |
|---|---|
| Exposure time | Exif `ExposureTime`, converting UVC's 100-microsecond units to seconds |
| Exposure mode | Exif `ExposureMode` where applicable; preserve the complete UVC mode in XMP |
| White balance auto/manual | Exif `WhiteBalance` |
| White balance temperature | Application XMP, in Kelvin |
| Autofocus enabled | Application XMP; this describes the mode, not whether focus succeeded |
| Absolute focus | Application XMP; potentially Exif `SubjectDistance` when its distance reporting is trustworthy |
| Iris/aperture | Exif `FNumber`, when supported and valid |
| Gain, contrast, saturation, sharpness, gamma, backlight compensation | Application XMP with raw values and documented units/ranges |

UVC defines absolute focus as distance to the focused target in millimeters;
Exif `SubjectDistance` uses meters. Focus settings cannot supply `FocalLength`.
Gain cannot supply ISO, and raw contrast or sharpness values cannot be copied
directly into Exif's categorical tags.

Retain the device, raw value, units, and observation time for control reads.
Label them as host observations unless their association with the saved frame
is established. Preserve existing camera-supplied metadata and conflicting
observations separately.

## Additional values retained by `capture`

The neighboring `capture` CLI also retains the following values from
AVFoundation, frame attachments, and matched USB descriptors. These describe
its current implementation, not mappings already implemented in PixelBooth.
In particular, PixelBooth's attachment archive does not make an archived value
available as a standard Exif field.

| Source value | Metadata written by `capture` | Mapping considerations |
|---|---|---|
| Frame `MetadataDictionary.Fnumber` | Exif `FNumber` | Use a finite positive value associated with the accepted frame; do not infer aperture from unrelated controls |
| Frame `MetadataDictionary.FocalLength` | Exif `FocalLength` | Preserve a reported focal length; focus position is not a substitute |
| Frame `MetadataDictionary.FocalLenIn35mmFilm` | Exif `FocalLengthIn35mmFilm` | `capture` rounds a finite nonnegative value to an unsigned 16-bit integer; retain the original observation separately |
| Matched USB serial string | Exif `BodySerialNumber` | A host-observed USB device serial is not necessarily a camera-reported body serial; retain its source and association evidence |
| AVFoundation manufacturer | Exif `Make`, XMP `tiff:Make` | Host-observed device identity; omit placeholders from generated Exif |
| Matched USB product string, falling back to AVFoundation localized name | Exif `Model`, XMP `tiff:Model` | Preserve the raw names and the identity-resolution source separately |
| AVFoundation localized name, model ID, unique ID, and device type | Application XMP | Preserve these as distinct device observations rather than treating a model ID as a model name |
| Accepted frame width and height | Exif `PixelXDimension`, `PixelYDimension` | Describe the saved primary image dimensions |
| Media presentation time correlated with the host clock | Exif capture/digitization timestamps, timezone offsets, millisecond subseconds, and XMP `CreateDate` | Host-correlated frame time is not sensor exposure time; preserve the clock correlation and justified precision |
| Valid positive sample duration | Application XMP `FrameDuration` | Duration of the accepted sample, not a measured frame-rate claim |
| Delivered pixel format and layout range | Application XMP `PixelFormat`, `VideoRange` | Keep delivered representation separate from the selected device format |
| Public AVFoundation effect indicators | Application XMP `ActiveEffects` | `capture` records active Center Stage, Portrait, Studio Light, and Background Replacement effects observed before acquisition; this is not a per-frame observation |
| AVFoundation `hasFlash == false` | Exif `Flash = 0x0020` (no flash function) | Device capability is not evidence of whether a flash fired for a particular frame |
| Configured warm-up frame count | Application XMP `WarmupFrames` | Application policy, not camera metadata or proof that AE/AF/AWB settled |
| Tool identity | Exif `Software`, XMP `CreatorTool` | Application-generated metadata; `capture` also writes Exif version `0232` |

`capture` also serializes propagating sample-buffer and image-buffer attachments
into application XMP under `urn:capture:ns:1.0`. The sample attachments include
the sensor metadata dictionary; its duplicate is removed from the image
attachments. Its serializer supports dictionaries, arrays, booleans, numbers,
and nonempty strings, but omits unsupported object types and dictionary keys
that are not valid XML names. This is not an exact attachment archive and does
not preserve embedded source Exif/XMP packets as original packets.

For color interpretation, `capture` maps selected-format primaries, transfer
function, and YCbCr matrix into AVIF CICP fields and writes full/limited range
from the pixel layout. Unrecognized color tags become unspecified. PixelBooth
must continue to resolve delivered color evidence and reject an unfaithful
export rather than adopt that fallback.

Implementation references in the neighboring checkout:

- `/Users/phawks/github/capture/Sources/capture/Metadata.swift`: frame observations, Exif fields,
  XMP fields, and attachment serialization
- `/Users/phawks/github/capture/Sources/capture/USB.swift`: USB descriptor association by location,
  vendor, and product IDs
- `/Users/phawks/github/capture/Sources/capture/Camera.swift`: accepted-frame copying and public
  effect observations
- `/Users/phawks/github/capture/Sources/capture/Avif.swift`: color-tag mapping and AVIF range

Sources:

- [CameraController control definitions](https://github.com/itaybre/CameraController/blob/5cc4a67cf7be2442937bf43f89d5d317039faf2c/UVC/Models/UVCDeviceProperties.swift#L43-L71)
- [UVC 1.5 specification](https://forums.adug.org.au/uploads/short-url/ig1j25sqsBdPWvS8gAD62hF6ysB.pdf)
- [Exif field meanings](https://github.com/adobe/xmp-docs/blob/e2573ad7e7959e657b1aed704546e19319cb4f5d/XMPNamespaces/exif.md)
