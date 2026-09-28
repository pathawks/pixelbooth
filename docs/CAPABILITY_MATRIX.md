# Supported formats and capability matrix

Legend: ✅ verified by automated tests · 🧪 hardware-dependent (listed "Not run"
until run on hardware) · ❌ explicitly rejected (never silently converted)

## Final outputs (settled)

| Output | Status | Evidence |
|--------|--------|----------|
| JPEG (passthrough) | ✅ pipeline + tests | Segment-level byte exactness through metadata-only insertion (`JPEGAndAVIFSuites.swift`) |
| AVIF (lossless) | ✅ | libavif 1.3.0 + libaom 3.13.1, quality 100, speed 0; exact native-channel decode-compare (smoke + `AVIFRoundTripTests` section of the runner) |
| HEIC | — excluded by product decision; never an output | — |

## Input representations

| FourCC | Layout | Depth | Archival path | Status |
|--------|--------|-------|---------------|--------|
| `MJPG` | Motion-JPEG | 8 | JPEG passthrough (byte-exact markers/tables/scan) | 🧪 adapter tests pass; live-camera capture pending hardware |
| `NV12`, `420v`, `420f` | bi-planar YUV 4:2:0 8-bit | 8 | deinterleave → lossless AVIF | ✅ round-trip tests (full + limited range) |
| `2yuv` (YUY2) | packed 4:2:2 8-bit | 8 | deinterleave → lossless AVIF | ✅ adapter tests pass |
| `yuvs` (UYVY) | packed 4:2:2 8-bit | 8 | deinterleave → lossless AVIF | ✅ adapter tests pass |
| `BGRA` | 32-bit with meaningful alpha | 8 | G,B,R planes + alpha plane → lossless AVIF | ✅ adapter tests pass |
| `BGR3` (BGR24) | packed 24-bit RGB | 8 | identity-RGB 4:4:4 → lossless AVIF | ✅ adapter + round-trip tests pass |
| `v210` (10-bit bi-planar YUV) | bi-planar 10-bit 4:2:0 | 10 | repack → lossless AVIF | ✅ adapter test passes (when camera exposes it) |
| `avc1` (H.264) | encoded stream | — | VideoToolbox decode → lossless AVIF; source never stored | 🧪 pending hardware |
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
| `macDeliveredUnknownUpstream` | upstream unestablishable | explicit user acknowledgment required; never silently substituted |

## Honest notes

- No claim in this matrix is accepted from documentation alone: lossless
  claims are verified by encoding fixtures and comparing native-channel
  samples after decoding.
- Live-camera and Photos integration rows remain "Not run" until executed on
  hardware with the required TCC permissions; see `docs/MANUAL_TEST_PLAN.md`.
  They are never counted as passed.
