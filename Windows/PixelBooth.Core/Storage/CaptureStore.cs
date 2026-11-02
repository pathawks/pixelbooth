using System.Security.Cryptography;
using System.Text.Json;
using PixelBooth.Core.Capture;
using PixelBooth.Core.Imaging;

namespace PixelBooth.Core.Storage;

public sealed record PendingCapture(Guid Id, CameraDevice Device, CameraMode Mode, long MediaTimestamp100ns,
    DateTimeOffset ReceivedAt, long Generation, string Sha256, string Destination, byte[]? CodecHeader = null,
    FrameCaptureMetadata? FrameMetadata = null, CameraControlSnapshot? Controls = null);

/// <summary>Persists the camera-delivered sample before encoding and only removes it after an atomic save.</summary>
public sealed class CaptureStore
{
    private const long MaxBytes = 512L * 1024 * 1024;
    private const int MaxCaptures = 200;
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly SemaphoreSlim SaveGate = new(1, 1);
    private readonly string _root;

    public CaptureStore(string? root = null)
    {
        _root = Path.GetFullPath(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PixelBooth", "Queue"));
        Directory.CreateDirectory(_root);
    }

    public string Root => _root;
    public int RetainedDirectoryCount => Directory.EnumerateDirectories(_root).Count();
    public static string DefaultDestination => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "PixelBooth");

