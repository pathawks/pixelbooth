using System.Buffers.Binary;
using System.Text;
using System.Xml.Linq;
using MediaFoundation;
using PixelBooth.Core.Capture;
using PixelBooth.Core.Imaging;
using PixelBooth.Core.Storage;

if (args.Length > 1 && args[0] == "--uvc-analyze")
{
    UvcPcapAnalyzer.Run(args);
    return;
}

if (args.Contains("--uvc-reference"))
{
    UvcReferenceProbe.Run(args);
    return;
}

if (args.Contains("--yuy2-probe"))
{
    await Yuy2Probe.RunAsync(args.Contains("--brio"));
    return;
}

if (args.Contains("--camera-settings"))
{
    var devices = MediaFoundationCamera.Discover();
    var selectedDevice = args.Contains("--brio")
        ? devices.FirstOrDefault(d => d.Name.Contains("BRIO", StringComparison.OrdinalIgnoreCase))
        : devices.FirstOrDefault();
    if (selectedDevice is null) { Console.WriteLine("NOT RUN: requested camera not detected"); return; }
    using var camera = new MediaFoundationCamera();
    var modes = camera.Open(selectedDevice);
    var mode = modes.Where(m => m.Width == 640 && m.Height == 480 && (args.Contains("--mjpeg") ? m.IsMjpeg : m.IsRaw || m.IsMjpeg))
        .OrderBy(m => m.FourCC == "YUY2" ? 0 : m.FourCC == "NV12" ? 1 : 2).FirstOrDefault()
        ?? throw new InvalidOperationException("No supported 640x480 mode found for the settings probe.");
    mode = camera.SetMode(mode);
    CameraFrame? frame = null;
    for (var i = 0; i < 10; i++) frame = camera.Read(selectedDevice, mode, 1) ?? frame;
    if (frame is null) throw new InvalidOperationException("Camera did not deliver a frame.");
    var controls = camera.ReadControls();
    Console.WriteLine($"{selectedDevice.Name}: {controls.Status}; {controls.Values.Length} controls");
    foreach (var value in controls.Values)
        Console.WriteLine($"  {value.Name}: {value.Value} {value.Unit} flags={(value.Flags is { } flags ? $"0x{flags:X}" : "unavailable")} capabilities={(value.Capabilities is { } capabilities ? $"0x{capabilities:X}" : "unavailable")} at {value.ObservedAt:O}");
    Console.WriteLine($"Frame metadata values: {frame.FrameMetadata?.Values.Length ?? 0}");
    var observed = frame with { Controls = controls };
    var encoded = mode.IsMjpeg ? JpegPreserver.AddMetadata(observed, Guid.NewGuid()) :
        LosslessTiff.RequiresTiff(mode) ? LosslessTiff.Encode(observed, Guid.NewGuid()) : AvifEncoder.Encode(observed, Guid.NewGuid());
    var embedded = Encoding.UTF8.GetString(encoded);
    if (!embedded.Contains("ControlObservationSource") || (controls.Values.Length > 0 && !embedded.Contains(controls.Values[0].Name)))
        throw new Exception("The live camera controls were not embedded in the saved format.");
    if (mode.IsMjpeg && JpegPreserver.CanAddStandardMetadata(frame.Bytes))
    {
        var markerLength = BinaryPrimitives.ReadUInt16BigEndian(encoded.AsSpan(4, 2));
        var stripped = encoded.AsSpan(0, 2).ToArray().Concat(encoded.Skip(4 + markerLength)).ToArray();
        if (!stripped.SequenceEqual(JpegPreserver.Extract(frame.Bytes))) throw new Exception("Live JPEG bytes changed outside the added XMP marker.");
        Console.WriteLine("PASS live JPEG preserves the original camera JPEG outside the added XMP marker");
    }
    Console.WriteLine($"PASS live {mode.FourCC} image includes the settings snapshot; no photo file written");
    return;
}

if (args.Contains("--metadata-fixture"))
{
    var fixtureBytes = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "jpeg-progressive.jpg"));
    int fixtureWidth = 0, fixtureHeight = 0;
    for (var i = 0; i + 8 < fixtureBytes.Length; i++)
        if (fixtureBytes[i] == 0xff && fixtureBytes[i + 1] is 0xc0 or 0xc1 or 0xc2)
        { fixtureHeight = BinaryPrimitives.ReadUInt16BigEndian(fixtureBytes.AsSpan(i + 5, 2)); fixtureWidth = BinaryPrimitives.ReadUInt16BigEndian(fixtureBytes.AsSpan(i + 7, 2)); break; }
    var mode = new CameraMode(0, Guid.Empty, "MJPG", fixtureWidth, fixtureHeight, 30, 1, null, 2, 2, 5, 2, 1);
    var frame = new CameraFrame(new("fixture", "fixture"), mode, fixtureBytes, 0, DateTimeOffset.Now, 0, 1,
        FrameMetadata: new([new("ExposureTime100ns", "UInt64", "100000"), new("IsoSpeed", "UInt32", "400")]),
        Controls: new(DateTimeOffset.Now, DateTimeOffset.Now, [new("WhiteBalance", Guid.Empty, 7, 6500, 1, 3, DateTimeOffset.Now, "kelvin")], "Fixture"));
    var path = Path.Combine(Path.GetTempPath(), "pixelbooth-metadata-fixture-" + Guid.NewGuid().ToString("N") + ".jpg");
    File.WriteAllBytes(path, JpegPreserver.AddMetadata(frame, Guid.NewGuid()));
    Console.WriteLine(path);
    return;
}

if (args.Length == 2 && args[0] == "--windows-image-decode")
{
    var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(Path.GetFullPath(args[1]));
    using var stream = await file.OpenAsync(Windows.Storage.FileAccessMode.Read);
    var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(stream);
    using var bitmap = await decoder.GetSoftwareBitmapAsync();
    Console.WriteLine($"PASS Windows image decoder: {bitmap.PixelWidth}x{bitmap.PixelHeight}");
    return;
}

if (args.Contains("--yuy2-avif-fixture"))
{
    const int fixtureWidth = 128, fixtureHeight = 96;
    var source = new byte[fixtureWidth * fixtureHeight * 2];
    new Random(4226).NextBytes(source);
    var mode = new CameraMode(0, Guid.Empty, "YUY2", fixtureWidth, fixtureHeight, 30, 1, null, 2, 2, 5, 2, 2, null, 6);
    var frame = new CameraFrame(new CameraDevice("fixture", "fixture"), mode, source, 0, DateTimeOffset.Now, 0, 1);
    var prefix = Path.Combine(Path.GetTempPath(), "pixelbooth-yuy2-" + Guid.NewGuid().ToString("N"));
    File.WriteAllBytes(prefix + ".avif", AvifEncoder.Encode(frame, Guid.NewGuid()));
    File.WriteAllBytes(prefix + ".raw", source);
    Console.WriteLine(prefix);
    return;
}

