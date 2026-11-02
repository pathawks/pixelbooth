using System.Buffers.Binary;
using System.Text;

namespace PixelBooth.Core.Imaging;

/// <summary>Checks the positioning in the encoder's single-image AVIF output.</summary>
internal static class AvifChromaValidator
{
    internal static void VerifyColocated420(byte[] data)
    {
        var top = Boxes(data, 0, data.Length);
        var meta = One(top, "meta");
        var media = One(top, "mdat");
        if (meta.End - meta.Start < 4) throw new InvalidDataException("Truncated AVIF metadata.");
        var metadata = Boxes(data, meta.Start + 4, meta.End);
        var pitm = One(metadata, "pitm");
        if (pitm.End - pitm.Start != 6 || data[pitm.Start] != 0)
            throw new InvalidDataException("Unsupported AVIF primary item format.");
        var primary = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(pitm.Start + 4, 2));
        var location = One(metadata, "iloc");
        var (offset, length) = PrimaryExtent(data.AsSpan(location.Start, location.End - location.Start), primary);
        if (offset != media.Start || length > media.End - media.Start || length == 0)
            throw new InvalidDataException("AVIF primary image extent is not the expected media data.");

        var iprp = One(metadata, "iprp");
        var properties = Boxes(data, iprp.Start, iprp.End);
        var ipco = One(properties, "ipco");
        var propertyList = Boxes(data, ipco.Start, ipco.End);
        var av1c = One(propertyList, "av1C");
        var ipma = One(properties, "ipma");
        VerifyPrimaryAssociation(data.AsSpan(ipma.Start, ipma.End - ipma.Start), primary, propertyList.IndexOf(av1c) + 1);
        if (av1c.End - av1c.Start != 4 || data[av1c.Start] != 0x81 ||
            (data[av1c.Start + 2] & 0x1f) != 0x0e)
            throw new InvalidDataException("AVIF configuration does not signal co-sited 4:2:0 chroma.");
        VerifySequenceHeader(data.AsSpan(offset, length));
    }

    private static void VerifyPrimaryAssociation(ReadOnlySpan<byte> data, int primary, int propertyIndex)
    {
        var reader = new ByteReader(data);
        if (reader.Read(4) != 0 || propertyIndex is < 1 or > 127)
            throw new InvalidDataException("Unsupported AVIF property association format.");
        var count = reader.Read(4);
        var found = false;
        for (uint i = 0; i < count; i++)
        {
            var id = reader.Read(2);
            var associations = reader.Read(1);
            for (var j = 0; j < associations; j++)
            {
                var index = reader.Read(1) & 0x7f;
                if (id == primary && index == propertyIndex)
                {
                    if (found) throw new InvalidDataException("Duplicate AVIF codec property association.");
                    found = true;
                }
            }
        }
        if (!reader.AtEnd || !found) throw new InvalidDataException("AVIF codec property is not associated with the primary image.");
    }

    // The current encoder emits iloc version 0, with one file-based extent per item.
    // Reject other arrangements until their primary-image association is verified.
    private static (int Offset, int Length) PrimaryExtent(ReadOnlySpan<byte> data, int primary)
    {
        var reader = new ByteReader(data);
        if (reader.Read(4) != 0) throw new InvalidDataException("Unsupported iloc version.");
        var sizes = reader.Read(1);
        var baseSizes = reader.Read(1);
        var offsetSize = (int)(sizes >> 4); var lengthSize = (int)(sizes & 15);
        var baseSize = (int)(baseSizes >> 4);
        if ((baseSizes & 15) != 0 || offsetSize is not (0 or 4) || lengthSize != 4 || baseSize is not (0 or 4))
            throw new InvalidDataException("Unsupported iloc field sizes.");
        var count = reader.Read(2);
        (int Offset, int Length)? found = null;
        for (var i = 0; i < count; i++)
        {
            var id = reader.Read(2);
            if (reader.Read(2) != 0) throw new InvalidDataException("External AVIF data is unsupported.");
            var baseOffset = reader.Read(baseSize);
            var extents = reader.Read(2);
            if (extents != 1) throw new InvalidDataException("Unsupported AVIF extent count.");
            var offset = reader.Read(offsetSize);
            var length = reader.Read(lengthSize);
            if (id == primary)
            {
                if (found is not null || (ulong)baseOffset + offset > int.MaxValue || length > int.MaxValue)
                    throw new InvalidDataException("Invalid AVIF primary extent.");
                found = ((int)(baseOffset + offset), (int)length);
            }
        }
        if (!reader.AtEnd || found is null) throw new InvalidDataException("AVIF primary extent missing or malformed.");
        return found.Value;
    }

    private static void VerifySequenceHeader(ReadOnlySpan<byte> data)
    {
        var reader = new ByteReader(data);
        // libaom emits a temporal delimiter followed by a sequence header.
        if (reader.Read(1) != 0x12 || reader.Read(1) != 0 || reader.Read(1) != 0x0a)
            throw new InvalidDataException("Unexpected AV1 image item structure.");
        var size = reader.ReadLeb128();
        var bits = new BitReader(reader.Take(size));
        if (bits.Read(3) != 0 || bits.Read(1) != 1 || bits.Read(1) != 1)
            throw new InvalidDataException("Unsupported AV1 sequence header.");
        bits.Read(5); // level
        var widthBits = (int)bits.Read(4) + 1;
        var heightBits = (int)bits.Read(4) + 1;
        bits.Read(widthBits); bits.Read(heightBits);
        bits.Read(3); // intra coding tools
        bits.Read(3); // superres, CDEF, restoration
        if (bits.Read(1) != 0 || bits.Read(1) != 0)
            throw new InvalidDataException("AV1 sequence is not 8-bit color.");
        var primaries = 2u; var transfer = 2u; var matrix = 2u;
        if (bits.Read(1) != 0)
        {
            primaries = bits.Read(8); transfer = bits.Read(8); matrix = bits.Read(8);
        }
        if (primaries == 1 && transfer == 13 && matrix == 0)
            throw new InvalidDataException("AV1 sequence is RGB, not 4:2:0.");
        bits.Read(1); // range
        if (bits.Read(2) != 2) throw new InvalidDataException("AV1 sequence does not signal co-sited chroma.");
    }

    private ref struct ByteReader
    {
        private readonly ReadOnlySpan<byte> data;
        private int position;
        internal ByteReader(ReadOnlySpan<byte> data) { this.data = data; position = 0; }
        internal bool AtEnd => position == data.Length;
        internal uint Read(int count)
        {
            if (count < 0 || count > 4 || count > data.Length - position) throw new InvalidDataException("Truncated AVIF data.");
            uint value = 0;
            for (var i = 0; i < count; i++) value = (value << 8) | data[position++];
            return value;
        }
        internal int ReadLeb128()
        {
            uint value = 0;
            for (var i = 0; i < 4; i++)
            {
                var b = Read(1); value |= (b & 127) << (7 * i);
                if ((b & 128) == 0) return checked((int)value);
            }
            throw new InvalidDataException("Unsupported AV1 OBU length.");
        }
        internal ReadOnlySpan<byte> Take(int count)
        {
            if (count < 0 || count > data.Length - position) throw new InvalidDataException("Truncated AV1 OBU.");
            var result = data.Slice(position, count); position += count; return result;
        }
    }

    private ref struct BitReader
    {
        private readonly ReadOnlySpan<byte> data;
        private int position;
        internal BitReader(ReadOnlySpan<byte> data) { this.data = data; position = 0; }
        internal uint Read(int count)
        {
            if (count < 0 || count > 24 || count > data.Length * 8L - position) throw new InvalidDataException("Truncated AV1 sequence header.");
            uint value = 0;
            for (var i = 0; i < count; i++, position++) value = (value << 1) | (uint)((data[position / 8] >> (7 - position % 8)) & 1);
            return value;
        }
    }

    private sealed record Box(string Type, int Start, int End);
    private static Box One(IEnumerable<Box> boxes, string type)
    {
        var matches = boxes.Where(b => b.Type == type).ToArray();
        return matches.Length == 1 ? matches[0] : throw new InvalidDataException($"Expected one {type} box.");
    }
    private static List<Box> Boxes(byte[] data, int start, int end)
    {
        var boxes = new List<Box>();
        while (start < end)
        {
            if (end - start < 8) throw new InvalidDataException("Truncated AVIF box.");
            var length = BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(start, 4));
            if (length < 8 || length > end - start) throw new InvalidDataException("Invalid AVIF box length.");
            boxes.Add(new Box(Encoding.ASCII.GetString(data, start + 4, 4), start + 8, checked(start + (int)length)));
            start += (int)length;
        }
        return boxes;
    }
}
