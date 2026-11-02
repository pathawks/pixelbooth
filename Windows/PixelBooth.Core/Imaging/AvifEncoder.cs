using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using PixelBooth.Core.Capture;

namespace PixelBooth.Core.Imaging;

/// <summary>Encodes native YCbCr channels losslessly and verifies the decoded output before returning it.</summary>
public static unsafe class AvifEncoder
{
    private static readonly SemaphoreSlim EncoderGate = new(1, 1);

    public static void ValidateMode(CameraMode mode)
    {
        RawPlanes.ValidateMode(mode);
        if (LosslessTiff.RequiresTiff(mode)) throw new InvalidDataException("This AVIF encoder cannot signal the camera's explicit chroma positioning.");
        if (mode.Matrix is not (1 or 2 or 3 or 4 or 5) || mode.NominalRange is not (1 or 2))
            throw new InvalidDataException("The camera did not report a supported YUV matrix and range.");
        if (mode.Primaries is not (null or 0 or 2 or 3 or 4 or 5 or 6 or 7 or 9 or 11 or 13) ||
            mode.Transfer is not (null or 0 or 1 or 4 or 5 or 6 or 7 or 8 or 9 or 10 or 15 or 16 or 18 or 19))
            throw new InvalidDataException("The reported color primaries or transfer function cannot be represented safely in AVIF.");
    }

    public static byte[] Encode(CameraFrame frame, Guid captureId)
    {
        ValidateMode(frame.Mode);
        var planes = RawPlanes.FromFrame(frame);
        var mode = frame.Mode;
        var matrix = mode.Matrix switch { 1 => 1, 2 => 6, 3 => 7, 4 or 5 => 9, _ => throw new InvalidDataException("The camera did not specify a supported YUV color matrix.") };
        var range = mode.NominalRange switch { 1 => 1, 2 => 0, _ => throw new InvalidDataException("The camera did not specify a supported YUV range.") };
        var primaries = mode.Primaries switch
        {
            null or 0 => 2, 2 => 1, 3 => 4, 4 => 5, 5 => 6, 6 => 7, 7 => 22, 9 => 9, 11 => 11, 13 => 12,
            _ => throw new InvalidDataException("The reported color primaries cannot be represented safely in AVIF.")
        };
        var transfer = mode.Transfer switch
        {
            null or 0 => 2, 1 => 8, 4 => 4, 5 => 1, 6 => 7, 7 => 13, 8 => 5, 9 => 9, 10 => 10,
            15 => 16, 16 => 18, 18 => 12, 19 => 17,
            _ => throw new InvalidDataException("The reported transfer function cannot be represented safely in AVIF.")
        };
        EncoderGate.Wait();
        try { return EncodeCore(frame, captureId, planes, primaries, transfer, matrix, range); }
        finally { EncoderGate.Release(); }
    }