if (args.Contains("--tiff-fixture"))
{
    foreach (var format in new[] { "NV12", "YUY2" })
    {
        const int fixtureWidth = 128, fixtureHeight = 96;
        var source = new byte[fixtureWidth * fixtureHeight * (format == "NV12" ? 3 : 4) / 2];
        new Random(7).NextBytes(source);
        var mode = new CameraMode(0, Guid.Empty, format, fixtureWidth, fixtureHeight, 30, 1, null, 2, 2, null, 2, 1, null, format == "NV12" ? 1 : 7);
        var frame = new CameraFrame(new CameraDevice("fixture", "fixture"), mode, source, 0, DateTimeOffset.Now, 0, 1);
        var output = LosslessTiff.Encode(frame, Guid.NewGuid());
        var path = Path.Combine(Path.GetTempPath(), "pixelbooth-" + format + ".tif");
        File.WriteAllBytes(path, output);
        File.WriteAllBytes(Path.Combine(Path.GetTempPath(), "pixelbooth-" + format + ".raw"), source);
        Console.WriteLine(path);
    }
    return;
}

if (args.Contains("--avc-fixture"))
{
    var input = File.ReadAllBytes(Path.Combine(Path.GetTempPath(), "pixelbooth-b024.264"));
    var picture = new H264AccessUnitCollector().Observe(input) ?? throw new Exception("No IDR picture found.");
    var mode = new CameraMode(0, Guid.Empty, "H264", picture.Width, picture.Height, 30, 1, null, 2, null, null, null, null);
    var frame = new CameraFrame(new CameraDevice("fixture", "fixture"), mode, input, 0, DateTimeOffset.Now, 0, 1);
    var output = AvciWriter.Write(picture, frame, Guid.NewGuid());
    HeifProbe.Inspect(output, picture.Width, picture.Height);
    using var platform = new MediaFoundationCamera();
    using var decoder = new H264PreviewDecoder(picture.Width, picture.Height);
    var decoded = decoder.Decode(input, 0, true) ?? throw new Exception("Windows H.264 decoder did not produce a frame.");
    File.WriteAllBytes(Path.Combine(Path.GetTempPath(), "pixelbooth-test.avci"), output);
    Console.WriteLine($"Parsed AVCI {picture.Width}x{picture.Height}, chroma={picture.Chroma}, depth={picture.LumaDepth}, bytes={output.Length}; decoded {decoded.Length} bytes");
    return;
}

if (args.Contains("--camera") || args.Contains("--camera-capture"))
{
    var devices = MediaFoundationCamera.Discover();
    if (devices.Count == 0) { Console.WriteLine("NOT RUN: no camera detected"); return; }
    foreach (var device in devices)
    {
        using var camera = new MediaFoundationCamera();
        var modes = camera.Open(device);
        Console.WriteLine($"{device.Name}: {modes.Count} native modes");
        if (args.Contains("--camera")) foreach (var mode in modes) Console.WriteLine($"  {mode} interlace={mode.InterlaceMode} primaries={mode.Primaries} transfer={mode.Transfer} matrix={mode.Matrix} range={mode.NominalRange} siting={mode.ChromaSiting}");
    }
    if (!args.Contains("--camera-capture")) return;
    var selectedDevice = args.Contains("--brio") ? devices.First(d => d.Name.Contains("BRIO", StringComparison.OrdinalIgnoreCase)) : devices[0];
    foreach (var format in new[] { "MJPG", "NV12", "YUY2" })
    {
        using var camera = new MediaFoundationCamera();
        var available = camera.Open(selectedDevice).Where(m => m.FourCC == format);
        if (args.Contains("--brio")) available = available.Where(m => m.Width == 640 && m.Height == 480);
        var mode = available.OrderByDescending(m => (long)m.Width * m.Height).ThenByDescending(m => m.FramesPerSecond).FirstOrDefault();
        if (mode is null) { Console.WriteLine($"NOT RUN: camera has no {format} mode"); continue; }
        camera.SetMode(mode);
        CameraFrame? frame = null;
        for (var i = 0; i < 10; i++) frame = camera.Read(selectedDevice, mode, 1) ?? frame;
        if (frame is null) throw new Exception("No frame arrived.");
        try
        {
            var encoded = format == "MJPG" ? JpegPreserver.AddMetadata(frame, Guid.NewGuid()) :
                LosslessTiff.RequiresTiff(mode) ? LosslessTiff.Encode(frame, Guid.NewGuid()) : AvifEncoder.Encode(frame, Guid.NewGuid());
            Console.WriteLine($"PASS camera {mode}: {frame.Bytes.Length} source bytes; {encoded.Length} output bytes");
        }
        catch (InvalidDataException e) { Console.WriteLine($"UNSUPPORTED camera {mode}: {e.Message}"); }
    }
    return;
}

var passed = 0;
var failed = 0;
async Task Test(string name, Func<Task> action)
{
    try { await action(); Console.WriteLine($"PASS {name}"); passed++; }
    catch (Exception e) { Console.WriteLine($"FAIL {name}: {e}"); failed++; }
}
void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
void Throws(Action action) { try { action(); } catch (Exception e) when (e is InvalidDataException or System.Xml.XmlException or JpegXmpEmbeddingException) { return; } throw new Exception("Expected invalid input to be rejected."); }
byte[] Segment(byte marker, byte[] payload)
{
    var result = new byte[payload.Length + 4]; result[0] = 0xff; result[1] = marker;
    BinaryPrimitives.WriteUInt16BigEndian(result.AsSpan(2), checked((ushort)(payload.Length + 2))); payload.CopyTo(result, 4); return result;
}
byte[] Insert(byte[] jpeg, params byte[][] segments) => jpeg.AsSpan(0, 2).ToArray().Concat(segments.SelectMany(x => x)).Concat(jpeg.Skip(2)).ToArray();
CameraFrame Frame(string format, int width, int height, byte[] data) => new(new CameraDevice("fixture-device", "Fixture camera"),
    new CameraMode(0, Guid.Empty, format, width, height, 30, 1, null, 2, 2, 5, 2, 1), data, 123, DateTimeOffset.Parse("2026-01-02T03:04:05-06:00"), 0, 1);

