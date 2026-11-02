using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;
using PixelBooth.Core.Capture;

namespace PixelBooth.Core.Imaging;

/// <summary>Stores native 8-bit YCbCr samples in a Deflate-compressed TIFF with explicit sampling and positioning.</summary>
public static class LosslessTiff
{
    private sealed record Entry(ushort Tag, ushort Type, uint Count, byte[] Value);

    // YUY2 is interpreted as co-sited by application policy and can use 4:2:2 AVIF.
    // Centered NV12 positioning still needs TIFF; co-sited NV12 can use AVIF.
    public static bool RequiresTiff(CameraMode mode) => mode.FourCC == "NV12" && mode.ChromaSiting is > 0 and not (7 or 15);

    public static void ValidateMode(CameraMode mode)
    {
        RawPlanes.ValidateMode(mode);
        var siting = mode.ChromaSiting.GetValueOrDefault() & 7;
        if (mode.FourCC == "NV12" ? siting is not (1 or 7) : siting is not (3 or 7))
            throw new InvalidDataException("The camera's chroma positioning cannot be expressed faithfully in TIFF.");
        if (mode.Matrix is not (1 or 2) || mode.NominalRange is not (1 or 2))
            throw new InvalidDataException("The camera did not report a supported YUV matrix and range.");
        if (mode.Primaries is not (null or 0 or 2) || mode.Transfer is not (null or 0 or 1 or 4 or 5 or 6 or 7 or 8))
            throw new InvalidDataException("The reported color primaries or transfer function cannot yet be represented in TIFF.");
    }