    private static byte[] EncodeCore(CameraFrame frame, Guid captureId, RawPlanes planes, int primaries, int transfer, int matrix, int range)
    {
        IntPtr ctx = IntPtr.Zero, image = IntPtr.Zero, encoder = IntPtr.Zero, handle = IntPtr.Zero, profile = IntPtr.Zero, options = IntPtr.Zero;
        try
        {
            ctx = Native.heif_context_alloc();
            if (ctx == IntPtr.Zero) throw new OutOfMemoryException();
            Check(Native.heif_image_create(planes.Width, planes.Height, 0, planes.Chroma, out image));
            AddPlane(image, 0, planes.Width, planes.Height, planes.Y);
            AddPlane(image, 1, planes.ChromaWidth, planes.ChromaHeight, planes.Cb);
            AddPlane(image, 2, planes.ChromaWidth, planes.ChromaHeight, planes.Cr);
            profile = Native.heif_nclx_color_profile_alloc();
            if (profile == IntPtr.Zero) throw new OutOfMemoryException();
            Check(Native.heif_nclx_color_profile_set_color_primaries(profile, (ushort)primaries));
            Check(Native.heif_nclx_color_profile_set_transfer_characteristics(profile, (ushort)transfer));
            Check(Native.heif_nclx_color_profile_set_matrix_coefficients(profile, (ushort)matrix));
            // nclx v1: uint8 version, 3 aligned enums, then uint8 full_range_flag.
            Marshal.WriteByte(profile, 16, (byte)range);
            Check(Native.heif_image_set_nclx_color_profile(image, profile));
            var descriptors = new IntPtr[16];
            var descriptorCount = Native.heif_get_encoder_descriptors(4, null, descriptors, descriptors.Length);
            var aom = descriptors.Take(descriptorCount).FirstOrDefault(d => Marshal.PtrToStringAnsi(Native.heif_encoder_descriptor_get_id_name(d)) == "aom");
            if (aom == IntPtr.Zero) throw new InvalidDataException("The required libaom encoder is unavailable.");
            Check(Native.heif_context_get_encoder(ctx, aom, out encoder));
            Check(Native.heif_encoder_set_lossless(encoder, 1));
            Check(Native.heif_encoder_set_parameter_integer(encoder, "speed", 0));
            Check(Native.heif_encoder_set_parameter_integer(encoder, "threads", 2));
            Check(Native.heif_encoder_set_parameter_string(encoder, "chroma", planes.Chroma == 1 ? "420" : "422"));
            if (frame.Mode.FourCC == "NV12" && frame.Mode.ChromaSiting is 7 or 15)
                Check(Native.heif_encoder_set_parameter_string(encoder, "aom:chroma-sample-position", "colocated"));
            options = Native.heif_encoding_options_alloc();
            if (options == IntPtr.Zero) throw new OutOfMemoryException();
            Check(Native.heif_context_encode_image(ctx, image, encoder, options, out handle));
            var xmp = Encoding.UTF8.GetBytes(CaptureMetadata.NewDocument(frame, captureId, yuy2CoSited: frame.Mode.FourCC == "YUY2").ToString());
            Check(Native.heif_context_add_XMP_metadata(ctx, handle, xmp, xmp.Length));
            using var output = new MemoryStream();
            var pin = GCHandle.Alloc(output);
            try
            {
                var writer = new Writer { Version = 1, Write = &WriteToStream };
                Check(Native.heif_context_write(ctx, ref writer, GCHandle.ToIntPtr(pin)));
            }
            finally { pin.Free(); }
            var data = output.ToArray();
            if (frame.Mode.FourCC == "NV12" && frame.Mode.ChromaSiting is 7 or 15)
                AvifChromaValidator.VerifyColocated420(data);
            Verify(data, planes, primaries, transfer, matrix, range, xmp);
            return data;
        }
        finally
        {
            if (options != IntPtr.Zero) Native.heif_encoding_options_free(options);
            if (profile != IntPtr.Zero) Native.heif_nclx_color_profile_free(profile);
            if (handle != IntPtr.Zero) Native.heif_image_handle_release(handle);
            if (encoder != IntPtr.Zero) Native.heif_encoder_release(encoder);
            if (image != IntPtr.Zero) Native.heif_image_release(image);
            if (ctx != IntPtr.Zero) Native.heif_context_free(ctx);
        }
    }

    private static void AddPlane(IntPtr image, int channel, int width, int height, byte[] bytes)
    {
        Check(Native.heif_image_add_plane(image, channel, width, height, 8));
        var pointer = Native.heif_image_get_plane(image, channel, out var stride);
        if (pointer == IntPtr.Zero || stride < width) throw new InvalidDataException("The AVIF encoder returned an invalid plane.");
        for (var row = 0; row < height; row++) Marshal.Copy(bytes, row * width, IntPtr.Add(pointer, checked(row * stride)), width);
    }