await Test("NV12 preview preserves display conversion and source bytes", () =>
{
    foreach (var range in new[] { 1, 2 })
    foreach (var matrix in new[] { 1, 2 })
    {
        const int width = 34, height = 18;
        var bytes = new byte[width * height * 3 / 2];
        new Random(42 + range * 10 + matrix).NextBytes(bytes);
        byte[] edges = [0, 1, 15, 16, 128, 235, 240, 254, 255];
        edges.CopyTo(bytes, 0);
        var frame = Frame("NV12", width, height, bytes);
        frame = frame with { Mode = frame.Mode with { NominalRange = range, Matrix = matrix } };
        var source = bytes.ToArray();
        var planes = RawPlanes.FromFrame(frame);
        var expected = new byte[width * height * 4];
        byte Clamp(double value) => (byte)Math.Clamp((int)Math.Round(value), 0, 255);
        for (var row = 0; row < height; row++)
        for (var col = 0; col < width; col++)
        {
            var y = (double)planes.Y[row * width + col];
            var chroma = row / 2 * planes.ChromaWidth + col / 2;
            var cb = (double)planes.Cb[chroma] - 128;
            var cr = (double)planes.Cr[chroma] - 128;
            if (range == 2) { y = (y - 16) * (255.0 / 219); cb *= 255.0 / 224; cr *= 255.0 / 224; }
            var offset = (row * width + col) * 4;
            expected[offset] = Clamp(y + (matrix == 1 ? 1.8556 : 1.772) * cb);
            expected[offset + 1] = Clamp(y - (matrix == 1 ? 0.1873 : 0.344136) * cb - (matrix == 1 ? 0.4681 : 0.714136) * cr);
            expected[offset + 2] = Clamp(y + (matrix == 1 ? 1.5748 : 1.402) * cr);
            expected[offset + 3] = 255;
        }
        Assert(PreviewPixels.ToBgra(frame).SequenceEqual(expected), "NV12 display conversion changed.");
        Assert(bytes.SequenceEqual(source), "Preview conversion changed the capture buffer.");
        Throws(() => PreviewPixels.ToBgra(frame with { Bytes = bytes[..^1] }));
        Throws(() => PreviewPixels.ToBgra(frame with { Mode = frame.Mode with { Stride = width + 2 } }));
    }
    return Task.CompletedTask;
});

await Test("USBPcap UVC analysis matches frames and rejects damaged packets", () =>
{
    var pixels = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();
    var reference = new UvcPcapAnalyzer.Reference(3, pixels.Length,
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(pixels)));
    byte[] Fixture(bool damaged)
    {
        var packets = new[]
        {
            new byte[] { 2, 2 },
            new byte[] { 2, 1 }.Concat(pixels.Take(8)).ToArray(),
            new byte[] { 2, 3 }.Concat(pixels.Skip(8)).ToArray()
        };
        using var usb = new MemoryStream();
        using (var writer = new BinaryWriter(usb, Encoding.UTF8, true))
        {
            writer.Write((ushort)(39 + packets.Length * 12)); writer.Write(0UL); writer.Write(0U); writer.Write((ushort)0);
            writer.Write((byte)1); writer.Write((ushort)5); writer.Write((ushort)1); writer.Write((byte)0x81); writer.Write((byte)0);
            writer.Write((uint)packets.Sum(p => p.Length)); writer.Write(0U); writer.Write((uint)packets.Length); writer.Write(0U);
            uint offset = 0;
            for (var i = 0; i < packets.Length; i++)
            {
                writer.Write(offset); writer.Write((uint)packets[i].Length); writer.Write(damaged && i == 2 ? 1U : 0U);
                offset += (uint)packets[i].Length;
            }
            foreach (var packet in packets) writer.Write(packet);
        }
        using var pcap = new MemoryStream();
        using (var writer = new BinaryWriter(pcap, Encoding.UTF8, true))
        {
            writer.Write(0xa1b2c3d4U); writer.Write((ushort)2); writer.Write((ushort)4); writer.Write(0U); writer.Write(0U);
            writer.Write(65535U); writer.Write(249U);
            void AddRecord(byte[] record)
            {
                writer.Write(0U); writer.Write(0U); writer.Write((uint)record.Length); writer.Write((uint)record.Length); writer.Write(record);
            }
            byte[] Control(bool response, byte[] data)
            {
                using var control = new MemoryStream();
                using var controlWriter = new BinaryWriter(control, Encoding.UTF8, true);
                controlWriter.Write((ushort)28); controlWriter.Write(0UL); controlWriter.Write(0U); controlWriter.Write((ushort)0);
                controlWriter.Write((byte)(response ? 1 : 0)); controlWriter.Write((ushort)5); controlWriter.Write((ushort)1);
                controlWriter.Write((byte)(response ? 0x80 : 0)); controlWriter.Write((byte)2); controlWriter.Write((uint)data.Length);
                controlWriter.Write((byte)(response ? 3 : 0)); controlWriter.Write(data);
                return control.ToArray();
            }
            var config = new byte[9 + 9 + 27 + 26 + 6];
            new byte[] { 9, 2, (byte)config.Length, 0, 1, 1, 0, 0x80, 50, 9, 4, 1, 0, 1, 14, 2, 0, 0 }.CopyTo(config, 0);
            config[18] = 27; config[19] = 0x24; config[20] = 4; config[21] = 1;
            Encoding.ASCII.GetBytes("YUY2").CopyTo(config, 23); config[39] = 16;
            config[45] = 26; config[46] = 0x24; config[47] = 5; config[48] = 1;
            BinaryPrimitives.WriteUInt16LittleEndian(config.AsSpan(50), 4);
            BinaryPrimitives.WriteUInt16LittleEndian(config.AsSpan(52), 2);
            new byte[] { 6, 0x24, 0x0d, 1, 1, 4 }.CopyTo(config, 71);
            AddRecord(Control(true, config));
            var commit = new byte[34];
            new byte[] { 0x21, 1, 0, 2, 1, 0, 26, 0 }.CopyTo(commit, 0);
            commit[10] = 1; commit[11] = 1;
            BinaryPrimitives.WriteUInt32LittleEndian(commit.AsSpan(12), 333333);
            BinaryPrimitives.WriteUInt32LittleEndian(commit.AsSpan(26), (uint)pixels.Length);
            AddRecord(Control(false, commit));
            AddRecord(usb.ToArray());
        }
        return pcap.ToArray();
    }
    var capture = Fixture(false);
    var valid = UvcPcapAnalyzer.Analyze(new MemoryStream(capture), 1, 0x81, [reference]);
    Assert(valid.CompleteFrames == 1 && valid.Matches.Single().ReferenceIndex == 3, "A complete UVC frame did not match.");
    Assert(valid.Formats.Single() is { FourCC: "YUY2", Width: 4, Height: 2, BitDepth: 16 } &&
        valid.Commits.Single() is { Interface: 1, FormatIndex: 1, FrameIndex: 1, FrameInterval: 333333, MaximumFrameBytes: 16 } &&
        valid.Colors.Single() is { Interface: 1, FormatIndex: 1, Primaries: 1, Transfer: 1, Matrix: 4 },
        "The advertised format or negotiated UVC mode was not parsed correctly.");
    var damaged = UvcPcapAnalyzer.Analyze(new MemoryStream(Fixture(true)), 1, 0x81, [reference]);
    Assert(damaged.PacketErrors == 1 && damaged.Matches.Count == 0, "A damaged USB packet produced a match.");
    var truncated = UvcPcapAnalyzer.Analyze(new MemoryStream(capture[..^1]), 1, 0x81, [reference]);
    Assert(truncated.IncompleteTail && truncated.Matches.Count == 0, "A truncated PCAP record was accepted.");
    return Task.CompletedTask;
});