    public static byte[] Encode(CameraFrame frame, Guid captureId)
    {
        ValidateMode(frame.Mode);
        var planes = RawPlanes.FromFrame(frame);
        var mode = frame.Mode;
        var siting = mode.ChromaSiting.GetValueOrDefault() & 7; // Bit 8 only indicates progressive chroma.
        var position = planes.Chroma == 1 ? siting switch
        {
            1 => 1, // MPEG-1: Cb and Cr centered in the 2x2 luma block.
            7 => 2, // Co-sited Cb and Cr at the upper-left luma sample.
            _ => throw new InvalidDataException("This 4:2:0 chroma positioning cannot be expressed faithfully in TIFF; the camera sample was retained.")
        } : siting switch
        {
            3 => 1, // Horizontally centered, vertically co-sited and aligned.
            7 => 2, // Horizontally and vertically co-sited and aligned.
            _ => throw new InvalidDataException("This 4:2:2 chroma positioning cannot be expressed faithfully in TIFF; the camera sample was retained.")
        };
        var coefficients = mode.Matrix switch
        {
            1 => new uint[] { 2126, 7152, 722, 10000 },
            2 => new uint[] { 299, 587, 114, 1000 },
            _ => throw new InvalidDataException("The camera did not specify a YUV matrix that can be represented in TIFF.")
        };
        var range = mode.NominalRange switch
        {
            1 => new uint[] { 0, 255, 128, 255, 128, 255 },
            2 => new uint[] { 16, 235, 128, 240, 128, 240 },
            _ => throw new InvalidDataException("The camera did not specify a YUV range that can be represented in TIFF.")
        };
        if (mode.Primaries is not (null or 0 or 2))
            throw new InvalidDataException("The reported color primaries cannot yet be represented in TIFF.");
        if (mode.Transfer is not (null or 0 or 1 or 4 or 5 or 6 or 7 or 8))
            throw new InvalidDataException("The reported transfer function cannot yet be represented in TIFF.");

        using var packed = new MemoryStream();
        var vertical = planes.Chroma == 1 ? 2 : 1;
        for (var row = 0; row < planes.Height; row += vertical)
        for (var col = 0; col < planes.Width; col += 2)
        {
            for (var y = 0; y < vertical; y++)
            {
                packed.WriteByte(planes.Y[(row + y) * planes.Width + col]);
                packed.WriteByte(planes.Y[(row + y) * planes.Width + col + 1]);
            }
            var chromaIndex = row / vertical * planes.ChromaWidth + col / 2;
            packed.WriteByte(planes.Cb[chromaIndex]); packed.WriteByte(planes.Cr[chromaIndex]);
        }
        byte[] compressed;
        using (var output = new MemoryStream())
        {
            using (var zlib = new ZLibStream(output, CompressionLevel.SmallestSize, true)) zlib.Write(packed.ToArray());
            compressed = output.ToArray();
        }
        var xmp = Encoding.UTF8.GetBytes(CaptureMetadata.NewDocument(frame, captureId).ToString());
        var entries = new List<Entry>
        {
            Long(256, (uint)planes.Width), Long(257, (uint)planes.Height), Shorts(258, 8, 8, 8),
            Short(259, 8), Short(262, 6), Long(273, 0), Short(277, 3), Long(278, (uint)planes.Height),
            Long(279, (uint)compressed.Length), Short(284, 1), Ascii(305, "PixelBooth for Windows"),
            Rationals(529, coefficients.Take(3).Select(v => (v, coefficients[3])).ToArray()),
            Shorts(530, 2, (ushort)vertical), Short(531, (ushort)position),
            Rationals(532, range.Select(v => (v, 1u)).ToArray()), new Entry(700, 1, (uint)xmp.Length, xmp)
        };
        if (mode.Primaries == 2)
        {
            entries.Add(Rationals(318, [(3127, 10000), (3290, 10000)]));
            entries.Add(Rationals(319, [(6400, 10000), (3300, 10000), (3000, 10000), (6000, 10000), (1500, 10000), (600, 10000)]));
        }
        // TIFF otherwise assumes gamma 2.2; Media Foundation specifies BT.709
        // as its interpretation for an unknown transfer function instead.
        var effectiveTransfer = mode.Transfer is null or 0 ? 5 : mode.Transfer.Value;
        {
            var values = new ushort[3 * 256];
            for (var i = 0; i < 256; i++)
            {
                var encoded = i / 255.0;
                var linear = effectiveTransfer switch
                {
                    1 => encoded, 4 => Math.Pow(encoded, 2.2), 8 => Math.Pow(encoded, 2.8),
                    5 => encoded < 0.081 ? encoded / 4.5 : Math.Pow((encoded + 0.099) / 1.099, 1 / 0.45),
                    6 => encoded < 0.0912 ? encoded / 4 : Math.Pow((encoded + 0.1115) / 1.1115, 1 / 0.45),
                    7 => encoded <= 0.04045 ? encoded / 12.92 : Math.Pow((encoded + 0.055) / 1.055, 2.4),
                    _ => throw new InvalidDataException("Unsupported transfer function.")
                };
                var value = (ushort)Math.Clamp((int)Math.Round(linear * 65535), 0, 65535);
                values[i] = values[i + 256] = values[i + 512] = value;
            }
            entries.Add(Shorts(301, values));
        }
        entries.Sort((a, b) => a.Tag.CompareTo(b.Tag));
        var ifdSize = checked(2 + entries.Count * 12 + 4);
        var extrasOffset = checked(8 + ifdSize);
        var extraBytes = entries.Where(e => e.Value.Length > 4).Sum(e => (e.Value.Length + 1) & ~1);
        var stripOffset = checked(extrasOffset + extraBytes);
        entries[entries.FindIndex(e => e.Tag == 273)] = Long(273, (uint)stripOffset);
        using var file = new MemoryStream(checked(stripOffset + compressed.Length));
        file.Write([0x49, 0x49, 42, 0]); WriteU32(file, 8); WriteU16(file, (ushort)entries.Count);
        var cursor = extrasOffset;
        foreach (var entry in entries)
        {
            WriteU16(file, entry.Tag); WriteU16(file, entry.Type); WriteU32(file, entry.Count);
            if (entry.Value.Length <= 4) { file.Write(entry.Value); for (var i = entry.Value.Length; i < 4; i++) file.WriteByte(0); }
            else { WriteU32(file, (uint)cursor); cursor = checked(cursor + ((entry.Value.Length + 1) & ~1)); }
        }
        WriteU32(file, 0);
        foreach (var entry in entries.Where(e => e.Value.Length > 4))
        {
            file.Write(entry.Value); if ((entry.Value.Length & 1) != 0) file.WriteByte(0);
        }
        file.Write(compressed);
        var result = file.ToArray();
        Validate(result, planes, position, entries);
        return result;
    }