    private static void Verify(byte[] data, RawPlanes expected, int primaries, int transfer, int matrix, int range, byte[] expectedXmp)
    {
        IntPtr ctx = IntPtr.Zero, handle = IntPtr.Zero, image = IntPtr.Zero, profile = IntPtr.Zero;
        var pin = GCHandle.Alloc(data, GCHandleType.Pinned);
        try
        {
            ctx = Native.heif_context_alloc();
            if (ctx == IntPtr.Zero) throw new OutOfMemoryException();
            Check(Native.heif_context_read_from_memory_without_copy(ctx, pin.AddrOfPinnedObject(), (nuint)data.Length, IntPtr.Zero));
            Check(Native.heif_context_get_primary_image_handle(ctx, out handle));
            var metadataIds = new uint[1];
            if (Native.heif_image_handle_get_number_of_metadata_blocks(handle, null) != 1 ||
                Native.heif_image_handle_get_list_of_metadata_block_IDs(handle, null, metadataIds, 1) != 1 ||
                Native.heif_image_handle_get_metadata_size(handle, metadataIds[0]) != (nuint)expectedXmp.Length ||
                Marshal.PtrToStringAnsi(Native.heif_image_handle_get_metadata_content_type(handle, metadataIds[0])) != "application/rdf+xml")
                throw new InvalidDataException("AVIF XMP metadata did not round-trip.");
            var xmp = new byte[expectedXmp.Length];
            Check(Native.heif_image_handle_get_metadata(handle, metadataIds[0], xmp));
            if (!xmp.AsSpan().SequenceEqual(expectedXmp)) throw new InvalidDataException("AVIF XMP metadata changed.");
            Check(Native.heif_image_handle_get_nclx_color_profile(handle, out profile));
            if (Marshal.ReadInt32(profile, 4) != primaries || Marshal.ReadInt32(profile, 8) != transfer ||
                Marshal.ReadInt32(profile, 12) != matrix || Marshal.ReadByte(profile, 16) != range)
                throw new InvalidDataException("AVIF color metadata did not round-trip.");
            Check(Native.heif_decode_image(handle, out image, 99, 99, IntPtr.Zero));
            if (Native.heif_image_get_colorspace(image) != 0 || Native.heif_image_get_chroma_format(image) != expected.Chroma)
                throw new InvalidDataException("AVIF decoded with a different color space or chroma sampling.");
            Compare(image, 0, expected.Width, expected.Height, expected.Y);
            Compare(image, 1, expected.ChromaWidth, expected.ChromaHeight, expected.Cb);
            Compare(image, 2, expected.ChromaWidth, expected.ChromaHeight, expected.Cr);
        }
        finally
        {
            if (profile != IntPtr.Zero) Native.heif_nclx_color_profile_free(profile);
            if (image != IntPtr.Zero) Native.heif_image_release(image);
            if (handle != IntPtr.Zero) Native.heif_image_handle_release(handle);
            if (ctx != IntPtr.Zero) Native.heif_context_free(ctx);
            pin.Free();
        }
    }