await Test("YUY2 probe separates known chroma reconstruction models", () =>
{
    const int w = 96, h = 32;
    var yuy2 = new byte[w * h * 2];
    var random = new Random(422);
    for (var i = 0; i < yuy2.Length; i += 4)
    {
        yuy2[i] = (byte)random.Next(64, 193); yuy2[i + 1] = (byte)random.Next(96, 161);
        yuy2[i + 2] = (byte)random.Next(64, 193); yuy2[i + 3] = (byte)random.Next(96, 161);
    }
    foreach (var expected in Enum.GetValues<Yuy2ChromaFit.Model>())
    {
        var rgb = new byte[w * h * 4];
        for (var row = 0; row < h; row++)
        for (var x = 2; x < w - 2; x++)
        {
            var pair = row * w * 2 + (x / 2) * 4;
            var weight = expected switch
            {
                Yuy2ChromaFit.Model.Nearest => 0,
                Yuy2ChromaFit.Model.CositedLinear => x % 2 == 0 ? 0 : .5,
                _ => .25
            };
            var neighbor = x % 2 == 0 ? -4 : 4;
            var u = yuy2[pair + 1] * (1 - weight) + yuy2[pair + neighbor + 1] * weight - 128;
            var v = yuy2[pair + 3] * (1 - weight) + yuy2[pair + neighbor + 3] * weight - 128;
            var y = yuy2[pair + (x % 2) * 2] - 128;
            var output = (row * w + x) * 4;
            rgb[output] = (byte)Math.Round(128 + .45 * y + .6 * u);
            rgb[output + 1] = (byte)Math.Round(128 + .45 * y - .15 * u - .25 * v);
            rgb[output + 2] = (byte)Math.Round(128 + .45 * y + .6 * v);
            rgb[output + 3] = 255;
        }
        var scores = Enum.GetValues<Yuy2ChromaFit.Model>().ToDictionary(model => model,
            model => Yuy2ChromaFit.Score(yuy2, rgb, w, h, model, true)?.Error ?? double.PositiveInfinity);
        Assert(scores[expected] < .4 && scores.Where(s => s.Key != expected).All(s => s.Value > scores[expected] + 1),
            $"Expected {expected} to be clearly distinguished: {string.Join(", ", scores)}");
    }
    Assert(Yuy2ChromaFit.Score(new byte[w * h * 2], new byte[w * h * 4], w, h,
        Yuy2ChromaFit.Model.Nearest, false) is null, "A uniform frame must be inconclusive.");
    return Task.CompletedTask;
});

var fixture = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "jpeg-progressive.jpg"));
int width = 0, height = 0;
for (var i = 0; i + 8 < fixture.Length; i++)
    if (fixture[i] == 0xff && fixture[i + 1] is 0xc0 or 0xc1 or 0xc2)
    { height = BinaryPrimitives.ReadUInt16BigEndian(fixture.AsSpan(i + 5, 2)); width = BinaryPrimitives.ReadUInt16BigEndian(fixture.AsSpan(i + 7, 2)); break; }
Assert(width > 0 && height > 0, "Fixture dimensions missing");
var jpegFrame = Frame("MJPG", width, height, fixture);

await Test("Media Foundation sample metadata retains documented types and values", () =>
{
    using var platform = new MediaFoundationCamera();
    System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)MFExtern.MFCreateSample(out var sample));
    System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)MFExtern.MFCreateAttributes(out var bag, 4));
    try
    {
        System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)bag.SetUINT64(FrameMetadataReader.Exposure, 100_000));
        System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)bag.SetUINT32(FrameMetadataReader.IsoSpeed, 400));
        var whiteBalance = new Guid("C736FD77-0FB9-4E2E-97A2-FCD490739EE9");
        System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)bag.SetUINT32(whiteBalance, 6500));
        var gains = new Guid("05802AC9-0E1D-41C7-A8C8-7E7369F84E1E");
        System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)bag.SetBlob(gains, [1, 2, 3, 4], 4));
        System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)sample.SetUnknown(FrameMetadataReader.CaptureMetadata, bag));
        var metadata = FrameMetadataReader.Read(sample) ?? throw new Exception("Frame metadata was not read.");
        Assert(metadata.Values.Any(v => v.Name == "ExposureTime100ns" && v.Type == "UInt64" && v.Value == "100000"), "Exposure was not preserved.");
        Assert(metadata.Values.Any(v => v.Name == "IsoSpeed" && v.Type == "UInt32" && v.Value == "400"), "ISO was not preserved.");
        Assert(metadata.Values.Any(v => v.Name == "WhiteBalanceKelvin" && v.Value == "6500"), "White balance was not preserved.");
        Assert(metadata.Values.Any(v => v.Name == "IsoGains" && v.Type == "BlobBase64" && v.Value == "AQIDBA=="), "Gain blob was not preserved.");
        var sourceExif = new Guid("2E9575B8-8C31-4A02-8575-42B197B71592");
        var oversized = new byte[256 * 1024 + 1];
        System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)bag.SetBlob(sourceExif, oversized, oversized.Length));
        metadata = FrameMetadataReader.Read(sample) ?? throw new Exception("Oversized metadata was not reported.");
        Assert(metadata.Values.Any(v => v.Name == "SourceExif" && v.Type == "BlobOmittedTooLarge" && v.Value == oversized.Length.ToString()), "Oversized metadata was silently discarded.");
        System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)bag.DeleteItem(sourceExif));
        System.Runtime.InteropServices.Marshal.ThrowExceptionForHR((int)bag.SetUINT32(FrameMetadataReader.Exposure, 100_000));
        metadata = FrameMetadataReader.Read(sample) ?? throw new Exception("32-bit exposure was not retained.");
        Assert(metadata.Values.Any(v => v.Name == "ExposureTime100ns" && v.Type == "UInt32"), "Unexpected exposure type was hidden.");
        Assert(CaptureMetadata.StandardDescription(jpegFrame with { FrameMetadata = metadata })?.Attribute(XNamespace.Get("http://ns.adobe.com/exif/1.0/") + "ExposureTime") is null,
            "An undocumented exposure type was mapped to a standard exposure.");
    }
    finally
    {
        System.Runtime.InteropServices.Marshal.ReleaseComObject(sample);
        System.Runtime.InteropServices.Marshal.ReleaseComObject(bag);
    }
    return Task.CompletedTask;
});