    private static void Validate(byte[] data, RawPlanes source, int position, IReadOnlyList<Entry> expected)
    {
        if (data.Length < 8 || data[0] != 0x49 || data[1] != 0x49 || ReadU16(data, 2) != 42) throw new InvalidDataException("Invalid TIFF header.");
        var ifd = checked((int)ReadU32(data, 4));
        var count = ReadU16(data, ifd); var entries = new Dictionary<ushort, (ushort Type, uint Count, uint Value)>();
        for (var i = 0; i < count; i++)
        {
            var offset = checked(ifd + 2 + 12 * i);
            entries.Add(ReadU16(data, offset), (ReadU16(data, offset + 2), ReadU32(data, offset + 4), ReadU32(data, offset + 8)));
        }
        if (entries.Count != expected.Count) throw new InvalidDataException("TIFF metadata count did not round-trip.");
        for (var i = 0; i < expected.Count; i++)
        {
            var entry = expected[i];
            if (!entries.TryGetValue(entry.Tag, out var actual) || actual.Type != entry.Type || actual.Count != entry.Count)
                throw new InvalidDataException("TIFF metadata type did not round-trip.");
            var valueOffset = entry.Value.Length <= 4 ? checked(ifd + 2 + 12 * i + 8) : checked((int)actual.Value);
            if (!data.AsSpan(valueOffset, entry.Value.Length).SequenceEqual(entry.Value))
                throw new InvalidDataException("TIFF metadata value did not round-trip.");
        }
        if (entries[256].Value != source.Width || entries[257].Value != source.Height || entries[259].Value != 8 ||
            entries[262].Value != 6 || entries[531].Value != position || entries[530].Value != (uint)(2 | ((source.Chroma == 1 ? 2 : 1) << 16)))
            throw new InvalidDataException("TIFF geometry or color layout did not round-trip.");
        var stripStart = checked((int)entries[273].Value); var stripLength = checked((int)entries[279].Value);
        using var strip = new MemoryStream(data, stripStart, stripLength, false);
        using var zlib = new ZLibStream(strip, CompressionMode.Decompress);
        using var decoded = new MemoryStream(); zlib.CopyTo(decoded);
        var bytes = decoded.ToArray(); var cursor = 0; var vertical = source.Chroma == 1 ? 2 : 1;
        for (var row = 0; row < source.Height; row += vertical)
        for (var col = 0; col < source.Width; col += 2)
        {
            for (var y = 0; y < vertical; y++)
            {
                if (cursor + 2 > bytes.Length || bytes[cursor++] != source.Y[(row + y) * source.Width + col] || bytes[cursor++] != source.Y[(row + y) * source.Width + col + 1])
                    throw new InvalidDataException("TIFF luma sample verification failed.");
            }
            var chroma = row / vertical * source.ChromaWidth + col / 2;
            if (cursor + 2 > bytes.Length || bytes[cursor++] != source.Cb[chroma] || bytes[cursor++] != source.Cr[chroma])
                throw new InvalidDataException("TIFF chroma sample verification failed.");
        }
        if (cursor != bytes.Length) throw new InvalidDataException("TIFF sample verification found extra data.");
    }

    private static Entry Short(ushort tag, ushort value) => Shorts(tag, value);
    private static Entry Shorts(ushort tag, params ushort[] values)
    {
        var data = new byte[values.Length * 2]; for (var i = 0; i < values.Length; i++) BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(i * 2), values[i]);
        return new Entry(tag, 3, (uint)values.Length, data);
    }
    private static Entry Long(ushort tag, uint value) { var data = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(data, value); return new Entry(tag, 4, 1, data); }
    private static Entry Ascii(ushort tag, string value) { var data = Encoding.ASCII.GetBytes(value + "\0"); return new Entry(tag, 2, (uint)data.Length, data); }
    private static Entry Rationals(ushort tag, (uint Num, uint Den)[] values)
    {
        var data = new byte[values.Length * 8];
        for (var i = 0; i < values.Length; i++) { BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(i * 8), values[i].Num); BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(i * 8 + 4), values[i].Den); }
        return new Entry(tag, 5, (uint)values.Length, data);
    }
    private static ushort ReadU16(byte[] data, int offset) => BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(offset, 2));
    private static uint ReadU32(byte[] data, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(offset, 4));
    private static void WriteU16(Stream stream, ushort value) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16LittleEndian(b, value); stream.Write(b); }
    private static void WriteU32(Stream stream, uint value) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(b, value); stream.Write(b); }
}