    private static void Compare(IntPtr image, int channel, int width, int height, byte[] expected)
    {
        if (Native.heif_image_get_width(image, channel) != width || Native.heif_image_get_height(image, channel) != height ||
            Native.heif_image_get_bits_per_pixel_range(image, channel) != 8)
            throw new InvalidDataException("AVIF decoded with a different channel layout.");
        var pointer = Native.heif_image_get_plane_readonly(image, channel, out var stride);
        if (pointer == IntPtr.Zero || stride < width) throw new InvalidDataException("Invalid decoded AVIF plane.");
        for (int row = 0; row < height; row++)
            if (!new ReadOnlySpan<byte>((void*)IntPtr.Add(pointer, checked(row * stride)), width).SequenceEqual(expected.AsSpan(row * width, width)))
                throw new InvalidDataException("AVIF sample verification failed; the source was retained.");
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static Error WriteToStream(IntPtr context, IntPtr data, nuint size, IntPtr user)
    {
        try
        {
            var stream = (MemoryStream)GCHandle.FromIntPtr(user).Target!;
            if (size > int.MaxValue || stream.Length + (long)size > 512L * 1024 * 1024) return new Error { Code = 2 };
            stream.Write(new ReadOnlySpan<byte>((void*)data, (int)size));
            return default;
        }
        catch { return new Error { Code = 2 }; }
    }

    private static void Check(Error error)
    {
        if (error.Code != 0) throw new InvalidDataException($"AVIF error {error.Code}/{error.Subcode}: {Marshal.PtrToStringAnsi(error.Message) ?? "unknown"}");
    }
    [StructLayout(LayoutKind.Sequential)] private struct Error { public int Code, Subcode; public IntPtr Message; }
    [StructLayout(LayoutKind.Sequential)] private struct Writer { public int Version; public delegate* unmanaged[Cdecl]<IntPtr, IntPtr, nuint, IntPtr, Error> Write; }

    private static class Native
    {
        private const string Dll = "libheif";
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_context_alloc();
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern void heif_context_free(IntPtr ctx);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_image_create(int w, int h, int color, int chroma, out IntPtr image);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern void heif_image_release(IntPtr image);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_image_add_plane(IntPtr image, int channel, int w, int h, int depth);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_image_get_plane(IntPtr image, int channel, out int stride);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_image_get_plane_readonly(IntPtr image, int channel, out int stride);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern int heif_image_get_width(IntPtr image, int channel);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern int heif_image_get_colorspace(IntPtr image);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern int heif_image_get_chroma_format(IntPtr image);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern int heif_image_get_height(IntPtr image, int channel);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern int heif_image_get_bits_per_pixel_range(IntPtr image, int channel);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_nclx_color_profile_alloc();
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern void heif_nclx_color_profile_free(IntPtr p);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_nclx_color_profile_set_color_primaries(IntPtr p, ushort v);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_nclx_color_profile_set_transfer_characteristics(IntPtr p, ushort v);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_nclx_color_profile_set_matrix_coefficients(IntPtr p, ushort v);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_image_set_nclx_color_profile(IntPtr image, IntPtr p);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_image_handle_get_nclx_color_profile(IntPtr handle, out IntPtr p);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern int heif_get_encoder_descriptors(int format, string? name, [Out] IntPtr[] descriptors, int count);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_encoder_descriptor_get_id_name(IntPtr descriptor);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_context_get_encoder(IntPtr ctx, IntPtr descriptor, out IntPtr encoder);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern void heif_encoder_release(IntPtr encoder);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_encoder_set_lossless(IntPtr encoder, int enabled);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_encoding_options_alloc();
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern void heif_encoding_options_free(IntPtr options);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern Error heif_encoder_set_parameter_integer(IntPtr encoder, string name, int value);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern Error heif_encoder_set_parameter_string(IntPtr encoder, string name, string value);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_context_encode_image(IntPtr ctx, IntPtr image, IntPtr encoder, IntPtr options, out IntPtr handle);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_context_add_XMP_metadata(IntPtr ctx, IntPtr handle, byte[] data, int size);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_context_write(IntPtr ctx, ref Writer writer, IntPtr user);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_context_read_from_memory_without_copy(IntPtr ctx, IntPtr data, nuint size, IntPtr options);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_context_get_primary_image_handle(IntPtr ctx, out IntPtr handle);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern void heif_image_handle_release(IntPtr handle);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern int heif_image_handle_get_number_of_metadata_blocks(IntPtr p, string? filter);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)] internal static extern int heif_image_handle_get_list_of_metadata_block_IDs(IntPtr p, string? filter, [Out] uint[] ids, int count);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern nuint heif_image_handle_get_metadata_size(IntPtr p, uint id);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr heif_image_handle_get_metadata_content_type(IntPtr p, uint id);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_image_handle_get_metadata(IntPtr p, uint id, [Out] byte[] data);
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] internal static extern Error heif_decode_image(IntPtr handle, out IntPtr image, int color, int chroma, IntPtr options);
    }
}