var observedAt = DateTimeOffset.Parse("2026-01-02T03:04:05.125-06:00");
var frameSettings = new FrameCaptureMetadata([
    new("ExposureTime100ns", "UInt64", "100000"), new("IsoSpeed", "UInt32", "400"),
    new("WhiteBalanceKelvin", "UInt32", "6500"), new("LensPosition", "UInt32", "123")]);
var controlSettings = new CameraControlSnapshot(observedAt, observedAt.AddMilliseconds(4), [
    new("Exposure", Guid.Parse("C6E13370-30AC-11D0-A18C-00A0C9118956"), 4, -7, 1, 3, observedAt, "log2 seconds"),
    new("Focus", Guid.Parse("C6E13370-30AC-11D0-A18C-00A0C9118956"), 6, 10, 1, 3, observedAt),
    new("WhiteBalance", Guid.Parse("C6E13360-30AC-11D0-A18C-00A0C9118956"), 7, 6700, 1, 3, observedAt, "kelvin")], "Read complete");
var settingsFrame = jpegFrame with { FrameMetadata = frameSettings, Controls = controlSettings };

await Test("Camera settings XMP keeps provenance and uses standard frame measurements", () =>
{
    XNamespace exif = "http://ns.adobe.com/exif/1.0/";
    XNamespace pb = CaptureMetadata.Namespace;
    var document = CaptureMetadata.NewDocument(settingsFrame, Guid.NewGuid());
    Assert(document.Descendants(CaptureMetadata.Rdf + "Description").Attributes(exif + "ExposureTime").Single().Value == "1/100", "Frame exposure was not mapped to XMP.");
    Assert(document.Descendants(exif + "ISOSpeedRatings").Descendants(CaptureMetadata.Rdf + "li").Single().Value == "400", "Frame ISO was not mapped to XMP.");
    Assert(document.Descendants(pb + "CameraControls").Descendants(pb + "Name").Select(x => x.Value).SequenceEqual(["Exposure", "Focus", "WhiteBalance"]), "Control observations were lost.");
    Assert(document.Descendants(pb + "ObservedAt").Count() == 3 && document.ToString().Contains("not frame synchronized"), "Control timing or provenance is missing.");
    var controlOnly = CaptureMetadata.NewDocument(jpegFrame with { Controls = controlSettings }, Guid.NewGuid());
    Assert(!controlOnly.Descendants(CaptureMetadata.Rdf + "Description").Attributes(exif + "ExposureTime").Any() && !controlOnly.Descendants(exif + "ISOSpeedRatings").Any(),
        "Near-shutter settings were mislabeled as frame measurements.");
    var sourceExif = settingsFrame with { FrameMetadata = new([..frameSettings.Values, new("SourceExif", "BlobBase64", "AA==")]) };
    Assert(CaptureMetadata.StandardDescription(sourceExif) is null, "Existing sample EXIF was overridden.");
    return Task.CompletedTask;
});

await Test("Source JPEG metadata takes precedence over frame observations", () =>
{
    var exif = Segment(0xe1, "Exif\0\0original"u8.ToArray());
    var withExif = Insert(fixture, exif);
    var output = JpegPreserver.AddMetadata(settingsFrame with { Bytes = withExif }, Guid.NewGuid());
    var text = Encoding.UTF8.GetString(output);
    Assert(text.Contains("Exif\0\0original") && text.Contains("FrameCaptureMetadata") && !text.Contains("exif:ExposureTime"), "Existing EXIF was overwritten or conflicting standard fields added.");
    var sourcePacket = "http://ns.adobe.com/xap/1.0/\0<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:exif=\"http://ns.adobe.com/exif/1.0/\" exif:ExposureTime=\"1/25\"/></rdf:RDF></x:xmpmeta>";
    var withXmp = Insert(fixture, Segment(0xe1, Encoding.UTF8.GetBytes(sourcePacket)));
    output = JpegPreserver.AddMetadata(settingsFrame with { Bytes = withXmp }, Guid.NewGuid());
    text = Encoding.UTF8.GetString(output);
    Assert(text.Contains("exif:ExposureTime=\"1/25\"") && !text.Contains("exif:ExposureTime=\"1/100\"") && text.Contains("CameraControls"), "Source XMP conflict was not preserved.");
    return Task.CompletedTask;
});

