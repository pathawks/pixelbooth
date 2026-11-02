using System.Security.Cryptography;
using PixelBooth.Core.Capture;

/// <summary>
/// Hash native Media Foundation frames while an independent USB capture is
/// running. The hashes allow comparison without saving a second copy of the
/// camera frames. They do not establish USB-level identity on their own.
/// </summary>
internal static class UvcReferenceProbe
{
    public static void Run(string[] args)
    {
        var framesArgument = Array.IndexOf(args, "--frames");
        var count = framesArgument < 0 ? 60 : framesArgument + 1 < args.Length && int.TryParse(args[framesArgument + 1], out var parsed)
            ? parsed : throw new ArgumentException("--frames requires a frame count.");
        if (count is < 8 or > 240) throw new ArgumentOutOfRangeException(nameof(args), "The frame count must be between 8 and 240.");

        var devices = MediaFoundationCamera.Discover();
        var device = args.Contains("--brio")
            ? devices.FirstOrDefault(d => d.Name.Contains("BRIO", StringComparison.OrdinalIgnoreCase))
            : devices.FirstOrDefault();
        if (device is null) throw new InvalidOperationException("The requested camera is not available.");

        using var camera = new MediaFoundationCamera();
        var mode = camera.Open(device).Where(m => m.FourCC == "YUY2" && m.Width == 640 && m.Height == 480)
            .OrderByDescending(m => m.FramesPerSecond).FirstOrDefault()
            ?? throw new InvalidOperationException("The camera does not offer 640×480 YUY2.");
        mode = camera.SetMode(mode);
        Console.WriteLine($"Media Foundation source: {device.Name}; {mode}");
        Console.WriteLine($"Color: matrix={mode.Matrix}, range={mode.NominalRange}, chroma_siting={mode.ChromaSiting}");
        Console.WriteLine("Frame hashes cover delivered YUY2 bytes, excluding USB payload headers.");
        var complete = 0;
        var attempts = 0;
        while (complete < count && attempts < (count + 10) * 3)
        {
            var frame = camera.Read(device, mode, 1);
            attempts++;
            if (frame is null) continue;
            if (attempts <= 10) continue;
            if (frame.Bytes.Length != checked(mode.Width * mode.Height * 2))
                throw new InvalidDataException($"Unexpected YUY2 sample size {frame.Bytes.Length}; cannot make an exact comparison.");
            var hash = Convert.ToHexString(SHA256.HashData(frame.Bytes));
            Console.WriteLine($"frame={complete} timestamp100ns={frame.MediaTimestamp100ns} bytes={frame.Bytes.Length} sha256={hash}");
            complete++;
        }
        if (complete != count) throw new InvalidOperationException($"Only {complete} of {count} requested frames arrived.");
        Console.WriteLine($"Completed {complete} frame hashes.");
    }
}
