using PixelBooth.Core.Capture;
using Windows.Graphics.Imaging;
using Windows.Security.Cryptography;

/// <summary>
/// Opt-in diagnostic: compare Windows' SoftwareBitmap conversion with simple
/// chroma reconstruction models, then exercise it on a camera-delivered frame.
/// This is not a test of the camera's physical sampling position.
/// </summary>
internal static class Yuy2Probe
{
    private const int Width = 64;
    private const int Height = 8;
    private const byte Low = 96;
    private const byte High = 160;

    public static async Task RunAsync(bool preferBrio)
    {
        Console.WriteLine($"Windows: {Environment.OSVersion.Version}");
        Console.WriteLine("Path: Media Foundation source reader -> YUY2 SoftwareBitmap -> Windows SoftwareBitmap.Convert(BGRA8)");
        Console.WriteLine("SoftwareBitmap.Convert receives pixel bytes but not the camera's Media Foundation color attributes.");
        var low = Convert(Fill(_ => Low), Width, Height);
        var high = Convert(Fill(_ => High), Width, Height);
        var pattern = Convert(Fill(pair => pair % 8 < 4 ? Low : High), Width, Height);
        Console.WriteLine($"Synthetic constant-color anchors, BGRA: low=({Pixel(low, 4)}) high=({Pixel(high, 4)})");
        Console.WriteLine($"Synthetic edge, blue values at columns 4–19: {string.Join(",", Enumerable.Range(4, 16).Select(x => pattern[x * 4]))}");
        foreach (var model in new[] { "co-sited linear", "centered linear", "nearest pair" })
        {
            double error = 0;
            int count = 0;
            for (var x = 2; x < Width - 2; x++)
            {
                double Value(int pair) => pair % 8 < 4 ? 0 : 1;
                var pair = x / 2;
                var weight = model switch
                {
                    "co-sited linear" => x % 2 == 0 ? Value(pair) : (Value(pair) + Value(pair + 1)) / 2,
                    "centered linear" => x % 2 == 0 ? .25 * Value(pair - 1) + .75 * Value(pair) : .75 * Value(pair) + .25 * Value(pair + 1),
                    _ => Value(pair)
                };
                for (var c = 0; c < 3; c++)
                {
                    var expected = low[x * 4 + c] * (1 - weight) + high[x * 4 + c] * weight;
                    error += Math.Abs(pattern[x * 4 + c] - expected);
                    count++;
                }
            }
            Console.WriteLine($"Synthetic {model} mean absolute RGB error: {error / count:F3} of 255");
        }

        var devices = MediaFoundationCamera.Discover();
        var device = preferBrio ? devices.FirstOrDefault(d => d.Name.Contains("BRIO", StringComparison.OrdinalIgnoreCase)) : devices.FirstOrDefault();
        if (device is null) { Console.WriteLine("NOT RUN: requested camera is unavailable."); return; }
        CameraMode selectedMode;
        using (var camera = new MediaFoundationCamera())
        {
            var mode = camera.Open(device).Where(m => m.FourCC == "YUY2" && m.Width == 640 && m.Height == 480)
                .OrderByDescending(m => m.FramesPerSecond).FirstOrDefault();
            if (mode is null) { Console.WriteLine($"NOT RUN: {device.Name} has no 640×480 YUY2 mode."); return; }
            selectedMode = camera.SetMode(mode);
            CameraFrame? frame = null;
            for (var i = 0; i < 10; i++) frame = camera.Read(device, mode, 1) ?? frame;
            if (frame is null) throw new InvalidOperationException("The camera did not deliver a frame.");
            if (frame.Bytes.Length != checked(mode.Width * mode.Height * 2)) throw new InvalidDataException("Unexpected YUY2 buffer size or stride.");
            var rgb = Convert(frame.Bytes, mode.Width, mode.Height);
            Console.WriteLine($"Source reader camera: {device.Name}; {mode}; {frame.Bytes.Length} YUY2 bytes -> {rgb.Length} BGRA bytes.");
            Console.WriteLine($"Media Foundation source attributes: matrix={mode.Matrix}, range={mode.NominalRange}, chroma_siting={mode.ChromaSiting}.");
        }
        try { await MediaCaptureYuy2Probe.RunAsync(device, selectedMode); }
        catch (Exception e) { Console.WriteLine($"NOT RUN: MediaCapture frame comparison: {e.GetType().Name}: {e.Message} (0x{e.HResult:X8})"); }
        Console.WriteLine("No camera images were saved.");
    }

    private static byte[] Fill(Func<int, byte> chroma)
    {
        var data = new byte[Width * Height * 2];
        for (var y = 0; y < Height; y++)
        for (var pair = 0; pair < Width / 2; pair++)
        {
            var index = y * Width * 2 + pair * 4;
            data[index] = 128; data[index + 1] = chroma(pair); data[index + 2] = 128; data[index + 3] = 128;
        }
        return data;
    }

    internal static byte[] Convert(byte[] yuy2, int width, int height)
    {
        using var source = SoftwareBitmap.CreateCopyFromBuffer(CryptographicBuffer.CreateFromByteArray(yuy2), BitmapPixelFormat.Yuy2, width, height);
        using var result = SoftwareBitmap.Convert(source, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
        var buffer = new Windows.Storage.Streams.Buffer(checked((uint)(width * height * 4)));
        result.CopyToBuffer(buffer);
        CryptographicBuffer.CopyToByteArray(buffer, out var bytes);
        return bytes;
    }

    private static string Pixel(byte[] bgra, int x) => string.Join(",", bgra.AsSpan(x * 4, 4).ToArray());
}
