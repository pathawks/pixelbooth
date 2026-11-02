using System.Runtime.InteropServices;

internal static class HeifProbe
{
    [StructLayout(LayoutKind.Sequential)] private struct Error { public int Code, Subcode; public IntPtr Message; }
    [DllImport("libheif", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr heif_context_alloc();
    [DllImport("libheif", CallingConvention = CallingConvention.Cdecl)] private static extern void heif_context_free(IntPtr p);
    [DllImport("libheif", CallingConvention = CallingConvention.Cdecl)] private static extern Error heif_context_read_from_memory_without_copy(IntPtr p, IntPtr data, nuint size, IntPtr options);
    [DllImport("libheif", CallingConvention = CallingConvention.Cdecl)] private static extern Error heif_context_get_primary_image_handle(IntPtr p, out IntPtr handle);
    [DllImport("libheif", CallingConvention = CallingConvention.Cdecl)] private static extern int heif_image_handle_get_width(IntPtr handle);
    [DllImport("libheif", CallingConvention = CallingConvention.Cdecl)] private static extern int heif_image_handle_get_height(IntPtr handle);
    [DllImport("libheif", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] private static extern int heif_image_handle_get_number_of_metadata_blocks(IntPtr handle, string? filter);
    [DllImport("libheif", CallingConvention = CallingConvention.Cdecl)] private static extern void heif_image_handle_release(IntPtr p);

    public static void Inspect(byte[] data, int width, int height)
    {
        var pin = GCHandle.Alloc(data, GCHandleType.Pinned); var ctx = heif_context_alloc(); var handle = IntPtr.Zero;
        try
        {
            Check(heif_context_read_from_memory_without_copy(ctx, pin.AddrOfPinnedObject(), (nuint)data.Length, IntPtr.Zero));
            Check(heif_context_get_primary_image_handle(ctx, out handle));
            if (heif_image_handle_get_width(handle) != width || heif_image_handle_get_height(handle) != height || heif_image_handle_get_number_of_metadata_blocks(handle, null) != 1)
                throw new InvalidDataException("HEIF image properties or metadata are missing.");
        }
        finally { if (handle != IntPtr.Zero) heif_image_handle_release(handle); heif_context_free(ctx); pin.Free(); }
    }
    private static void Check(Error error)
    {
        if (error.Code != 0) throw new InvalidDataException($"HEIF {error.Code}/{error.Subcode}: {Marshal.PtrToStringAnsi(error.Message)}");
    }
}