    public async Task<PendingCapture> EnqueueAsync(CameraFrame frame, string destination)
    {
        await Gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var directories = Directory.GetDirectories(_root);
            var used = QueueBytes();
            var id = Guid.NewGuid();
            var pending = new PendingCapture(id, frame.Device, frame.Mode, frame.MediaTimestamp100ns, frame.ReceivedAt,
                frame.Generation, Convert.ToHexString(SHA256.HashData(frame.Bytes)), destination, frame.CodecHeader, frame.FrameMetadata, frame.Controls);
            var descriptor = JsonSerializer.SerializeToUtf8Bytes(pending);
            if (directories.Length >= MaxCaptures || used + 2L * frame.Bytes.Length + descriptor.LongLength + 1024 * 1024 > MaxBytes)
                throw new IOException("Capture storage is full. Save or recover pending photos before taking another.");
            var staging = Path.Combine(_root, "." + id.ToString("N") + ".staging");
            var committed = Path.Combine(_root, id.ToString("N"));
            Directory.CreateDirectory(staging);
            WriteDurably(Path.Combine(staging, "source.bin"), frame.Bytes);
            WriteDurably(Path.Combine(staging, "capture.json"), descriptor);
            Directory.Move(staging, committed);
            return pending;
        }
        finally { Gate.Release(); }
    }

    public IReadOnlyList<PendingCapture> Pending()
    {
        var items = new List<PendingCapture>();
        foreach (var dir in Directory.EnumerateDirectories(_root))
        {
            try
            {
                var descriptor = Path.Combine(dir, "capture.json");
                if (!File.Exists(descriptor)) continue;
                var pending = JsonSerializer.Deserialize<PendingCapture>(File.ReadAllBytes(descriptor));
                if (pending is not null && File.Exists(Path.Combine(dir, "source.bin"))) items.Add(pending);
            }
            catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { }
        }
        return items.OrderBy(x => x.ReceivedAt).ToArray();
    }

    public async Task<string> SaveAsync(PendingCapture capture)
    {
        // One pipeline at a time bounds memory and the encoder's worker budget.
        await SaveGate.WaitAsync().ConfigureAwait(false);
        try
        {
            var directory = FindDirectory(capture.Id);
            var source = await File.ReadAllBytesAsync(Path.Combine(directory, "source.bin")).ConfigureAwait(false);
            if (!string.Equals(Convert.ToHexString(SHA256.HashData(source)), capture.Sha256, StringComparison.Ordinal))
                throw new InvalidDataException("The retained camera sample failed its integrity check.");
            var frame = new CameraFrame(capture.Device, capture.Mode, source, capture.MediaTimestamp100ns, capture.ReceivedAt, 0, capture.Generation,
                capture.CodecHeader, capture.FrameMetadata, capture.Controls);
            var extension = frame.Mode.IsMjpeg ? ".jpg" : frame.Mode.IsH264 ? ".avci" : frame.Mode.FourCC is "NV12" or "YUY2" ?
                (LosslessTiff.RequiresTiff(frame.Mode) ? ".tif" : ".avif") :
                throw new NotSupportedException($"Preserving {frame.Mode.FourCC} is not yet supported; the original sample remains in the recovery queue.");
            var stagedResult = Path.Combine(directory, "final" + extension);
            var stagedHash = Path.Combine(directory, "final.sha256");
            var stagedSidecar = Path.Combine(directory, "final.xmp");
            var stagedSidecarHash = Path.Combine(directory, "final.xmp.sha256");
            byte[] result;
            byte[]? sidecar = null;
            if (File.Exists(stagedResult) && File.Exists(stagedHash))
            {
                result = await File.ReadAllBytesAsync(stagedResult).ConfigureAwait(false);
                if (!string.Equals(Convert.ToHexString(SHA256.HashData(result)), File.ReadAllText(stagedHash), StringComparison.Ordinal))
                    throw new InvalidDataException("The retained final image failed its integrity check; the source remains available.");
                if (File.Exists(stagedSidecar) != File.Exists(stagedSidecarHash))
                    throw new InvalidDataException("The retained metadata sidecar is incomplete; the source remains available.");
                if (File.Exists(stagedSidecar))
                {
                    sidecar = await File.ReadAllBytesAsync(stagedSidecar).ConfigureAwait(false);
                    if (!string.Equals(Convert.ToHexString(SHA256.HashData(sidecar)), File.ReadAllText(stagedSidecarHash), StringComparison.Ordinal))
                        throw new InvalidDataException("The retained metadata sidecar failed its integrity check; the source remains available.");
                }
            }
            else
            {
                try
                {
                    result = frame.Mode.IsMjpeg ? JpegPreserver.AddMetadata(frame, capture.Id) : frame.Mode.IsH264 ? EncodeAvci(frame, capture.Id) :
                        extension == ".tif" ? LosslessTiff.Encode(frame, capture.Id) : AvifEncoder.Encode(frame, capture.Id);
                }
                catch (JpegXmpEmbeddingException)
                {
                    // Keep all source JPEG metadata in place and put the complete
                    // PixelBooth XMP in a companion file when APP1 is too small
                    // or the existing packet cannot be safely merged.
                    result = JpegPreserver.Extract(frame.Bytes);
                    sidecar = System.Text.Encoding.UTF8.GetBytes(CaptureMetadata.NewDocument(frame, capture.Id,
                        includeStandard: JpegPreserver.CanAddStandardMetadata(frame.Bytes)).ToString());
                }
                await Gate.WaitAsync().ConfigureAwait(false);
                try
                {
                    var stagedTemporary = Path.Combine(directory, "final.tmp");
                    var hashTemporary = Path.Combine(directory, "final.sha256.tmp");
                    var sidecarTemporary = Path.Combine(directory, "final.xmp.tmp");
                    var sidecarHashTemporary = Path.Combine(directory, "final.xmp.sha256.tmp");
                    // A crash may leave an uncommitted output without its integrity marker.
                    if (File.Exists(stagedTemporary)) File.Delete(stagedTemporary);
                    if (File.Exists(hashTemporary)) File.Delete(hashTemporary);
                    if (File.Exists(stagedResult)) File.Delete(stagedResult);
                    if (File.Exists(stagedHash)) File.Delete(stagedHash);
                    if (File.Exists(stagedSidecar)) File.Delete(stagedSidecar);
                    if (File.Exists(stagedSidecarHash)) File.Delete(stagedSidecarHash);
                    if (File.Exists(sidecarTemporary)) File.Delete(sidecarTemporary);
                    if (File.Exists(sidecarHashTemporary)) File.Delete(sidecarHashTemporary);
                    if (QueueBytes() + result.LongLength + (sidecar?.LongLength ?? 0) + 128 > MaxBytes)
                        throw new IOException("Capture storage is full. Save or recover other pending photos first; the original remains in the queue.");
                    if (sidecar is not null)
                    {
                        WriteDurably(sidecarTemporary, sidecar);
                        File.Move(sidecarTemporary, stagedSidecar);
                        WriteDurably(sidecarHashTemporary, System.Text.Encoding.ASCII.GetBytes(Convert.ToHexString(SHA256.HashData(sidecar))));
                        File.Move(sidecarHashTemporary, stagedSidecarHash);
                    }
                    WriteDurably(stagedTemporary, result);
                    File.Move(stagedTemporary, stagedResult, true);
                    WriteDurably(hashTemporary, System.Text.Encoding.ASCII.GetBytes(Convert.ToHexString(SHA256.HashData(result))));
                    File.Move(hashTemporary, stagedHash);
                }
                finally { Gate.Release(); }
            }
            Directory.CreateDirectory(capture.Destination);
            var name = $"PixelBooth-{capture.ReceivedAt:yyyyMMdd-HHmmss}-{capture.Id:N}{extension}";
            var final = Path.Combine(capture.Destination, name);
            if (File.Exists(final))
            {
                var existing = await File.ReadAllBytesAsync(final).ConfigureAwait(false);
                if (!SHA256.HashData(existing).AsSpan().SequenceEqual(SHA256.HashData(result)))
                    throw new IOException("The destination already contains a different file with this capture's name.");
            }
            else
            {
                var temporary = Path.Combine(capture.Destination, "." + name + ".tmp");
                WriteDurably(temporary, result);
                File.Move(temporary, final);
            }
            if (sidecar is not null)
            {
                var finalSidecar = Path.ChangeExtension(final, ".xmp");
                if (File.Exists(finalSidecar))
                {
                    var existing = await File.ReadAllBytesAsync(finalSidecar).ConfigureAwait(false);
                    if (!SHA256.HashData(existing).AsSpan().SequenceEqual(SHA256.HashData(sidecar)))
                        throw new IOException("The destination already contains different metadata with this capture's name.");
                }
                else
                {
                    var temporarySidecar = Path.Combine(capture.Destination, "." + Path.GetFileName(finalSidecar) + ".tmp");
                    WriteDurably(temporarySidecar, sidecar);
                    File.Move(temporarySidecar, finalSidecar);
                }
            }
            var fullDirectory = Path.GetFullPath(directory);
            if (!fullDirectory.StartsWith(_root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Capture recovery path is outside the queue.");
            await Gate.WaitAsync().ConfigureAwait(false);
            try { Directory.Delete(fullDirectory, true); }
            finally { Gate.Release(); }
            return final;
        }
        finally { SaveGate.Release(); }
    }

    private static byte[] EncodeAvci(CameraFrame frame, Guid id)
    {
        var collector = new H264AccessUnitCollector();
        if (frame.CodecHeader is { Length: > 0 }) collector.Observe(frame.CodecHeader);
        var picture = collector.Observe(frame.Bytes) ?? throw new InvalidDataException("The retained H.264 sample is not a complete independently decodable IDR picture.");
        using var platform = new MediaFoundationCamera();
        using var decoder = new H264PreviewDecoder(picture.Width, picture.Height);
        var input = picture.CodecHeader.Concat(frame.Bytes).ToArray();
        if (decoder.Decode(input, frame.MediaTimestamp100ns, true) is null)
            throw new InvalidDataException("Windows could not decode the H.264 picture independently.");
        var result = AvciWriter.Write(picture, frame, id);
        AvciValidator.Validate(result, picture, System.Text.Encoding.UTF8.GetBytes(CaptureMetadata.NewDocument(frame, id).ToString()));
        return result;
    }

    private string FindDirectory(Guid id)
    {
        var committed = Path.Combine(_root, id.ToString("N"));
        if (Directory.Exists(committed)) return committed;
        var staging = Path.Combine(_root, "." + id.ToString("N") + ".staging");
        if (Directory.Exists(staging)) return staging;
        throw new DirectoryNotFoundException("The retained capture could not be found.");
    }

    private long QueueBytes() => Directory.EnumerateDirectories(_root)
        .SelectMany(d => Directory.EnumerateFiles(d, "*", SearchOption.AllDirectories)).Sum(f => new FileInfo(f).Length);

    private static void WriteDurably(string path, byte[] bytes)
    {
        using var file = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough);
        file.Write(bytes);
        file.Flush(true);
    }
}
