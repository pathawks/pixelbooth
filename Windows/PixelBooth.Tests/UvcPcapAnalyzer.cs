using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

/// <summary>
/// Diagnostic for USBPcap isochronous UVC IN transfers. This is intentionally
/// separate from the application and does not infer sensor-level provenance.
/// </summary>
internal static class UvcPcapAnalyzer
{
    private const int MaximumRecordBytes = 32 * 1024 * 1024;
    private const int MaximumFrameBytes = 32 * 1024 * 1024;
    private const uint PcapMagic = 0xa1b2c3d4;
    private const uint UsbPcapLinkType = 249;

    internal sealed record Reference(int Index, int Length, string Hash);
    internal sealed record FrameMatch(int UsbFrame, int ReferenceIndex, string Boundary);
    internal sealed record Format(byte Interface, byte FormatIndex, byte FrameIndex, string FourCC, ushort Width, ushort Height, byte BitDepth);
    internal sealed record Commit(byte Interface, byte FormatIndex, byte FrameIndex, uint FrameInterval, uint MaximumFrameBytes);
    internal sealed record ColorDescriptor(byte Interface, byte FormatIndex, byte Primaries, byte Transfer, byte Matrix);
    internal sealed class Result
    {
        public int Records, TruncatedRecords, IsoTransfers, IsoPackets, EmptyPackets, TransferErrors,
            PacketErrors, UvcErrors, InvalidPackets, CompleteFrames, CorruptFrames, UnconfirmedFrames;
        public bool IncompleteTail;
        public List<FrameMatch> Matches { get; } = [];
        public List<Format> Formats { get; } = [];
        public List<Commit> Commits { get; } = [];
        public List<ColorDescriptor> Colors { get; } = [];
    }

