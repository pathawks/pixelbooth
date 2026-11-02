using PixelBooth.Core.Capture;
using PixelBooth.Core.Imaging;
using MediaFoundation;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using Windows.Security.Cryptography;

/// <summary>Compare two MediaCapture readers fed by the same selected camera source.</summary>
internal static class MediaCaptureYuy2Probe
{
    private sealed record Frame(long Ticks, byte[] Bytes);

    public static async Task RunAsync(CameraDevice device, CameraMode sourceMode)
    {
        var groups = await MediaFrameSourceGroup.FindAllAsync();
        var group = groups.FirstOrDefault(g => g.SourceInfos.Any(i =>
            string.Equals(i.DeviceInformation?.Id, device.Id, StringComparison.OrdinalIgnoreCase)));
        if (group is null) throw new InvalidOperationException("No MediaCapture source group matched the camera's device ID.");

        using var capture = new MediaCapture();
        await capture.InitializeAsync(new MediaCaptureInitializationSettings
        {
            SourceGroup = group,
            StreamingCaptureMode = StreamingCaptureMode.Video,
            SharingMode = MediaCaptureSharingMode.ExclusiveControl,
            MemoryPreference = MediaCaptureMemoryPreference.Cpu
        });
        var choice = capture.FrameSources.Values
            .Where(s => s.Info.SourceKind == MediaFrameSourceKind.Color)
            .SelectMany(s => s.SupportedFormats.Where(f => f.Subtype.Equals("YUY2", StringComparison.OrdinalIgnoreCase) &&
                    f.VideoFormat.Width == 640 && f.VideoFormat.Height == 480)
                .Select(f => (Source: s, Format: f)))
            .OrderByDescending(x => (double)x.Format.FrameRate.Numerator / Math.Max(1, x.Format.FrameRate.Denominator))
            .FirstOrDefault();
        if (choice.Source is null) throw new InvalidOperationException("MediaCapture does not expose 640×480 YUY2 for this device.");
        await choice.Source.SetFormatAsync(choice.Format);
        Console.WriteLine($"MediaCapture source: {group.DisplayName}; {choice.Source.Info.MediaStreamType}; selected {choice.Format.Subtype} {choice.Format.VideoFormat.Width}×{choice.Format.VideoFormat.Height} at {choice.Format.FrameRate.Numerator}/{choice.Format.FrameRate.Denominator} fps.");
        var attributes = new[]
        {
            (Name: "matrix", Key: MFAttributesClsid.MF_MT_YUV_MATRIX, Expected: sourceMode.Matrix),
            (Name: "range", Key: MFAttributesClsid.MF_MT_VIDEO_NOMINAL_RANGE, Expected: sourceMode.NominalRange),
            (Name: "chroma_siting", Key: MFAttributesClsid.MF_MT_VIDEO_CHROMA_SITING, Expected: sourceMode.ChromaSiting),
            (Name: "primaries", Key: MFAttributesClsid.MF_MT_VIDEO_PRIMARIES, Expected: sourceMode.Primaries),
            (Name: "transfer", Key: MFAttributesClsid.MF_MT_TRANSFER_FUNCTION, Expected: sourceMode.Transfer)
        };
        int? Attribute(Guid key) => choice.Source.CurrentFormat.Properties.TryGetValue(key, out var value) && int.TryParse(value?.ToString(), out var number) ? number : null;
        var observed = attributes.Select(a => (a.Name, a.Expected, Actual: Attribute(a.Key))).ToArray();
        Console.WriteLine($"MediaCapture source attributes: {string.Join(", ", observed.Select(a => $"{a.Name}={a.Actual?.ToString() ?? "not exposed"}"))}.");

        using var rawReader = await capture.CreateFrameReaderAsync(choice.Source);
        using var rgbReader = await capture.CreateFrameReaderAsync(choice.Source, MediaEncodingSubtypes.Bgra8);
        var pendingRaw = new Dictionary<long, Frame>();
        var pendingRgb = new Dictionary<long, Frame>();
        var gate = new object();
        var matched = new TaskCompletionSource<(Frame Raw, Frame Rgb)>(TaskCreationOptions.RunContinuationsAsynchronously);

        void Receive(MediaFrameReader sender, bool isRaw)
        {
            try
            {
                using var reference = sender.TryAcquireLatestFrame();
                using var bitmap = reference?.VideoMediaFrame?.SoftwareBitmap;
                if (reference?.SystemRelativeTime is not TimeSpan time || bitmap is null || matched.Task.IsCompleted) return;
                var expected = isRaw ? BitmapPixelFormat.Yuy2 : BitmapPixelFormat.Bgra8;
                if (bitmap.BitmapPixelFormat != expected || bitmap.PixelWidth != 640 || bitmap.PixelHeight != 480)
                    throw new InvalidDataException($"Unexpected MediaCapture frame: {bitmap.BitmapPixelFormat} {bitmap.PixelWidth}×{bitmap.PixelHeight}.");
                var capacity = checked((uint)(bitmap.PixelWidth * bitmap.PixelHeight * (isRaw ? 2 : 4)));
                var buffer = new Windows.Storage.Streams.Buffer(capacity);
                bitmap.CopyToBuffer(buffer);
                CryptographicBuffer.CopyToByteArray(buffer, out var bytes);
                var frame = new Frame(time.Ticks, bytes);
                lock (gate)
                {
                    var own = isRaw ? pendingRaw : pendingRgb;
                    var other = isRaw ? pendingRgb : pendingRaw;
                    if (other.Remove(frame.Ticks, out var matching))
                        matched.TrySetResult(isRaw ? (frame, matching) : (matching, frame));
                    else own[frame.Ticks] = frame;
                    if (own.Count > 12) own.Remove(own.Keys.Min());
                }
            }
            catch (Exception e) { matched.TrySetException(e); }
        }

        rawReader.FrameArrived += (sender, _) => Receive(sender, true);
        rgbReader.FrameArrived += (sender, _) => Receive(sender, false);
        var rawStarted = false;
        var rgbStarted = false;
        (Frame Raw, Frame Rgb) pair;
        try
        {
            var status = await rawReader.StartAsync();
            if (status != MediaFrameReaderStartStatus.Success) throw new InvalidOperationException($"YUY2 reader start: {status}.");
            rawStarted = true;
            status = await rgbReader.StartAsync();
            if (status != MediaFrameReaderStartStatus.Success) throw new InvalidOperationException($"BGRA reader start: {status}.");
            rgbStarted = true;
            pair = await matched.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        finally
        {
            if (rgbStarted) await rgbReader.StopAsync();
            if (rawStarted) await rawReader.StopAsync();
        }
        var converted = Yuy2Probe.Convert(pair.Raw.Bytes, 640, 480);
        Console.WriteLine($"MediaCapture matched source timestamp {pair.Raw.Ticks}: YUY2 and BGRA8 readers both returned 640×480 frames.");
        PrintDifference("Reader BGRA vs SoftwareBitmap.Convert of matched YUY2", pair.Rgb.Bytes, converted);
        PrintFits("MediaCapture reader", pair.Raw.Bytes, pair.Rgb.Bytes);

        if ((long)choice.Format.FrameRate.Numerator * sourceMode.RateDenominator != (long)sourceMode.RateNumerator * choice.Format.FrameRate.Denominator)
        {
            Console.WriteLine("NOT RUN: AVIF comparison: MediaCapture and Media Foundation selected different frame rates.");
            return;
        }
        var mismatches = observed.Where(a => a.Actual.HasValue && a.Expected.HasValue && a.Actual != a.Expected).ToArray();
        if (mismatches.Length != 0)
        {
            Console.WriteLine($"NOT RUN: AVIF comparison: source attributes disagree for {string.Join(", ", mismatches.Select(a => a.Name))}.");
            return;
        }
        var unavailable = observed.Where(a => !a.Actual.HasValue || !a.Expected.HasValue).Select(a => a.Name).ToArray();
        Console.WriteLine(unavailable.Length == 0
            ? "AVIF test uses matching Media Foundation and MediaCapture color attributes."
            : $"AVIF test uses Media Foundation color attributes; not independently verified: {string.Join(", ", unavailable)}.");
        var frame = new CameraFrame(device, sourceMode, pair.Raw.Bytes, 0, DateTimeOffset.Now, 0, 1);
        var avif = AvifEncoder.Encode(frame, Guid.NewGuid());
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        await stream.WriteAsync(CryptographicBuffer.CreateFromByteArray(avif));
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var decoded = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
        if (decoded.PixelWidth != 640 || decoded.PixelHeight != 480) throw new InvalidDataException("Windows decoded an unexpected AVIF size.");
        var decodedBuffer = new Windows.Storage.Streams.Buffer(640 * 480 * 4);
        decoded.CopyToBuffer(decodedBuffer);
        CryptographicBuffer.CopyToByteArray(decodedBuffer, out var decodedBytes);
        PrintDifference("Windows-decoded AVIF vs MediaCapture BGRA", decodedBytes, pair.Rgb.Bytes);
        PrintFits("Windows AVIF decoder", pair.Raw.Bytes, decodedBytes);
        Console.WriteLine("Models use nearest or linear chroma reconstruction and fit a separate affine color conversion for each RGB channel.");
        Console.WriteLine("Any difference can also reflect color/range conversion, resampling, or other pipeline processing; this is not a measurement of camera siting.");
    }

    private static void PrintDifference(string label, byte[] first, byte[] second)
    {
        if (first.Length != 640 * 480 * 4 || second.Length != first.Length) throw new InvalidDataException("Unexpected RGB frame size.");
        double error = 0;
        long unequal = 0;
        long overOne = 0;
        var maximum = 0;
        for (var i = 0; i < first.Length; i += 4)
        for (var c = 0; c < 3; c++)
        {
            var difference = Math.Abs(first[i + c] - second[i + c]);
            error += difference;
            if (difference != 0) unequal++;
            if (difference > 1) overOne++;
            maximum = Math.Max(maximum, difference);
        }
        Console.WriteLine($"{label}: RGB mean absolute error {error / (640 * 480 * 3):F3}; {unequal} differing channels; {overOne} differ by more than 1; maximum difference {maximum}.");
    }

    private static void PrintFits(string label, byte[] raw, byte[] rgb)
    {
        foreach (var edgesOnly in new[] { false, true })
        foreach (var model in Enum.GetValues<Yuy2ChromaFit.Model>())
        {
            var score = Yuy2ChromaFit.Score(raw, rgb, 640, 480, model, edgesOnly);
            Console.WriteLine(score is null
                ? $"{label}, {(edgesOnly ? "chroma edges" : "all pixels")}, {model}: insufficient usable variation."
                : $"{label}, {(edgesOnly ? "chroma edges" : "all pixels")}, {model}: fitted RGB RMSE {score.Value.Error:F3} from {score.Value.Count} channel samples.");
        }
    }
}
