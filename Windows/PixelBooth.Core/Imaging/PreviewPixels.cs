using PixelBooth.Core.Capture;

namespace PixelBooth.Core.Imaging;

/// <summary>Display-only conversion. These pixels are never used for saving.</summary>
public static class PreviewPixels
{
    public static byte[] ToBgra(CameraFrame frame)
    {
        if (frame.Mode.FourCC == "NV12") return Nv12ToBgra(frame);
        var planes = RawPlanes.FromFrame(frame);
        var m = frame.Mode;
        var result = new byte[checked(planes.Width * planes.Height * 4)];
        var limited = m.NominalRange == 2;
        var bt709 = m.Matrix == 1;
        for (var row = 0; row < planes.Height; row++)
        for (var col = 0; col < planes.Width; col++)
        {
            var chromaRow = planes.Chroma == 1 ? row / 2 : row;
            var chroma = chromaRow * planes.ChromaWidth + col / 2;
            var y = (double)planes.Y[row * planes.Width + col];
            var cb = (double)planes.Cb[chroma] - 128;
            var cr = (double)planes.Cr[chroma] - 128;
            if (limited) { y = (y - 16) * (255.0 / 219); cb *= 255.0 / 224; cr *= 255.0 / 224; }
            var r = y + (bt709 ? 1.5748 : 1.402) * cr;
            var g = y - (bt709 ? 0.1873 : 0.344136) * cb - (bt709 ? 0.4681 : 0.714136) * cr;
            var b = y + (bt709 ? 1.8556 : 1.772) * cb;
            var offset = (row * planes.Width + col) * 4;
            result[offset] = Clamp(b); result[offset + 1] = Clamp(g); result[offset + 2] = Clamp(r); result[offset + 3] = 255;
        }
        return result;
    }

    private static byte[] Nv12ToBgra(CameraFrame frame)
    {
        var mode = frame.Mode;
        RawPlanes.ValidateMode(mode);
        var pixelCount = checked(mode.Width * mode.Height);
        if (frame.Bytes.Length != checked(pixelCount + pixelCount / 2))
            throw new InvalidDataException("The raw buffer layout or stride is ambiguous.");
        var result = new byte[checked(pixelCount * 4)];
        var limited = mode.NominalRange == 2;
        var bt709 = mode.Matrix == 1;
        var yValues = new double[256];
        var cbValues = new double[256];
        var crValues = new double[256];
        for (var i = 0; i < 256; i++)
        {
            yValues[i] = limited ? (i - 16) * (255.0 / 219) : i;
            cbValues[i] = crValues[i] = limited ? (i - 128) * (255.0 / 224) : i - 128;
        }
        Parallel.For(0, mode.Height, new ParallelOptions { MaxDegreeOfParallelism = Math.Min(4, Environment.ProcessorCount) }, row =>
        {
            var yRow = row * mode.Width;
            var uvRow = pixelCount + (row / 2) * mode.Width;
            for (var col = 0; col < mode.Width; col += 2)
            {
                var cb = cbValues[frame.Bytes[uvRow + col]];
                var cr = crValues[frame.Bytes[uvRow + col + 1]];
                var red = (bt709 ? 1.5748 : 1.402) * cr;
                var greenCb = (bt709 ? 0.1873 : 0.344136) * cb;
                var greenCr = (bt709 ? 0.4681 : 0.714136) * cr;
                var blue = (bt709 ? 1.8556 : 1.772) * cb;
                for (var pixel = 0; pixel < 2; pixel++)
                {
                    var source = yRow + col + pixel;
                    var y = yValues[frame.Bytes[source]];
                    var offset = source * 4;
                    result[offset] = Clamp(y + blue);
                    result[offset + 1] = Clamp(y - greenCb - greenCr);
                    result[offset + 2] = Clamp(y + red);
                    result[offset + 3] = 255;
                }
            }
        });
        return result;
    }

    private static byte Clamp(double value) => (byte)Math.Clamp((int)Math.Round(value), 0, 255);
}
