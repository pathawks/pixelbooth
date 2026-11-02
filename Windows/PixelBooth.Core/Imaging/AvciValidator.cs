using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Text;

namespace PixelBooth.Core.Imaging;

/// <summary>Checks the HEIF structure with libheif and compares the coded picture and parameter sets byte for byte.</summary>
public static class AvciValidator
{
    public static void Validate(byte[] data, H264Picture picture, byte[]? expectedXmp = null)
    {
        var pin = GCHandle.Alloc(data, GCHandleType.Pinned); var context = Native.heif_context_alloc(); var handle = IntPtr.Zero;
        if (context == IntPtr.Zero) { pin.Free(); throw new OutOfMemoryException(); }
        try
        {
            Check(Native.heif_context_read_from_memory_without_copy(context, pin.AddrOfPinnedObject(), (nuint)data.Length, IntPtr.Zero));
            Check(Native.heif_context_get_primary_image_handle(context, out handle));
            if (Native.heif_image_handle_get_width(handle) != picture.Width || Native.heif_image_handle_get_height(handle) != picture.Height ||
                Native.heif_image_handle_get_number_of_metadata_blocks(handle, null) != 1)
                throw new InvalidDataException("The AVCI image dimensions or XMP metadata could not be verified.");
            var ids = new uint[1];
            if (Native.heif_image_handle_get_list_of_metadata_block_IDs(handle, null, ids, 1) != 1 ||
                Marshal.PtrToStringAnsi(Native.heif_image_handle_get_metadata_content_type(handle, ids[0])) != "application/rdf+xml")
                throw new InvalidDataException("The AVCI XMP item could not be verified.");
            var size = Native.heif_image_handle_get_metadata_size(handle, ids[0]);
            if (size == 0 || size > 1024 * 1024) throw new InvalidDataException("Invalid AVCI XMP size.");
            var xmp = new byte[(int)size];
            Check(Native.heif_image_handle_get_metadata(handle, ids[0], xmp));
            if (expectedXmp is not null && !xmp.AsSpan().SequenceEqual(expectedXmp))
                throw new InvalidDataException("AVCI XMP metadata changed during container writing.");
        }
        finally
        {
            if (handle != IntPtr.Zero) Native.heif_image_handle_release(handle);
            Native.heif_context_free(context); pin.Free();
        }
        var top = Boxes(data, 0, data.Length);
        var meta = One(top, "meta"); var mdat = One(top, "mdat");
        var iprp = One(Boxes(data, meta.Start + 4, meta.End), "iprp");
        var ipco = One(Boxes(data, iprp.Start, iprp.End), "ipco");
        var avcc = One(Boxes(data, ipco.Start, ipco.End), "avcC");
        var position = avcc.Start;
        if (avcc.End - position < 7 || data[position] != 1 || (data[position + 4] & 3) != 3 || (data[position + 5] & 31) != 1)
            throw new InvalidDataException("Invalid AVC decoder configuration.");
        position += 6;
        ReadUnit16(data, ref position, avcc.End, picture.Sps);
        if (position >= avcc.End || data[position++] != 1) throw new InvalidDataException("Invalid AVC picture parameter set count.");
        ReadUnit16(data, ref position, avcc.End, picture.Pps);
        position = mdat.Start;
        foreach (var nal in picture.NalUnits)
        {
            if (position + 4 > mdat.End) throw new InvalidDataException("Truncated AVC image item.");
            var size = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(position, 4)); position += 4;
            if (size != nal.Length || size > mdat.End - position || !data.AsSpan(position, (int)size).SequenceEqual(nal))
                throw new InvalidDataException("AVC image-coding data changed during container writing.");
            position += (int)size;
        }
    }

    private static void ReadUnit16(byte[] data, ref int position, int end, byte[] expected)
    {
        if (position + 2 > end) throw new InvalidDataException("Truncated AVC parameter set.");
        var size = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(position, 2)); position += 2;
        if (size != expected.Length || position + size > end || !data.AsSpan(position, size).SequenceEqual(expected))
            throw new InvalidDataException("AVC parameter set changed during container writing.");
        position += size;
    }
    private sealed record Box(string Type, int Start, int End);
    private static Box One(IEnumerable<Box> boxes, string type) => boxes.SingleOrDefault(b => b.Type == type) ?? throw new InvalidDataException($"AVCI {type} box is missing.");
    private static List<Box> Boxes(byte[] data, int start, int end)
    {
        var result = new List<Box>();
        while (start < end)
        {
            if (end - start < 8) throw new InvalidDataException("Truncated HEIF box.");
            var length = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(start, 4));
            if (length < 8 || length > end - start) throw new InvalidDataException("Invalid HEIF box size.");
            var type = Encoding.ASCII.GetString(data, start + 4, 4);
            result.Add(new Box(type, start + 8, checked(start + (int)length)));
            start += (int)length;
        }
        return result;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Error { public int Code, Subcode; public IntPtr Message; }
    private static void Check(Error error) { if (error.Code != 0) throw new InvalidDataException($"HEIF validation error {error.Code}/{error.Subcode}: {Marshal.PtrToStringAnsi(error.Message)}"); }
    private static class Native
    {
        private const string Dll = "libheif";
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_context_alloc();
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern void heif_context_free(IntPtr p);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_context_read_from_memory_without_copy(IntPtr p, IntPtr data, nuint size, IntPtr options);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_context_get_primary_image_handle(IntPtr p, out IntPtr handle);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern int heif_image_handle_get_width(IntPtr handle);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern int heif_image_handle_get_height(IntPtr handle);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern int heif_image_handle_get_number_of_metadata_blocks(IntPtr handle, string? filter);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern int heif_image_handle_get_list_of_metadata_block_IDs(IntPtr handle, string? filter, [Out] uint[] ids, int count);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern nuint heif_image_handle_get_metadata_size(IntPtr handle, uint id);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_image_handle_get_metadata_content_type(IntPtr handle, uint id);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_image_handle_get_metadata(IntPtr handle, uint id, [Out] byte[] data);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern void heif_image_handle_release(IntPtr p);
    }
}
