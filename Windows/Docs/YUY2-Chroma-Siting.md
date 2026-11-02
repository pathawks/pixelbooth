# YUY2 chroma siting: evidence for the Windows implementation

PixelBooth currently treats supported YUY2 input as horizontally co-sited:
each Cb/Cr pair is interpreted at the position of the first Y sample in the
pair. This is an application policy, not a measurement of a camera's internal
signal processing. The original Media Foundation flag and the policy are
recorded separately in XMP. No chroma samples are resampled during encoding.

## Observations from the BRIO

For the tested Logitech BRIO, USB vendor/product ID `046d:085e`, a USBPcap
trace identified an uncompressed YUY2 format at 640 × 480 and 30 fps. The
camera's video-control descriptor reports `bcdUVC = 0x0100` and its YUY2
format descriptor declares 16 bits per pixel (8 bits per component with 4:2:2
sampling). After UVC headers were removed, all 60 recorded Media Foundation
frame hashes matched 60 consecutive reconstructed USB frame hashes. That
observation applies only to the tested device, mode, and run.

The YUY2 color-matching descriptor was `06 24 0d 01 01 04`: primaries 1
(BT.709/sRGB), transfer 1 (BT.709), and matrix 4 (SMPTE 170M, with BT.601
matrix coefficients). The standard color-matching descriptor contains those
three color fields and no chroma-position field; see Microsoft's [USBView
descriptor definition](https://github.com/microsoft/Windows-driver-samples/blob/main/usb/usbview/uvcdesc.h)
and the [UVC color definitions](https://github.com/torvalds/linux/blob/master/include/uapi/linux/usb/video.h).

Media Foundation reported `MF_MT_VIDEO_CHROMA_SITING = 6` (`0x6`) for the
tested mode. It includes the `0x4` horizontally co-sited and `0x2` vertically
co-sited bits, but omits the separate `0x1` bit for vertical alignment of the
two chroma planes. The observation is from Media Foundation; its ultimate
source in the camera, driver, or Windows has not been established. See the
[Microsoft flag definitions](https://learn.microsoft.com/en-us/windows/win32/api/mfobjects/ne-mfobjects-mfvideochromasubsampling).

## Documentation and limits

- The public [Logitech BRIO datasheet](https://www.logitech.com/content/dam/logitech/vc/en/pdf/brio-datasheet.pdf)
  describes UVC support but does not specify the BRIO's YUY2 chroma position.
- Microsoft describes 4:2:2 as co-sited in its [Media Foundation flag
  documentation](https://learn.microsoft.com/en-us/windows/win32/api/mfobjects/ne-mfobjects-mfvideochromasubsampling).
  An [ITU-T supplement](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.Sup19-202104-I%21%21PDF-E&lang=e&type=items)
  states that the BT.601, BT.709, BT.2020, and BT.2100 signal recommendations
  specify co-sited 4:2:2. These support the policy, but do not document the
  BRIO's internal implementation.
- In a [UVC device implementation note](https://www.infineon.com/assets/row/public/documents/24/42/infineon-implementing-a-usb-video-and-audio-composite-device-using-ez-usb-fx20-fx10-fx5n-fx5-controller-applicationnotes-en.pdf),
  Infineon describes YUY2 chroma as sampled at even pixels. This is a UVC
  example, not a Logitech specification.
- The Linux [V4L2 packed-YUV documentation](https://docs.kernel.org/userspace-api/media/v4l/pixfmt-packed-yuv.html)
  describes YUYV, which has the same component order, as horizontally
  interstitial. That documents a different API convention; it does not prove
  that the BRIO's output is centered. Component packing alone should not be
  treated as independent proof of position.

AV1 does not carry `chroma_sample_position` in a 4:2:2 bitstream; see the
[libavif decoder implementation](https://aomedia.googlesource.com/libavif/+/a3e97630b618dec0278382fe8a5b4e8a023fbc40/src/read.c).
PixelBooth's co-sited interpretation is documented in its application XMP,
which other viewers may not interpret.

An authoritative BRIO-specific answer would require Logitech to document
whether the camera's native UVC YUY2 output places Cb and Cr at even luma
sample positions or midway between them, and whether that holds across modes
and firmware versions. The USB hash comparison establishes sample delivery
for the tested run; it cannot answer that chroma-position question.
