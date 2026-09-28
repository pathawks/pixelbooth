# Supported formats and capability matrix

Legend: ✅ the production adapter-to-snapshot-to-archive path has synthetic
native-sample tests · 🧪 implemented or hardware-dependent, but acceptance is
not complete · ❌ no archival adapter (the capture is retained and the failure
is shown; samples are never silently converted)

## Final outputs (settled)

| Output | Status | Evidence |
|--------|--------|----------|
| JPEG (passthrough) | ✅ pipeline + tests | Segment-level byte exactness through metadata-only insertion (`JPEGAndAVIFSuites.swift`) |
| AVIF (lossless) | ✅ | libavif 1.3.0 + libaom 3.13.1, quality 100, speed 0; exact native-channel decode-compare (smoke + `AVIFRoundTripTests` section of the runner) |
| HEIC | — excluded by product decision; never an output | — |

## Input representations

| FourCC | Layout | Depth | Archival path | Status |
|--------|--------|-------|---------------|--------|
| `jpeg`, `dmb1`, `MJPG` | JPEG / Motion-JPEG | bitstream | JPEG passthrough (coding bytes preserved; metadata-only additions) | ✅ real CoreMedia sample-buffer path and decodable baseline/progressive fixtures |
| `NV12`, `420v`, `420f` | bi-planar YUV 4:2:0 8-bit | 8 | deinterleave → lossless AVIF | ✅ round-trip tests (full + limited range) |
| `2vuy` (UYVY) | packed 4:2:2 8-bit | 8 | deinterleave → lossless AVIF | ✅ adapter tests pass |
| `yuvs` (YUY2) | packed 4:2:2 8-bit | 8 | deinterleave → lossless AVIF | ✅ adapter tests pass |
| `BGRA` | 32-bit with meaningful alpha | 8 | G,B,R planes + alpha plane → lossless AVIF | ✅ adapter tests pass |
| `24BG` (BGR24), `24RGB` | packed 24-bit RGB | 8 | identity-RGB 4:4:4 → lossless AVIF | ✅ production packed adapter, persisted snapshot, and exact AVIF channels tested; live pixel-buffer delivery not run |
| `x420`, `xf20` | bi-planar YUV 4:2:0 | 10 | MSB-aligned unpack → lossless AVIF | ✅ padded multirow adapter, JSON persistence, and exact native-channel AVIF round trip |
| `v210` | packed 10-bit YUV 4:2:2 | 10 | no current archival adapter | ❌ explicitly unarchivable; not bi-planar and not tested as supported |
| `x422`, `xf22`, `x444`, `xf44`, `y420` | other YUV layouts | varies | no current archival adapter | ❌ classified for selection/fidelity facts, but not routed to the archival path |
| `avc1` (H.264) | encoded stream | — | VideoToolbox decode → reconstructed native-plane snapshot → lossless AVIF; compressed source is not archived | 🧪 implementation and encoded fixture exist; this host returns `kVTVideoDecoderMalfunctionErr (-12911)` while creating the VideoToolbox session, so end-to-end acceptance is not verified |
| Unknown/interlaced/Bayer/FP layouts | — | — | rejected with explicit error | ❌ by contract |

## Readiness heuristic (product defaults, not camera claims)

| Parameter | Default | Configurable |
|-----------|---------|--------------|
| Minimum fresh valid frames | 8 | yes (Settings > advanced) |
| Minimum ms since valid streaming began | 500 | yes |
| Maximum adjusting wait | 5 s, then "Still adjusting" + explicit capture override | yes |

## Acquisition-fidelity classification

| Class | Meaning | Evidence required |
|-------|---------|-------------------|
| `nativePreserved` | Camera and AVFoundation both deliver the native representation | matching format FourCC + non-empty confirmed-delivery videoSettings + inspected sample buffers |
| `macDeliveredConverted` | macOS performed a known conversion | delivered format ≠ camera format |
| `macDeliveredUnknownUpstream` | upstream unestablishable | recorded as unknown provenance; never labeled native; does not block capture |

## Honest notes

- No claim in this matrix is accepted from documentation alone: lossless
  claims are verified by encoding fixtures and comparing native-channel
  samples after decoding.
- Layout facts and adapter availability are separate: the shared FourCC model
  describes known formats, while `PixelFormatFourCC.nativePlaneFormats` is the
  exact list routed through production archival adapters.
- Live-camera and Photos integration rows remain "Not run" until executed on
  hardware with the required TCC permissions; see `docs/MANUAL_TEST_PLAN.md`.
  They are never counted as passed.
