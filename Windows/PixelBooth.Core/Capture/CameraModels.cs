namespace PixelBooth.Core.Capture;

public sealed record CameraDevice(string Id, string Name)
{
    public override string ToString() => Name;
}

public sealed record CameraMode(
    int Index, Guid Subtype, string FourCC, int Width, int Height,
    int RateNumerator, int RateDenominator, int? Stride, int? InterlaceMode,
    int? Primaries, int? Transfer, int? Matrix, int? NominalRange, byte[]? SequenceHeader = null, int? ChromaSiting = null)
{
    public double FramesPerSecond => RateDenominator > 0 ? (double)RateNumerator / RateDenominator : 0;
    public string Id => $"{Subtype:D}|{Width}|{Height}|{RateNumerator}|{RateDenominator}|{Stride}|{InterlaceMode}|{Primaries}|{Transfer}|{Matrix}|{NominalRange}|{ChromaSiting}";
    public bool IsMjpeg => FourCC is "MJPG" or "JPEG";
    public bool IsH264 => FourCC is "H264" or "h264" or "AVC1" or "avc1";
    public bool IsRaw => FourCC is "YUY2" or "NV12";
    public override string ToString()
    {
        var detail = FourCC switch { "NV12" => "8-bit 4:2:0", "YUY2" => "8-bit 4:2:2", _ => "depth/chroma unknown" };
        var range = NominalRange switch { 1 => "full", 2 => "limited", _ => "range unknown" };
        var siting = IsRaw ? $"  ·  siting {ChromaSiting?.ToString() ?? "unknown"}" : "";
        return $"{Width} × {Height}  ·  {FourCC}  ·  {detail}  ·  {range}{siting}  ·  {(FramesPerSecond > 0 ? $"{FramesPerSecond:0.##} fps" : "frame rate unknown")}";
    }
}

// Bytes are a private copy of the sample; preview and subsequent reads never mutate it.
public sealed record CameraFrame(CameraDevice Device, CameraMode Mode, byte[] Bytes,
    long MediaTimestamp100ns, DateTimeOffset ReceivedAt, long MonotonicTimestamp, long Generation, byte[]? CodecHeader = null,
    FrameCaptureMetadata? FrameMetadata = null, CameraControlSnapshot? Controls = null);

// Values in this collection came from attributes attached to the delivered sample.
// The original Media Foundation type and value are retained rather than guessed.
public sealed record FrameMetadataValue(string Name, string Type, string Value);
public sealed record FrameCaptureMetadata(FrameMetadataValue[] Values);

// These are control reads, not measurements tied to the delivered frame. Each read
// has its own timestamp because automatic controls can change between frames.
public sealed record CameraControlObservation(string Name, Guid PropertySet, uint PropertyId,
    int Value, uint? Flags, uint? Capabilities, DateTimeOffset ObservedAt, string? Unit = null);
public sealed record CameraControlSnapshot(DateTimeOffset StartedAt, DateTimeOffset CompletedAt,
    CameraControlObservation[] Values, string Status);
