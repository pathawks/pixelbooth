// C module exposing the pinned libavif 1.3.0 API surface that PixelBooth uses.
#ifndef PIXELBOOTH_CAVIF_SHIM_H
#define PIXELBOOTH_CAVIF_SHIM_H

#include <avif/avif.h>
#include <stdbool.h>

/// Returns the pinned libavif version string, e.g. "1.3.0".
const char *pixelbooth_avif_version(void);

/// Returns the actual codec used by an encoder after `avifEncoderWrite`,
/// for verification that AOM was selected (never auto-substituted).
const char *pixelbooth_avif_encoder_codec_name(avifEncoder *encoder);

/// Applies preview mirroring with ObjC exception safety (see MirroringShim.m).
/// `layer` must be the AVCaptureVideoPreviewLayer instance.
/// Returns true when the mirroring value was applied (or already matched).
bool pixelbooth_apply_preview_mirroring(void *layer, bool mirrored);

/// Reports whether the preview layer's session is currently running.
bool pixelbooth_preview_session_running(void *layer);

#endif // PIXELBOOTH_CAVIF_SHIM_H

