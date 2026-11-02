using PixelBooth.Core.Capture;

namespace PixelBooth.Core.Imaging;

/// <summary>Rearranges 8-bit, contiguous Media Foundation YUV samples without color conversion.</summary>
public sealed record RawPlanes(int Width, int Height, int Chroma, byte[] Y, byte[] Cb, byte[] Cr)
{
    public int ChromaWidth => Width / 2;
    public int ChromaHeight => Chroma == 1 ? Height / 2 : Height;

    public static void ValidateMode(CameraMode m)
    {
        if (m.InterlaceMode != 2) throw new InvalidDataException("Only explicitly progressive raw frames are supported.");
        if (m.Width <= 0 || m.Height <= 0 || m.Width > 16384 || m.Height > 16384 || (m.Width & 1) != 0)
            throw new InvalidDataException("Unsupported raw image dimensions.");
        if (m.FourCC == "NV12" && (m.Height & 1) != 0) throw new InvalidDataException("NV12 requires an even height.");
        if (m.FourCC is not ("NV12" or "YUY2")) throw new InvalidDataException("This raw pixel layout is not supported.");
        var rowSize = checked(m.Width * (m.FourCC == "NV12" ? 1 : 2));
        if (m.Stride is not null && m.Stride != rowSize)
            throw new InvalidDataException("The camera's reported stride is not a supported tightly packed layout.");
    }

    public static RawPlanes FromFrame(CameraFrame frame)
    {
        var m = frame.Mode;
        ValidateMode(m);
        var chroma = m.FourCC == "NV12" ? 1 : 2;
        var pixels = checked(m.Width * m.Height);
        var samples = chroma == 1 ? pixels / 4 : pixels / 2;
        var expected = checked(pixels + 2 * samples);
        if (frame.Bytes.Length != expected) throw new InvalidDataException("The raw buffer layout or stride is ambiguous.");
        var y = new byte[pixels]; var cb = new byte[samples]; var cr = new byte[samples];
        if (chroma == 1)
        {
            Buffer.BlockCopy(frame.Bytes, 0, y, 0, pixels);
            for (int i = 0; i < samples; i++) { cb[i] = frame.Bytes[pixels + 2 * i]; cr[i] = frame.Bytes[pixels + 2 * i + 1]; }
        }
        else
        {
            for (int i = 0; i < samples; i++)
            {
                y[2 * i] = frame.Bytes[4 * i]; cb[i] = frame.Bytes[4 * i + 1];
                y[2 * i + 1] = frame.Bytes[4 * i + 2]; cr[i] = frame.Bytes[4 * i + 3];
            }
        }
        return new RawPlanes(m.Width, m.Height, chroma, y, cb, cr);
    }
}