await Test("Settings survive queue reopening, failed save, and JPEG finalization", async () =>
{
    var root = Path.Combine(Path.GetTempPath(), "pixelbooth-tests-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    try
    {
        var queue = Path.Combine(root, "queue");
        var blocked = Path.Combine(root, "blocked"); File.WriteAllText(blocked, "fixture");
        var store = new CaptureStore(queue);
        var capture = await store.EnqueueAsync(settingsFrame, blocked);
        var reopened = new CaptureStore(queue).Pending().Single();
        Assert(reopened.Controls?.Values.Single(v => v.Name == "Exposure").Value == -7 && reopened.FrameMetadata?.Values.Single(v => v.Name == "IsoSpeed").Value == "400", "Settings did not survive queue serialization.");
        try { await store.SaveAsync(reopened); throw new Exception("Saving to a file unexpectedly succeeded."); } catch (IOException) { }
        var path = await store.SaveAsync(reopened with { Destination = Path.Combine(root, "photos") });
        var result = File.ReadAllBytes(path);
        var text = Encoding.UTF8.GetString(result);
        Assert(text.Contains("CameraControls") && text.Contains("WhiteBalanceKelvin") && text.Contains("exif:ExposureTime=\"1/100\""), "Saved JPEG lacks settings.");
        var length = BinaryPrimitives.ReadUInt16BigEndian(result.AsSpan(4, 2));
        Assert(result.AsSpan(0, 2).ToArray().Concat(result.Skip(4 + length)).SequenceEqual(fixture), "Settings altered JPEG coding bytes.");
    }
    finally
    {
        var full = Path.GetFullPath(root); var temp = Path.GetFullPath(Path.GetTempPath());
        if (full.StartsWith(temp, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(full).StartsWith("pixelbooth-tests-", StringComparison.Ordinal) && Directory.Exists(full)) Directory.Delete(full, true);
    }
});

await Test("Oversized JPEG metadata is retained in a verified XMP sidecar", async () =>
{
    var root = Path.Combine(Path.GetTempPath(), "pixelbooth-tests-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(root);
    try
    {
        var queue = Path.Combine(root, "queue");
        var blocked = Path.Combine(root, "blocked"); File.WriteAllText(blocked, "fixture");
        var store = new CaptureStore(queue);
        var large = settingsFrame with { FrameMetadata = new([new("SourceExif", "BlobBase64", new string('A', 80_000))]) };
        var capture = await store.EnqueueAsync(large, blocked);
        try { await store.SaveAsync(capture); throw new Exception("Saving to a file unexpectedly succeeded."); } catch (IOException) { }
        var reopened = new CaptureStore(queue).Pending().Single();
        var path = await store.SaveAsync(reopened with { Destination = Path.Combine(root, "photos") });
        Assert(File.ReadAllBytes(path).SequenceEqual(fixture), "Sidecar fallback changed the source JPEG.");
        var sidecar = File.ReadAllText(Path.ChangeExtension(path, ".xmp"));
        Assert(sidecar.Contains(new string('A', 80_000)) && sidecar.Contains("WhiteBalance") && store.Pending().Count == 0, "Sidecar or queue recovery lost settings.");
    }
    finally
    {
        var full = Path.GetFullPath(root); var temp = Path.GetFullPath(Path.GetTempPath());
        if (full.StartsWith(temp, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(full).StartsWith("pixelbooth-tests-", StringComparison.Ordinal) && Directory.Exists(full)) Directory.Delete(full, true);
    }
});

await Test("Unsafe source XMP is preserved with new metadata in a sidecar", async () =>
{
    var root = Path.Combine(Path.GetTempPath(), "pixelbooth-tests-" + Guid.NewGuid().ToString("N"));
    try
    {
        var hostile = Encoding.UTF8.GetBytes("http://ns.adobe.com/xap/1.0/\0<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///C:/secret'>]><x>&secret;</x>");
        var original = Insert(fixture, Segment(0xe1, hostile));
        var store = new CaptureStore(Path.Combine(root, "queue"));
        var capture = await store.EnqueueAsync(settingsFrame with { Bytes = original }, Path.Combine(root, "photos"));
        var path = await store.SaveAsync(capture);
        Assert(File.ReadAllBytes(path).SequenceEqual(original), "Unmergeable camera XMP was changed.");
        var sidecar = File.ReadAllText(Path.ChangeExtension(path, ".xmp"));
        Assert(sidecar.Contains("CameraControls") && !sidecar.Contains("exif:ExposureTime"), "Sidecar failed to retain controls or overrode source metadata.");
    }
    finally
    {
        var full = Path.GetFullPath(root); var temp = Path.GetFullPath(Path.GetTempPath());
        if (full.StartsWith(temp, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(full).StartsWith("pixelbooth-tests-", StringComparison.Ordinal) && Directory.Exists(full)) Directory.Delete(full, true);
    }
});

await Test("JPEG insertion preserves every source byte and trims padding", () =>
{
    var padded = fixture.Concat(new byte[] { 0, 0, 0 }).ToArray();
    var result = JpegPreserver.AddMetadata(jpegFrame with { Bytes = padded }, Guid.NewGuid());
    var length = BinaryPrimitives.ReadUInt16BigEndian(result.AsSpan(4, 2));
    var withoutInsertedXmp = result.AsSpan(0, 2).ToArray().Concat(result.Skip(4 + length)).ToArray();
    Assert(withoutInsertedXmp.SequenceEqual(fixture), "Original JPEG markers or scan data changed.");
    Assert(JpegPreserver.Extract(padded).SequenceEqual(fixture), "Padding was not removed correctly.");
    return Task.CompletedTask;
});

await Test("JPEG retains unknown metadata and merges source XMP", () =>
{
    var header = Encoding.ASCII.GetBytes("http://ns.adobe.com/xap/1.0/\0");
    var sourceXmp = Encoding.UTF8.GetBytes("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:cam=\"urn:camera:test\" cam:calibration=\"keep-this\"/></rdf:RDF></x:xmpmeta>");
    var xmp = Segment(0xe1, header.Concat(sourceXmp).ToArray());
    var opaque = Segment(0xed, Encoding.ASCII.GetBytes("unknown-camera-payload"));
    var input = Insert(fixture, xmp, opaque);
    var output = JpegPreserver.AddMetadata(jpegFrame with { Bytes = input }, Guid.NewGuid());
    var text = Encoding.UTF8.GetString(output);
    Assert(text.Contains("keep-this") && text.Contains("unknown-camera-payload") && text.Contains("HostReceivedTime"), "Metadata was lost.");
    var replacementLength = BinaryPrimitives.ReadUInt16BigEndian(output.AsSpan(4, 2));
    var outputTail = output.AsSpan(4 + replacementLength).ToArray();
    var inputTail = input.AsSpan(2 + xmp.Length).ToArray();
    Assert(outputTail.SequenceEqual(inputTail), "A non-XMP JPEG segment changed.");
    return Task.CompletedTask;
});

await Test("JPEG rejects malformed, truncated, and hostile XMP inputs", () =>
{
    Throws(() => JpegPreserver.Extract(fixture[..^2]));
    Throws(() => JpegPreserver.Extract([0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff]));
    Throws(() => JpegPreserver.AddMetadata(jpegFrame with { Mode = jpegFrame.Mode with { Width = width + 1 } }, Guid.NewGuid()));
    var xmp = Encoding.UTF8.GetBytes("http://ns.adobe.com/xap/1.0/\0<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///C:/secret'>]><x>&secret;</x>");
    Throws(() => JpegPreserver.AddMetadata(jpegFrame with { Bytes = Insert(fixture, Segment(0xe1, xmp)) }, Guid.NewGuid()));
    return Task.CompletedTask;
});

await Test("H.264 IDR becomes an AVCI image without changing NAL units", () =>
{
    var input = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "h264-idr.264"));
    var picture = new H264AccessUnitCollector().Observe(input) ?? throw new Exception("Fixture contains no IDR picture.");
    Assert(picture.Width == 128 && picture.Height == 96, "Incorrect H.264 dimensions.");
    var frame = Frame("H264", picture.Width, picture.Height, input) with { FrameMetadata = frameSettings, Controls = controlSettings };
    var output = AvciWriter.Write(picture, frame, Guid.NewGuid());
    HeifProbe.Inspect(output, picture.Width, picture.Height);
    AvciValidator.Validate(output, picture);
    Assert(Encoding.UTF8.GetString(output).Contains("CameraControls"), "AVCI lacks camera settings.");
    var mdat = Array.IndexOf(output, (byte)'m', 4);
    while (mdat >= 0 && (mdat + 4 >= output.Length || Encoding.ASCII.GetString(output, mdat, 4) != "mdat")) mdat = Array.IndexOf(output, (byte)'m', mdat + 1);
    Assert(mdat > 0, "AVCI has no media-data box.");
    var cursor = mdat + 4;
    foreach (var nal in picture.NalUnits)
    {
        var length = checked((int)BinaryPrimitives.ReadUInt32BigEndian(output.AsSpan(cursor, 4))); cursor += 4;
        Assert(length == nal.Length && output.AsSpan(cursor, length).SequenceEqual(nal), "AVC NAL data changed."); cursor += length;
    }
    using var platform = new MediaFoundationCamera();
    using var decoder = new H264PreviewDecoder(picture.Width, picture.Height);
    Assert(decoder.Decode(input, 0, true) is not null, "Windows could not decode the fixture IDR picture.");
    Throws(() => new H264AccessUnitCollector().Observe([0, 0, 1, 0x65]));
    return Task.CompletedTask;
});

await Test("H.264 capture queue validates and saves AVCI", async () =>
{
    var input = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "h264-idr.264"));
    var picture = new H264AccessUnitCollector().Observe(input) ?? throw new Exception("Fixture contains no IDR.");
    var root = Path.Combine(Path.GetTempPath(), "pixelbooth-tests-" + Guid.NewGuid().ToString("N"));
    try
    {
        var store = new CaptureStore(Path.Combine(root, "queue"));
        var capture = await store.EnqueueAsync(Frame("H264", picture.Width, picture.Height, input) with { CodecHeader = picture.CodecHeader }, Path.Combine(root, "photos"));
        var file = await store.SaveAsync(capture);
        Assert(Path.GetExtension(file) == ".avci" && store.Pending().Count == 0, "AVCI capture did not finish.");
        AvciValidator.Validate(File.ReadAllBytes(file), picture);
    }
    finally
    {
        var full = Path.GetFullPath(root); var temp = Path.GetFullPath(Path.GetTempPath());
        if (full.StartsWith(temp, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(full).StartsWith("pixelbooth-tests-", StringComparison.Ordinal) && Directory.Exists(full)) Directory.Delete(full, true);
    }
});

foreach (var format in new[] { "NV12", "YUY2" })
await Test($"{format} lossless AVIF channel round-trip", () =>
{
    const int w = 64, h = 48;
    var data = new byte[format == "NV12" ? w * h * 3 / 2 : w * h * 2];
    new Random(format == "NV12" ? 12 : 422).NextBytes(data);
    data[0] = 0; data[1] = 255;
    var encoded = AvifEncoder.Encode(Frame(format, w, h, data) with { FrameMetadata = frameSettings, Controls = controlSettings }, Guid.NewGuid());
    Assert(encoded.Length > 20 && Encoding.ASCII.GetString(encoded, 4, 4) == "ftyp", "Output is not an ISO image file.");
    Assert(Encoding.UTF8.GetString(encoded).Contains("CameraControls"), "AVIF lacks camera settings.");
    return Task.CompletedTask;
});

await Test("NV12 co-sited samples save as verified AVIF", async () =>
{
    const int w = 64, h = 48;
    var samples = new byte[w * h * 3 / 2];
    new Random(4207).NextBytes(samples);
    samples[0] = 0; samples[1] = 255; samples[w * h] = 0; samples[w * h + 1] = 255;
    var original = Frame("NV12", w, h, samples);
    var root = Path.Combine(Path.GetTempPath(), "pixelbooth-tests-" + Guid.NewGuid().ToString("N"));
    try
    {
        foreach (var siting in new[] { 7, 15 })
        {
            var frame = original with { Mode = original.Mode with { ChromaSiting = siting, NominalRange = 2 } };
            Assert(!LosslessTiff.RequiresTiff(frame.Mode), "Co-sited NV12 was not routed to AVIF.");
            var store = new CaptureStore(Path.Combine(root, "queue" + siting));
            var capture = await store.EnqueueAsync(frame, Path.Combine(root, "photos"));
            var path = await store.SaveAsync(capture);
            Assert(Path.GetExtension(path) == ".avif" && File.Exists(path) && store.Pending().Count == 0, "Co-sited NV12 was not saved as AVIF.");
            var encoded = File.ReadAllBytes(path);
            AvifChromaValidator.VerifyColocated420(encoded);
            Assert(Encoding.UTF8.GetString(encoded).Contains($"ChromaSitingMF=\"{siting}\""), "Original siting was not retained.");
            var av1c = encoded.AsSpan().IndexOf("av1C"u8);
            Assert(av1c >= 0, "AVIF codec configuration missing.");
            encoded[av1c + 6] &= 0xfc;
            Throws(() => AvifChromaValidator.VerifyColocated420(encoded));
        }

        // A matching container declaration cannot hide an unspecified AV1 sequence header.
        var unknown = AvifEncoder.Encode(original, Guid.NewGuid());
        var config = unknown.AsSpan().IndexOf("av1C"u8);
        Assert(config >= 0, "AVIF codec configuration missing.");
        unknown[config + 6] = (byte)((unknown[config + 6] & 0xfc) | 2);
        Throws(() => AvifChromaValidator.VerifyColocated420(unknown));
        foreach (var siting in new[] { 1, 5, 8, 9, 23 })
            Assert(LosslessTiff.RequiresTiff(original.Mode with { ChromaSiting = siting }), "Other NV12 positioning was incorrectly routed to AVIF.");
    }
    finally
    {
        var full = Path.GetFullPath(root); var temp = Path.GetFullPath(Path.GetTempPath());
        if (full.StartsWith(temp, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(full).StartsWith("pixelbooth-tests-", StringComparison.Ordinal) && Directory.Exists(full)) Directory.Delete(full, true);
    }
});

await Test("YUY2 co-sited policy retains source metadata and saves AVIF", async () =>
{
    const int w = 64, h = 48;
    var data = new byte[w * h * 2];
    new Random(4226).NextBytes(data);
    data[0] = 0; data[1] = 255; data[2] = 255; data[3] = 0;
    var frame = Frame("YUY2", w, h, data);
    frame = frame with { Mode = frame.Mode with { ChromaSiting = 6, NominalRange = 2 } };
    var planes = RawPlanes.FromFrame(frame);
    for (var i = 0; i < w * h / 2; i++)
        Assert(planes.Y[i * 2] == data[i * 4] && planes.Cb[i] == data[i * 4 + 1] &&
            planes.Y[i * 2 + 1] == data[i * 4 + 2] && planes.Cr[i] == data[i * 4 + 3], "YUY2 samples were changed during deinterleaving.");
    foreach (int? reportedSiting in new int?[] { null, 0, 1, 3, 6, 7 })
    {
        var mode = frame.Mode with { ChromaSiting = reportedSiting };
        Assert(!LosslessTiff.RequiresTiff(mode), "YUY2 was not routed to AVIF.");
        AvifEncoder.ValidateMode(mode);
    }
    var description = CaptureMetadata.Description(frame, Guid.NewGuid(), yuy2CoSited: true);
    System.Xml.Linq.XNamespace pb = CaptureMetadata.Namespace;
    Assert((string?)description.Attribute(pb + "ChromaSitingMF") == "6", "The reported siting flag was lost.");
    Assert((string?)description.Attribute(pb + "OutputChromaInterpretation") == "Co-sited (PixelBooth YUY2 policy)", "The output interpretation was not attributed to policy.");
    var root = Path.Combine(Path.GetTempPath(), "pixelbooth-tests-" + Guid.NewGuid().ToString("N"));
    try
    {
        var store = new CaptureStore(Path.Combine(root, "queue"));
        var capture = await store.EnqueueAsync(frame, Path.Combine(root, "photos"));
        var path = await store.SaveAsync(capture);
        Assert(Path.GetExtension(path) == ".avif" && File.Exists(path) && store.Pending().Count == 0, "YUY2 capture did not save as AVIF.");
        var output = File.ReadAllBytes(path);
        var xmp = Encoding.UTF8.GetString(output);
        Assert(xmp.Contains("ChromaSitingMF=\"6\"") && xmp.Contains("Co-sited (PixelBooth YUY2 policy)"), "Saved AVIF is missing the original flag or output policy.");
    }
    finally
    {
        var full = Path.GetFullPath(root); var temp = Path.GetFullPath(Path.GetTempPath());
        if (full.StartsWith(temp, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(full).StartsWith("pixelbooth-tests-", StringComparison.Ordinal) && Directory.Exists(full)) Directory.Delete(full, true);
    }
});

await Test("Raw layouts reject incomplete data and unknown color range", () =>
{
    var frame = Frame("NV12", 8, 8, new byte[96]);
    Throws(() => RawPlanes.FromFrame(frame with { Bytes = new byte[95] }));
    Throws(() => RawPlanes.FromFrame(frame with { Mode = frame.Mode with { InterlaceMode = 3 } }));
    Throws(() => RawPlanes.FromFrame(frame with { Mode = frame.Mode with { Stride = 16 } }));
    Throws(() => AvifEncoder.Encode(frame with { Mode = frame.Mode with { NominalRange = null } }, Guid.NewGuid()));
    Throws(() => AvifEncoder.Encode(frame with { Mode = frame.Mode with { Transfer = 2 } }, Guid.NewGuid()));
    return Task.CompletedTask;
});

await Test("TIFF records Media Foundation's unknown-transfer fallback", () =>
{
    var frame = Frame("NV12", 8, 8, new byte[96]);
    frame = frame with { Mode = frame.Mode with { ChromaSiting = 1, Transfer = null } };
    var encoded = LosslessTiff.Encode(frame, Guid.NewGuid());
    var text = Encoding.UTF8.GetString(encoded);
    Assert(text.Contains("Media Foundation default for unknown transfer"), "The transfer fallback was not attributed in XMP.");
    var count = BinaryPrimitives.ReadUInt16LittleEndian(encoded.AsSpan(8, 2));
    var hasTransfer = Enumerable.Range(0, count).Any(i => BinaryPrimitives.ReadUInt16LittleEndian(encoded.AsSpan(10 + 12 * i, 2)) == 301);
    Assert(hasTransfer, "The TIFF would otherwise assume a different transfer function.");
    return Task.CompletedTask;
});

foreach (var format in new[] { "NV12", "YUY2" })
await Test($"{format} lossless TIFF preserves samples and positioning", () =>
{
    const int w = 64, h = 48;
    var data = new byte[format == "NV12" ? w * h * 3 / 2 : w * h * 2];
    new Random(91).NextBytes(data);
    var frame = Frame(format, w, h, data) with { FrameMetadata = frameSettings, Controls = controlSettings };
    frame = frame with { Mode = frame.Mode with { ChromaSiting = format == "NV12" ? 1 : 7 } };
    var encoded = LosslessTiff.Encode(frame, Guid.NewGuid());
    Assert(encoded[0] == 0x49 && encoded[1] == 0x49, "Output is not a TIFF.");
    Assert(Encoding.UTF8.GetString(encoded).Contains("CameraControls"), "TIFF lacks camera settings.");
    if (format == "NV12") Throws(() => AvifEncoder.Encode(frame, Guid.NewGuid()));
    Throws(() => LosslessTiff.Encode(frame with { Mode = frame.Mode with { ChromaSiting = 6 } }, Guid.NewGuid()));
    return Task.CompletedTask;
});

await Test("Capture queue survives failed save and can be recovered", async () =>
{
    var root = Path.Combine(Path.GetTempPath(), "pixelbooth-tests-" + Guid.NewGuid().ToString("N"));
    var queue = Path.Combine(root, "queue"); var destination = Path.Combine(root, "photos");
    Directory.CreateDirectory(root);
    try
    {
        var blocked = Path.Combine(root, "not-a-folder"); File.WriteAllText(blocked, "fixture");
        var store = new CaptureStore(queue);
        var capture = await store.EnqueueAsync(jpegFrame, blocked);
        Assert(new CaptureStore(queue).Pending().Count == 1, "Capture did not survive reopening the queue.");
        var captureDir = Path.Combine(queue, capture.Id.ToString("N"));
        File.WriteAllText(Path.Combine(captureDir, "final.tmp"), "interrupted output");
        File.WriteAllText(Path.Combine(captureDir, "final.sha256.tmp"), "interrupted hash");
        try { await store.SaveAsync(capture); throw new Exception("Saving to a file unexpectedly succeeded."); } catch (IOException) { }
        Assert(store.Pending().Count == 1, "Failed save discarded the source.");
        var result = await store.SaveAsync(capture with { Destination = destination });
        Assert(File.Exists(result) && store.Pending().Count == 0, "Recovered capture was not saved and cleared.");
        Assert(JpegPreserver.Extract(File.ReadAllBytes(result)).Length > fixture.Length, "Saved JPEG is incomplete.");
        var damaged = await store.EnqueueAsync(jpegFrame, destination);
        File.WriteAllText(Path.Combine(queue, damaged.Id.ToString("N"), "source.bin"), "corrupted");
        try { await store.SaveAsync(damaged); throw new Exception("Corrupted source was saved."); } catch (InvalidDataException) { }
        Assert(store.Pending().Count == 1, "A failed integrity check removed the retained source.");
        Directory.CreateDirectory(Path.Combine(queue, ".incomplete.staging"));
        Assert(store.RetainedDirectoryCount == 2 && store.Pending().Count == 1, "Incomplete recovery items are hidden.");
    }
    finally
    {
        var full = Path.GetFullPath(root); var temp = Path.GetFullPath(Path.GetTempPath());
        if (full.StartsWith(temp, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(full).StartsWith("pixelbooth-tests-", StringComparison.Ordinal)) Directory.Delete(full, true);
    }
});

Console.WriteLine($"{passed} passed, {failed} failed. Hardware probes run only when explicitly requested.");
if (failed != 0) Environment.ExitCode = 1;
