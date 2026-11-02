using System.Buffers.Binary;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using PixelBooth.Core.Capture;

namespace PixelBooth.Core.Imaging;

public sealed class JpegXmpEmbeddingException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>Copies JPEG markers and entropy data without ever decoding or recompressing them.</summary>
public static class JpegPreserver
{
    private static readonly byte[] XmpHeader = Encoding.ASCII.GetBytes("http://ns.adobe.com/xap/1.0/\0");
    private static readonly byte[] ExtendedXmpHeader = Encoding.ASCII.GetBytes("http://ns.adobe.com/xmp/extension/\0");
    private sealed record Segment(int Start, int End, byte Marker, int DataStart, int DataLength);

    public static bool CanAddStandardMetadata(byte[] bytes)
    {
        var (segments, _, _, _) = Parse(bytes);
        return !segments.Any(s => s.Marker == 0xe1 &&
            (s.DataLength >= 6 && bytes.AsSpan(s.DataStart, 6).SequenceEqual("Exif\0\0"u8) ||
             s.DataLength >= XmpHeader.Length && bytes.AsSpan(s.DataStart, XmpHeader.Length).SequenceEqual(XmpHeader) ||
             s.DataLength >= ExtendedXmpHeader.Length && bytes.AsSpan(s.DataStart, ExtendedXmpHeader.Length).SequenceEqual(ExtendedXmpHeader)));
    }

