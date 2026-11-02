using System.Runtime.InteropServices;
using MediaFoundation;
using MediaFoundation.ReadWrite;

namespace PixelBooth.Core.Capture;

/// <summary>Opens the source reader with a camera-reported type and no video processing.</summary>
public sealed class MediaFoundationCamera : IDisposable
{
    private const int VideoStream = unchecked((int)0xfffffffc);
    private static readonly object StartupLock = new();
    private static bool _started;
    private IMFMediaSource? _source;
    private IMFSourceReader? _reader;
    private IMFActivate? _activation;

    public MediaFoundationCamera()
    {
        lock (StartupLock)
        {
            if (!_started)
            {
                Check(MFExtern.MFStartup(0x20070, MFStartup.Full));
                _started = true;
            }
        }
    }

    public static IReadOnlyList<CameraDevice> Discover()
    {
        using var platform = new MediaFoundationCamera();
        var activations = Enumerate();
        try
        {
            var result = new List<CameraDevice>();
            foreach (var activation in activations)
            {
                Check(activation.GetAllocatedString(MFAttributesClsid.MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, out var name, out _));
                Check(activation.GetAllocatedString(MFAttributesClsid.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, out var id, out _));
                result.Add(new CameraDevice(id, name));
            }
            return result;
        }
        finally { foreach (var a in activations) Release(a); }
    }

    public IReadOnlyList<CameraMode> Open(CameraDevice device)
    {
        Dispose();
        var activations = Enumerate();
        IMFActivate? chosen = null;
        try
        {
            foreach (var activation in activations)
            {
                Check(activation.GetAllocatedString(MFAttributesClsid.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, out var id, out _));
                if (string.Equals(id, device.Id, StringComparison.OrdinalIgnoreCase))
                {
                    _activation = activation;
                    chosen = activation;
                    break;
                }
            }
            if (_activation is null) throw new InvalidOperationException("The selected camera is no longer connected.");
            Check(_activation.ActivateObject(typeof(IMFMediaSource).GUID, out var source));
            _source = (IMFMediaSource)source;
            Check(MFExtern.MFCreateSourceReaderFromMediaSource(_source, null!, out var reader));
            _reader = reader;
            var modes = new List<CameraMode>();
            for (var i = 0; i < 2048; i++)
            {
                var hr = _reader.GetNativeMediaType(VideoStream, i, out var type);
                if ((int)hr < 0) break;
                try { modes.Add(ReadMode(type, i)); }
                finally { Release(type); }
            }
            return modes;
        }
        catch { Dispose(); throw; }
        finally
        {
            foreach (var activation in activations)
                if (!ReferenceEquals(activation, chosen)) Release(activation);
        }
    }

    public CameraMode SetMode(CameraMode mode)
    {
        if (_reader is null) throw new InvalidOperationException("Camera is not open.");
        Check(_reader.GetNativeMediaType(VideoStream, mode.Index, out var type));
        try
        {
            var actual = ReadMode(type, mode.Index);
            if (actual.Id != mode.Id) throw new InvalidOperationException("The selected camera mode changed; choose it again.");
            Check(_reader.SetCurrentMediaType(VideoStream, null!, type));
            Check(_reader.GetCurrentMediaType(VideoStream, out var current));
            try
            {
                var negotiated = ReadMode(current, mode.Index);
                if (negotiated.Id != mode.Id) throw new InvalidOperationException("The camera negotiated a different format; capture was stopped.");
                return negotiated;
            }
            finally { Release(current); }
        }
        finally { Release(type); }
    }

