#include "PixelBoothCAvif.h"

const char *pixelbooth_avif_version(void) {
  return avifVersion();
}

const char *pixelbooth_avif_encoder_codec_name(avifEncoder *encoder) {
  if (!encoder) return NULL;
  switch (encoder->codecChoice) {
    case AVIF_CODEC_CHOICE_AOM: return "aom";
    case AVIF_CODEC_CHOICE_RAV1E: return "rav1e";
    case AVIF_CODEC_CHOICE_SVT: return "svt";
    case AVIF_CODEC_CHOICE_DAV1D: return "dav1d";
    case AVIF_CODEC_CHOICE_LIBGAV1: return "libgav1";
    case AVIF_CODEC_CHOICE_AVM: return "avm";
    case AVIF_CODEC_CHOICE_AUTO:
    default: return "auto";
  }
}