    public static byte[] AddMetadata(CameraFrame frame, Guid captureId)
    {
        var bytes = frame.Bytes;
        var (segments, end, width, height) = Parse(bytes);
        if (width != frame.Mode.Width || height != frame.Mode.Height)
            throw new InvalidDataException("The JPEG dimensions do not match the selected camera mode.");
        var xmpSegments = segments.Where(s => s.Marker == 0xe1 && s.DataLength >= XmpHeader.Length &&
            bytes.AsSpan(s.DataStart, XmpHeader.Length).SequenceEqual(XmpHeader)).ToArray();
        if (xmpSegments.Length > 1) throw new JpegXmpEmbeddingException("Multiple standard XMP packets cannot be merged safely.");

        XDocument document;
        if (xmpSegments.Length == 1)
        {
            var segment = xmpSegments[0];
            try
            {
                using var stream = new MemoryStream(bytes, segment.DataStart + XmpHeader.Length, segment.DataLength - XmpHeader.Length, false);
                using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1_000_000 });
                document = XDocument.Load(reader, LoadOptions.PreserveWhitespace);
            }
            catch (XmlException e) { throw new JpegXmpEmbeddingException("Existing XMP cannot be parsed safely.", e); }
            var roots = document.Descendants(CaptureMetadata.Rdf + "RDF").Take(2).ToArray();
            if (roots.Length != 1) throw new JpegXmpEmbeddingException("Existing XMP has no single RDF root.");
            var rdf = roots[0];
            var description = CaptureMetadata.Description(frame, captureId);
            var sourceSubject = (string?)rdf.Elements(CaptureMetadata.Rdf + "Description").FirstOrDefault()?.Attribute(CaptureMetadata.Rdf + "about");
            if (sourceSubject is not null) description.SetAttributeValue(CaptureMetadata.Rdf + "about", sourceSubject);
            rdf.Add(description);
        }
        else
        {
            document = CaptureMetadata.NewDocument(frame, captureId, includeStandard: CanAddStandardMetadata(bytes));
        }

        var packet = Encoding.UTF8.GetBytes(document.ToString(SaveOptions.DisableFormatting));
        var length = checked(XmpHeader.Length + packet.Length + 2);
        if (length > ushort.MaxValue) throw new JpegXmpEmbeddingException("The merged XMP is too large for a JPEG marker.");
        using var output = new MemoryStream(end + length + 2);
        var insertion = xmpSegments.Length == 1 ? xmpSegments[0].Start : 2;
        output.Write(bytes, 0, insertion);
        output.WriteByte(0xff); output.WriteByte(0xe1);
        Span<byte> size = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(size, (ushort)length);
        output.Write(size); output.Write(XmpHeader); output.Write(packet);
        var tail = xmpSegments.Length == 1 ? xmpSegments[0].End : insertion;
        output.Write(bytes, tail, end - tail);
        return output.ToArray();
    }

    /// <summary>Validates segment bounds and returns the complete JPEG, omitting trailing buffer padding.</summary>
    public static byte[] Extract(byte[] bytes)
    {
        var (_, end, _, _) = Parse(bytes);
        return bytes.AsSpan(0, end).ToArray();
    }

    private static (List<Segment>, int, int, int) Parse(byte[] bytes)
    {
        if (bytes.Length < 4 || bytes[0] != 0xff || bytes[1] != 0xd8)
            throw new InvalidDataException("Camera sample is not a complete JPEG.");
        var segments = new List<Segment>();
        var pos = 2;
        var scan = false;
        var entropy = false;
        var sawScan = false;
        var sawFrame = false;
        var frameMarker = 0;
        var width = 0;
        var height = 0;
        var components = new Dictionary<byte, int>();
        var quantization = new HashSet<int>();
        var dcTables = new HashSet<int>();
        var acTables = new HashSet<int>();
        while (pos < bytes.Length)
        {
            if (scan)
            {
                while (pos < bytes.Length && bytes[pos] != 0xff) { entropy = true; pos++; }
                if (pos >= bytes.Length) break;
                var markerStart = pos++;
                while (pos < bytes.Length && bytes[pos] == 0xff) pos++;
                if (pos >= bytes.Length) break;
                var code = bytes[pos];
                if (code == 0) { entropy = true; pos++; continue; }
                if (code is >= 0xd0 and <= 0xd7) { if (!entropy) throw new InvalidDataException("Empty JPEG restart interval."); pos++; continue; }
                if (!entropy) throw new InvalidDataException("JPEG scan has no entropy data.");
                pos = markerStart;
                scan = false;
            }
            if (bytes[pos] != 0xff) throw new InvalidDataException("Invalid JPEG marker boundary.");
            var start = pos++;
            while (pos < bytes.Length && bytes[pos] == 0xff) pos++;
            if (pos >= bytes.Length) break;
            var marker = bytes[pos++];
            if (marker == 0xd9)
            {
                if (!sawFrame || !sawScan) throw new InvalidDataException("JPEG lacks an image frame or scan.");
                return (segments, pos, width, height);
            }
            if (marker == 0 || marker == 0xd8 || marker is >= 0xd0 and <= 0xd7)
                throw new InvalidDataException("Unexpected JPEG marker.");
            if (marker == 0x01) { segments.Add(new Segment(start, pos, marker, pos, 0)); continue; }
            if (pos + 2 > bytes.Length) break;
            var length = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(pos, 2));
            if (length < 2 || (long)pos + length > bytes.Length) throw new InvalidDataException("Invalid JPEG segment length.");
            var dataStart = pos + 2;
            pos += length;
            segments.Add(new Segment(start, pos, marker, dataStart, length - 2));
            if (marker is >= 0xc0 and <= 0xcf && marker is not (0xc4 or 0xc8 or 0xcc))
            {
                if (sawFrame || marker is not (0xc0 or 0xc1 or 0xc2) || length < 11)
                    throw new InvalidDataException("Unsupported or invalid JPEG frame header.");
                var precision = bytes[dataStart];
                height = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(dataStart + 1, 2));
                width = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(dataStart + 3, 2));
                var count = bytes[dataStart + 5];
                if (width == 0 || height == 0 || count is 0 or > 4 || length != 8 + count * 3 ||
                    (marker == 0xc0 ? precision != 8 : precision is not (8 or 12)))
                    throw new InvalidDataException("Invalid JPEG frame geometry or components.");
                for (var i = 0; i < count; i++)
                {
                    var offset = dataStart + 6 + i * 3;
                    var sampling = bytes[offset + 1];
                    if ((sampling >> 4) is 0 or > 4 || (sampling & 15) is 0 or > 4 || bytes[offset + 2] > 3 ||
                        !components.TryAdd(bytes[offset], bytes[offset + 2]))
                        throw new InvalidDataException("Invalid JPEG component.");
                }
                frameMarker = marker;
                sawFrame = true;
            }
            else if (marker == 0xdb)
            {
                var cursor = dataStart;
                while (cursor < pos)
                {
                    var info = bytes[cursor++]; var precision = info >> 4; var id = info & 15;
                    if (precision > 1 || id > 3 || cursor + 64 * (precision + 1) > pos)
                        throw new InvalidDataException("Invalid JPEG quantization table.");
                    for (var i = 0; i < 64; i++)
                    {
                        var value = precision == 0 ? bytes[cursor + i] : BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(cursor + i * 2, 2));
                        if (value == 0) throw new InvalidDataException("Invalid JPEG quantization value.");
                    }
                    cursor += 64 * (precision + 1); quantization.Add(id);
                }
            }
            else if (marker == 0xc4)
            {
                var cursor = dataStart;
                while (cursor < pos)
                {
                    if (pos - cursor < 17) throw new InvalidDataException("Invalid JPEG Huffman table.");
                    var info = bytes[cursor++]; var kind = info >> 4; var id = info & 15;
                    if (kind > 1 || id > 3) throw new InvalidDataException("Invalid JPEG Huffman table identifier.");
                    var symbols = 0; var available = 1;
                    for (var i = 0; i < 16; i++) { var count = bytes[cursor++]; symbols += count; available = available * 2 - count; if (available < 0) throw new InvalidDataException("Oversubscribed JPEG Huffman table."); }
                    if (symbols is 0 or > 256 || cursor + symbols > pos) throw new InvalidDataException("Invalid JPEG Huffman symbols.");
                    cursor += symbols; (kind == 0 ? dcTables : acTables).Add(id);
                }
            }
            else if (marker == 0xcc) throw new InvalidDataException("Arithmetic JPEG coding is not supported.");
            else if (marker == 0xda)
            {
                if (!sawFrame || length < 8) throw new InvalidDataException("JPEG scan has no valid frame.");
                var count = bytes[dataStart];
                if (count is 0 or > 4 || length != 6 + count * 2) throw new InvalidDataException("Invalid JPEG scan header.");
                var spectralStart = bytes[dataStart + 1 + count * 2];
                var spectralEnd = bytes[dataStart + 2 + count * 2];
                var successive = bytes[dataStart + 3 + count * 2];
                if (frameMarker != 0xc2 && (spectralStart != 0 || spectralEnd != 63 || successive != 0) ||
                    frameMarker == 0xc2 && (spectralStart > spectralEnd || spectralEnd > 63 || (spectralStart == 0 ? spectralEnd != 0 : count != 1)))
                    throw new InvalidDataException("Invalid JPEG scan parameters.");
                var seen = new HashSet<byte>();
                for (var i = 0; i < count; i++)
                {
                    var id = bytes[dataStart + 1 + i * 2]; var table = bytes[dataStart + 2 + i * 2];
                    if (!components.TryGetValue(id, out var q) || !seen.Add(id) || !quantization.Contains(q) ||
                        (frameMarker != 0xc2 || spectralStart == 0 && (successive >> 4) == 0) && !dcTables.Contains(table >> 4) ||
                        (frameMarker != 0xc2 || spectralStart != 0) && !acTables.Contains(table & 15))
                        throw new InvalidDataException("JPEG scan references a missing component or coding table.");
                }
                sawScan = true; scan = true; entropy = false;
            }
        }
        throw new InvalidDataException("JPEG ends before its end-of-image marker.");
    }
}