    public CameraFrame? Read(CameraDevice device, CameraMode mode, long generation)
    {
        if (_reader is null) throw new InvalidOperationException("Camera is not open.");
        Check(_reader.ReadSample(VideoStream, MF_SOURCE_READER_CONTROL_FLAG.None, out _, out var flags, out var time, out var sample));
        if ((flags & (MF_SOURCE_READER_FLAG.Error | MF_SOURCE_READER_FLAG.EndOfStream |
                      MF_SOURCE_READER_FLAG.NativeMediaTypeChanged | MF_SOURCE_READER_FLAG.CurrentMediaTypeChanged)) != 0)
        {
            if (sample is not null) Release(sample);
            throw new InvalidOperationException($"Camera stream stopped or changed format ({flags}).");
        }
        if (sample is null) return null;
        var receivedAt = DateTimeOffset.Now;
        var monotonic = System.Diagnostics.Stopwatch.GetTimestamp();
        try
        {
            var metadata = FrameMetadataReader.Read(sample);
            Check(sample.ConvertToContiguousBuffer(out var buffer));
            try
            {
                Check(buffer.Lock(out var pointer, out _, out var length));
                try
                {
                    if (length <= 0 || length > 256 * 1024 * 1024) throw new InvalidDataException("Invalid camera sample size.");
                    var bytes = new byte[length];
                    Marshal.Copy(pointer, bytes, 0, length);
                    return new CameraFrame(device, mode, bytes, time, receivedAt, monotonic, generation, FrameMetadata: metadata);
                }
                finally { buffer.Unlock(); }
            }
            finally { Release(buffer); }
        }
        finally { Release(sample); }
    }

    public CameraControlSnapshot ReadControls() =>
        _source is null ? throw new InvalidOperationException("Camera is not open.") : CameraControlReader.Read(_source);

    public void Dispose()
    {
        if (_reader is not null) { Release(_reader); _reader = null; }
        if (_source is not null) { _source.Shutdown(); Release(_source); _source = null; }
        if (_activation is not null) { _activation.ShutdownObject(); Release(_activation); _activation = null; }
    }

    private static IMFActivate[] Enumerate()
    {
        Check(MFExtern.MFCreateAttributes(out var attributes, 1));
        try
        {
            Check(attributes.SetGUID(MFAttributesClsid.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, CLSID.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID));
            Check(MFExtern.MFEnumDeviceSources(attributes, out var devices, out _));
            return devices ?? [];
        }
        finally { Release(attributes); }
    }

    private static CameraMode ReadMode(IMFMediaType type, int index)
    {
        Check(type.GetGUID(MFAttributesClsid.MF_MT_SUBTYPE, out var subtype));
        Check(type.GetUINT64(MFAttributesClsid.MF_MT_FRAME_SIZE, out var size));
        type.GetUINT64(MFAttributesClsid.MF_MT_FRAME_RATE, out var rate);
        var bytes = subtype.ToByteArray();
        var fourcc = System.Text.Encoding.ASCII.GetString(bytes, 0, 4);
        if (fourcc.Any(c => c < 32 || c > 126)) fourcc = subtype.ToString("D");
        int? Attribute(Guid key) => (int)type.GetUINT32(key, out var value) >= 0 ? value : null;
        byte[]? sequenceHeader = null;
        if ((int)type.GetBlobSize(MFAttributesClsid.MF_MT_MPEG_SEQUENCE_HEADER, out var blobLength) >= 0 && blobLength is > 0 and <= 1048576)
        {
            sequenceHeader = new byte[blobLength];
            if ((int)type.GetBlob(MFAttributesClsid.MF_MT_MPEG_SEQUENCE_HEADER, sequenceHeader, blobLength, out var actual) < 0 || actual != blobLength)
                sequenceHeader = null;
        }
        return new CameraMode(index, subtype, fourcc, unchecked((int)(size >> 32)), unchecked((int)size),
            unchecked((int)(rate >> 32)), unchecked((int)rate), Attribute(MFAttributesClsid.MF_MT_DEFAULT_STRIDE),
            Attribute(MFAttributesClsid.MF_MT_INTERLACE_MODE), Attribute(MFAttributesClsid.MF_MT_VIDEO_PRIMARIES),
            Attribute(MFAttributesClsid.MF_MT_TRANSFER_FUNCTION), Attribute(MFAttributesClsid.MF_MT_YUV_MATRIX),
            Attribute(MFAttributesClsid.MF_MT_VIDEO_NOMINAL_RANGE), sequenceHeader, Attribute(MFAttributesClsid.MF_MT_VIDEO_CHROMA_SITING));
    }

    private static void Check(HResult hr) { if ((int)hr < 0) Marshal.ThrowExceptionForHR((int)hr); }
    private static void Release(object o) { if (Marshal.IsComObject(o)) Marshal.ReleaseComObject(o); }
}
