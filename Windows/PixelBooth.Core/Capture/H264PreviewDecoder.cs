using System.Runtime.InteropServices;
using MediaFoundation;
using MediaFoundation.Transform;

namespace PixelBooth.Core.Capture;

/// <summary>Windows' H.264 decoder is used only for display and validation, never for archival output.</summary>
public sealed class H264PreviewDecoder : IDisposable
{
    private readonly IMFTransform _decoder;
    private int _width;
    private int _height;
    private readonly int _expectedWidth;
    private readonly int _expectedHeight;

    public H264PreviewDecoder(int width, int height)
    {
        _width = _expectedWidth = width; _height = _expectedHeight = height;
        _decoder = (IMFTransform)new MSH264DecoderMFT();
        Check(MFExtern.MFCreateMediaType(out var input));
        try
        {
            Check(input.SetGUID(MFAttributesClsid.MF_MT_MAJOR_TYPE, MFMediaType.Video));
            Check(input.SetGUID(MFAttributesClsid.MF_MT_SUBTYPE, MFMediaType.H264));
            Check(input.SetUINT64(MFAttributesClsid.MF_MT_FRAME_SIZE, ((long)width << 32) | (uint)height));
            Check(input.SetUINT32(MFAttributesClsid.MF_MT_INTERLACE_MODE, 7));
            Check(_decoder.SetInputType(0, input, MFTSetTypeFlags.None));
        }
        finally { Release(input); }
        SetOutputType();
        Check(_decoder.ProcessMessage(MFTMessageType.NotifyBeginStreaming, IntPtr.Zero));
        Check(_decoder.ProcessMessage(MFTMessageType.NotifyStartOfStream, IntPtr.Zero));
    }

    public byte[]? Decode(byte[] annexB, long timestamp100ns, bool drain = false)
    {
        Check(MFExtern.MFCreateSample(out var input));
        try
        {
            Check(MFExtern.MFCreateMemoryBuffer(annexB.Length, out var buffer));
            try
            {
                Check(buffer.Lock(out var pointer, out _, out _));
                try { Marshal.Copy(annexB, 0, pointer, annexB.Length); }
                finally { buffer.Unlock(); }
                Check(buffer.SetCurrentLength(annexB.Length));
                Check(input.AddBuffer(buffer));
                Check(input.SetSampleTime(timestamp100ns));
                Check(input.SetSampleDuration(333333));
                var hr = _decoder.ProcessInput(0, input, 0);
                byte[]? output = null;
                if ((int)hr == unchecked((int)0xc00d36b5)) { output = Pull(); hr = _decoder.ProcessInput(0, input, 0); }
                Check(hr);
                output = Pull() ?? output;
                if (drain)
                {
                    Check(_decoder.ProcessMessage(MFTMessageType.CommandDrain, IntPtr.Zero));
                    output = Pull() ?? output;
                }
                return output;
            }
            finally { Release(buffer); }
        }
        finally { Release(input); }
    }

    private byte[]? Pull()
    {
        byte[]? latest = null;
        for (var attempt = 0; attempt < 16; attempt++)
        {
            Check(_decoder.GetOutputStreamInfo(0, out var info));
            IMFSample? sample = null; IntPtr samplePointer = IntPtr.Zero; IntPtr providedPointer = IntPtr.Zero;
            try
            {
                if ((info.dwFlags & MFTOutputStreamInfoFlags.ProvidesSamples) == 0)
                {
                    Check(MFExtern.MFCreateSample(out sample));
                    Check(MFExtern.MFCreateMemoryBuffer(Math.Max(info.cbSize, checked(_width * _height * 3 / 2)), out var buffer));
                    try { Check(sample.AddBuffer(buffer)); }
                    finally { Release(buffer); }
                    samplePointer = Marshal.GetIUnknownForObject(sample);
                }
                var buffers = new[] { new MFTOutputDataBuffer { dwStreamID = 0, pSample = samplePointer } };
                var hr = _decoder.ProcessOutput(MFTProcessOutputFlags.None, 1, buffers, out _);
                if (buffers[0].pEvents is not null) Release(buffers[0].pEvents);
                if ((int)hr == unchecked((int)0xc00d6d72)) return latest;
                if ((int)hr == unchecked((int)0xc00d6d61)) { SetOutputType(); continue; }
                Check(hr);
                if (sample is null && buffers[0].pSample != IntPtr.Zero)
                {
                    providedPointer = buffers[0].pSample;
                    sample = (IMFSample)Marshal.GetObjectForIUnknown(providedPointer);
                }
                if (sample is null) return latest;
                Check(sample.ConvertToContiguousBuffer(out var data));
                try
                {
                    Check(data.Lock(out var pointer, out _, out var length));
                    try
                    {
                        if (length != checked(_width * _height * 3 / 2)) throw new InvalidDataException("The H.264 preview has an unsupported stride or size.");
                        latest = new byte[length]; Marshal.Copy(pointer, latest, 0, length);
                    }
                    finally { data.Unlock(); }
                }
                finally { Release(data); }
            }
            finally
            {
                if (samplePointer != IntPtr.Zero) Marshal.Release(samplePointer);
                if (providedPointer != IntPtr.Zero) Marshal.Release(providedPointer);
                if (sample is not null) Release(sample);
            }
        }
        return latest;
    }

    private void SetOutputType()
    {
        for (var i = 0; i < 64; i++)
        {
            var hr = _decoder.GetOutputAvailableType(0, i, out var type);
            if ((int)hr < 0) break;
            try
            {
                Check(type.GetGUID(MFAttributesClsid.MF_MT_SUBTYPE, out var subtype));
                if (subtype != MFMediaType.NV12) continue;
                Check(_decoder.SetOutputType(0, type, MFTSetTypeFlags.None));
                if ((int)type.GetUINT64(MFAttributesClsid.MF_MT_FRAME_SIZE, out var size) >= 0)
                {
                    _width = checked((int)(size >> 32)); _height = unchecked((int)size);
                    if (_width != _expectedWidth || _height != _expectedHeight)
                        throw new InvalidDataException("The H.264 decoder changed the preview dimensions.");
                }
                return;
            }
            finally { Release(type); }
        }
        throw new NotSupportedException("The Windows H.264 decoder did not offer NV12 preview output.");
    }

    public void Dispose() { _decoder.ProcessMessage(MFTMessageType.NotifyEndStreaming, IntPtr.Zero); Release(_decoder); }
    private static void Check(HResult hr) { if ((int)hr < 0) Marshal.ThrowExceptionForHR((int)hr); }
    private static void Release(object o) { if (Marshal.IsComObject(o)) Marshal.ReleaseComObject(o); }
}