    public static void Run(string[] args)
    {
        var directory = Path.GetFullPath(args[1]);
        var device = ReadArgument(args, "--device", byte.MaxValue);
        var endpoint = ReadArgument(args, "--endpoint", byte.MaxValue);
        if ((endpoint & 0x80) == 0) throw new ArgumentException("The selected endpoint must be an IN endpoint.");
        var references = File.ReadLines(Path.Combine(directory, "media-foundation-hashes.txt"))
            .Select(line => Regex.Match(line, @"^frame=(\d+)\s+timestamp100ns=-?\d+\s+bytes=(\d+)\s+sha256=([0-9A-Fa-f]{64})$"))
            .Where(match => match.Success)
            .Select(match => new Reference(int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture),
                int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture), match.Groups[3].Value.ToUpperInvariant()))
            .ToArray();
        if (references.Length == 0 || references.Select(r => r.Length).Distinct().Count() != 1 ||
            references.Select(r => r.Index).Distinct().Count() != references.Length)
            throw new InvalidDataException("Reference hashes are missing, duplicated, or have inconsistent frame sizes.");
        using var stream = File.OpenRead(Path.Combine(directory, "brio-usb.pcap"));
        var result = Analyze(stream, (byte)device, (byte)endpoint, references);
        var matched = result.Matches.Select(m => m.ReferenceIndex).Distinct().Count();
        foreach (var commit in result.Commits.Distinct())
        {
            var format = result.Formats.FirstOrDefault(f => f.Interface == commit.Interface && f.FormatIndex == commit.FormatIndex && f.FrameIndex == commit.FrameIndex);
            var description = format is null ? "descriptor unavailable" : $"{format.FourCC} {format.Width}×{format.Height}, {format.BitDepth} bits per pixel";
            Console.WriteLine($"UVC commit: interface {commit.Interface}, format {commit.FormatIndex}, frame {commit.FrameIndex}: {description}; interval {commit.FrameInterval} × 100 ns; maximum frame bytes {commit.MaximumFrameBytes}.");
            var color = result.Colors.FirstOrDefault(c => c.Interface == commit.Interface && c.FormatIndex == commit.FormatIndex);
            if (color is not null)
                Console.WriteLine($"UVC color-matching descriptor: primaries={color.Primaries}, transfer={color.Transfer}, matrix={color.Matrix}; it has no chroma-siting field.");
        }
        Console.WriteLine($"PCAP records: {result.Records}; truncated records: {result.TruncatedRecords}; incomplete final record: {result.IncompleteTail}.");
        Console.WriteLine($"Selected isochronous IN transfers: {result.IsoTransfers}; packets: {result.IsoPackets}; empty packets: {result.EmptyPackets}.");
        Console.WriteLine($"Transfer errors: {result.TransferErrors}; packet errors: {result.PacketErrors}; UVC error flags: {result.UvcErrors}; invalid packets: {result.InvalidPackets}.");
        Console.WriteLine($"Complete valid UVC frames: {result.CompleteFrames}; corrupt or wrong-size frames: {result.CorruptFrames}; frames without a confirmed boundary: {result.UnconfirmedFrames}.");
        Console.WriteLine($"Reference SHA-256 hashes matched: {matched}/{references.Length}; reference bytes per frame: {references[0].Length}.");
        var pairs = result.Matches.OrderBy(m => m.UsbFrame).ThenBy(m => m.ReferenceIndex).ToArray();
        if (pairs.Length != 0)
        {
            Console.WriteLine($"First match: USB frame {pairs[0].UsbFrame}, reference frame {pairs[0].ReferenceIndex}; last match: USB frame {pairs[^1].UsbFrame}, reference frame {pairs[^1].ReferenceIndex}.");
            var inSequence = pairs.Length == references.Length &&
                pairs.Select(p => p.ReferenceIndex).SequenceEqual(references.Select(r => r.Index).Order()) &&
                pairs.Select(p => p.UsbFrame).SequenceEqual(Enumerable.Range(pairs[0].UsbFrame, pairs.Length));
            Console.WriteLine($"All reference frames matched consecutive USB frames in order: {inSequence}.");
        }
        Console.WriteLine("A hash match compares UVC payload bytes after header removal with a Media Foundation frame. It does not establish the camera's sensor processing or chroma sample position.");
    }

    private static int ReadArgument(string[] args, string name, int max)
    {
        var index = Array.IndexOf(args, name);
        if (index < 0 || index + 1 >= args.Length) throw new ArgumentException($"Specify {name} for the USB stream being analyzed.");
        var value = args[index + 1];
        var number = value.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
            ? int.Parse(value.AsSpan(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture)
            : int.Parse(value, CultureInfo.InvariantCulture);
        if (number < 0 || number > max) throw new ArgumentOutOfRangeException(name);
        return number;
    }

    internal static Result Analyze(Stream stream, byte device, byte endpoint, IReadOnlyList<Reference> references)
    {
        if (references.Count == 0 || references[0].Length is <= 0 or > MaximumFrameBytes || references.Any(r => r.Length != references[0].Length))
            throw new ArgumentException("References must have a bounded, consistent frame size.");
        var hashLookup = references.GroupBy(r => r.Hash, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Select(r => r.Index).ToArray(), StringComparer.OrdinalIgnoreCase);
        var result = new Result();
        var global = new byte[24];
        if (ReadAtMost(stream, global) != global.Length || U32(global, 0) != PcapMagic || U32(global, 20) != UsbPcapLinkType)
            throw new InvalidDataException("Expected a little-endian USBPcap file.");
        var frame = new byte[references[0].Length];
        var frameLength = 0;
        int? fid = null;
        var bad = false;
        var sawBoundary = false;
        var usbFrame = 0;

        void Finish(string boundary)
        {
            if (frameLength == 0) { bad = false; return; }
            usbFrame++;
            if (!sawBoundary) result.UnconfirmedFrames++;
            else if (bad || frameLength != frame.Length) result.CorruptFrames++;
            else
            {
                result.CompleteFrames++;
                var hash = Convert.ToHexString(SHA256.HashData(frame));
                if (hashLookup.TryGetValue(hash, out var indexes))
                    foreach (var index in indexes) result.Matches.Add(new FrameMatch(usbFrame, index, boundary));
            }
            frameLength = 0;
            bad = false;
        }

        var recordHeader = new byte[16];
        for (;;)
        {
            var headerRead = ReadAtMost(stream, recordHeader);
            if (headerRead == 0) break;
            if (headerRead != recordHeader.Length) { result.IncompleteTail = true; break; }
            var included = U32(recordHeader, 8);
            var original = U32(recordHeader, 12);
            if (included > MaximumRecordBytes || included > original) throw new InvalidDataException("Invalid or oversized PCAP record.");
            var packet = new byte[(int)included];
            if (ReadAtMost(stream, packet) != packet.Length) { result.IncompleteTail = true; break; }
            result.Records++;
            if (included < original) { result.TruncatedRecords++; bad = true; continue; }
            if (packet.Length < 27) throw new InvalidDataException("A USBPcap record is shorter than its header.");
            var headerLength = U16(packet, 0);
            var dataLength = U32(packet, 23);
            var recordDevice = U16(packet, 19);
            if (recordDevice == device && packet[22] == 2)
            {
                if (headerLength < 28 || headerLength > packet.Length || dataLength > packet.Length - headerLength)
                    throw new InvalidDataException("Invalid USBPcap control transfer.");
                var control = packet.AsSpan(headerLength, (int)dataLength);
                if ((packet[16] & 1) != 0 && control.Length >= 9 && control[0] == 9 && control[1] == 2)
                    ParseFormats(control, result.Formats, result.Colors);
                if ((packet[16] & 1) == 0 && control.Length >= 34 && control[0] == 0x21 && control[1] == 1 &&
                    BinaryPrimitives.ReadUInt16LittleEndian(control[2..]) == 0x0200 &&
                    BinaryPrimitives.ReadUInt16LittleEndian(control[6..]) >= 26)
                {
                    var index = BinaryPrimitives.ReadUInt16LittleEndian(control[4..]);
                    if (index <= byte.MaxValue)
                        result.Commits.Add(new Commit((byte)index, control[10], control[11],
                            BinaryPrimitives.ReadUInt32LittleEndian(control[12..]), BinaryPrimitives.ReadUInt32LittleEndian(control[26..])));
                }
            }
            if (recordDevice != device || packet[21] != endpoint || packet[22] != 0 || (packet[16] & 1) == 0) continue;
            result.IsoTransfers++;
            if (headerLength < 39 || headerLength > packet.Length || dataLength > packet.Length - headerLength)
                throw new InvalidDataException("Invalid isochronous USBPcap header or data size.");
            var packetCount = U32(packet, 31);
            if (packetCount > (headerLength - 39) / 12) throw new InvalidDataException("Invalid isochronous descriptor count.");
            if (U32(packet, 10) != 0 || U32(packet, 35) != 0) { result.TransferErrors++; bad = true; }
            for (var i = 0; i < packetCount; i++)
            {
                var descriptor = checked(39 + (int)i * 12);
                var offset = U32(packet, descriptor);
                var length = U32(packet, descriptor + 4);
                var status = U32(packet, descriptor + 8);
                result.IsoPackets++;
                if (status != 0) { result.PacketErrors++; bad = true; continue; }
                if (length == 0) { result.EmptyPackets++; continue; }
                if ((ulong)offset + length > dataLength) throw new InvalidDataException("Isochronous packet exceeds its transfer buffer.");
                var payload = packet.AsSpan(checked(headerLength + (int)offset), checked((int)length));
                if (payload.Length < 2 || payload[0] < 2 || payload[0] > payload.Length)
                {
                    result.InvalidPackets++; bad = true; continue;
                }
                var flags = payload[1];
                var minimumHeader = 2 + ((flags & 4) != 0 ? 4 : 0) + ((flags & 8) != 0 ? 6 : 0);
                if (payload[0] < minimumHeader) { result.InvalidPackets++; bad = true; continue; }
                var nextFid = flags & 1;
                if (fid is null) fid = nextFid;
                else if (fid != nextFid)
                {
                    Finish("FID change");
                    sawBoundary = true;
                    fid = nextFid;
                }
                if ((flags & 0x40) != 0) { result.UvcErrors++; bad = true; }
                var pixels = payload[payload[0]..];
                if (pixels.Length > frame.Length - frameLength) { bad = true; frameLength = frame.Length; }
                else { pixels.CopyTo(frame.AsSpan(frameLength)); frameLength += pixels.Length; }
                if ((flags & 2) != 0) { Finish("EOF"); sawBoundary = true; }
            }
        }
        if (frameLength != 0) result.UnconfirmedFrames++;
        return result;
    }

    private static void ParseFormats(ReadOnlySpan<byte> config, List<Format> formats, List<ColorDescriptor> colors)
    {
        var offset = 0;
        int interfaceNumber = -1, videoFormat = -1;
        string? fourCC = null;
        byte bitDepth = 0;
        while (offset + 2 <= config.Length)
        {
            var length = config[offset];
            if (length < 2 || length > config.Length - offset) throw new InvalidDataException("Invalid USB descriptor length.");
            var descriptor = config.Slice(offset, length);
            if (descriptor[1] == 4 && length >= 9)
            {
                interfaceNumber = descriptor[5] == 14 && descriptor[6] == 2 ? descriptor[2] : -1;
                videoFormat = -1;
                fourCC = null;
            }
            else if (interfaceNumber >= 0 && descriptor[1] == 0x24 && length >= 4)
            {
                if (descriptor[2] == 4 && length >= 27)
                {
                    videoFormat = descriptor[3];
                    fourCC = Encoding.ASCII.GetString(descriptor.Slice(5, 4));
                    bitDepth = descriptor[21];
                }
                else if (descriptor[2] is 6 or 0x10)
                {
                    videoFormat = -1;
                    fourCC = null;
                }
                else if (descriptor[2] == 5 && length >= 26 && videoFormat >= 0 && fourCC is not null)
                {
                    var item = new Format((byte)interfaceNumber, (byte)videoFormat, descriptor[3], fourCC,
                        BinaryPrimitives.ReadUInt16LittleEndian(descriptor[5..]), BinaryPrimitives.ReadUInt16LittleEndian(descriptor[7..]), bitDepth);
                    if (!formats.Contains(item)) formats.Add(item);
                }
                else if (descriptor[2] == 0x0d && length >= 6 && videoFormat >= 0 && fourCC is not null)
                {
                    var item = new ColorDescriptor((byte)interfaceNumber, (byte)videoFormat, descriptor[3], descriptor[4], descriptor[5]);
                    if (!colors.Contains(item)) colors.Add(item);
                }
            }
            offset += length;
        }
        if (offset != config.Length) throw new InvalidDataException("Truncated USB configuration descriptor.");
    }

    private static int ReadAtMost(Stream stream, byte[] buffer)
    {
        var total = 0;
        while (total < buffer.Length)
        {
            var read = stream.Read(buffer, total, buffer.Length - total);
            if (read == 0) break;
            total += read;
        }
        return total;
    }

    private static ushort U16(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(offset, 2));
    private static uint U32(byte[] bytes, int offset) => BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(offset, 4));
}
