namespace PixelBooth.Core.Imaging;

/// <summary>Collects AVC parameter sets and accepts only a self-contained progressive IDR picture.</summary>
public sealed class H264AccessUnitCollector
{
    private readonly Dictionary<int, Sps> _sps = new();
    private readonly Dictionary<int, Pps> _pps = new();

    public H264Picture? Observe(byte[] annexB)
    {
        var nals = SplitAnnexB(annexB);
        foreach (var nal in nals)
        {
            var type = nal[0] & 31;
            if (type == 7) { var sps = ParseSps(nal); _sps[sps.Id] = sps; }
            if (type == 8) { var pps = ParsePps(nal); _pps[pps.Id] = pps; }
        }
        var slices = nals.Where(n => (n[0] & 31) is >= 1 and <= 5).ToArray();
        if (slices.Length == 0 || slices.Any(n => (n[0] & 31) != 5)) return null;
        int? picturePps = null;
        var previousFirstMb = -1;
        foreach (var nal in slices)
        {
            var bits = new BitReader(nal.AsSpan(1));
            var firstMb = bits.UnsignedExpGolomb();
            var sliceType = bits.UnsignedExpGolomb();
            var ppsId = bits.UnsignedExpGolomb();
            if (sliceType % 5 != 2 || firstMb <= previousFirstMb || (previousFirstMb == -1 && firstMb != 0) ||
                picturePps is not null && picturePps != ppsId)
                throw new InvalidDataException("The H.264 sample does not contain one supported IDR picture.");
            previousFirstMb = firstMb; picturePps = ppsId;
        }
        if (picturePps is null || !_pps.TryGetValue(picturePps.Value, out var selectedPps) || !_sps.TryGetValue(selectedPps.SpsId, out var selectedSps)) return null;
        return new H264Picture(selectedSps.Bytes, selectedPps.Bytes, nals.Where(n => (n[0] & 31) is not (7 or 8 or 9)).ToArray(),
            selectedSps.Width, selectedSps.Height, selectedSps.Chroma, selectedSps.LumaDepth, selectedSps.ChromaDepth);
    }

    public static byte[][] SplitAnnexB(byte[] data)
    {
        var starts = new List<(int Prefix, int Data)>();
        for (var i = 0; i + 3 <= data.Length;)
        {
            var size = i + 4 <= data.Length && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 ? 4 :
                data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 ? 3 : 0;
            if (size > 0) { starts.Add((i, i + size)); i += size; } else i++;
        }
        if (starts.Count == 0 || data.AsSpan(0, starts[0].Prefix).IndexOfAnyExcept((byte)0) >= 0)
            throw new InvalidDataException("H.264 input is not an Annex B byte stream.");
        var result = new List<byte[]>();
        for (var i = 0; i < starts.Count; i++)
        {
            var end = i + 1 < starts.Count ? starts[i + 1].Prefix : data.Length;
            if (end <= starts[i].Data) throw new InvalidDataException("Empty H.264 NAL unit.");
            var nal = data.AsSpan(starts[i].Data, end - starts[i].Data).ToArray();
            if ((nal[0] & 0x80) != 0 || (nal[0] & 31) is 0 or > 23) throw new InvalidDataException("Invalid H.264 NAL unit.");
            result.Add(nal);
        }
        return result.ToArray();
    }

    private sealed record Sps(int Id, int Width, int Height, int Chroma, int LumaDepth, int ChromaDepth, byte[] Bytes);
    private sealed record Pps(int Id, int SpsId, byte[] Bytes);
    private static Pps ParsePps(byte[] nal)
    {
        var bits = new BitReader(nal.AsSpan(1));
        var id = bits.UnsignedExpGolomb(); var spsId = bits.UnsignedExpGolomb();
        if (id > 255 || spsId > 31) throw new InvalidDataException("Invalid H.264 parameter set ID.");
        return new Pps(id, spsId, nal);
    }

    private static Sps ParseSps(byte[] nal)
    {
        if (nal.Length < 5) throw new InvalidDataException("H.264 SPS is truncated.");
        var bits = new BitReader(nal.AsSpan(1));
        var profile = bits.Read(8); bits.Read(8); bits.Read(8);
        var id = bits.UnsignedExpGolomb();
        if (id > 31) throw new InvalidDataException("Invalid H.264 SPS ID.");
        var chroma = 1; var luma = 8; var color = 8; var separate = false;
        if (profile is 100 or 110 or 122 or 244 or 44 or 83 or 86 or 118 or 128 or 138 or 139 or 134 or 135)
        {
            chroma = bits.UnsignedExpGolomb();
            if (chroma > 3) throw new InvalidDataException("Invalid H.264 chroma format.");
            if (chroma == 3) separate = bits.Read(1) != 0;
            luma = checked(8 + bits.UnsignedExpGolomb()); color = checked(8 + bits.UnsignedExpGolomb());
            if (luma > 14 || color > 14 || separate) throw new InvalidDataException("Unsupported H.264 bit depth or separate color planes.");
            bits.Read(1);
            if (bits.Read(1) != 0)
            {
                var count = chroma == 3 ? 12 : 8;
                for (var i = 0; i < count; i++) if (bits.Read(1) != 0) SkipScalingList(bits, i < 6 ? 16 : 64);
            }
        }
        if (bits.UnsignedExpGolomb() > 12) throw new InvalidDataException("Invalid H.264 frame number size.");
        var poc = bits.UnsignedExpGolomb();
        if (poc == 0) { if (bits.UnsignedExpGolomb() > 12) throw new InvalidDataException("Invalid H.264 POC size."); }
        else if (poc == 1)
        {
            bits.Read(1); bits.SignedExpGolomb(); bits.SignedExpGolomb();
            var count = bits.UnsignedExpGolomb(); if (count > 255) throw new InvalidDataException("Invalid H.264 POC cycle.");
            for (var i = 0; i < count; i++) bits.SignedExpGolomb();
        }
        else if (poc != 2) throw new InvalidDataException("Invalid H.264 POC mode.");
        bits.UnsignedExpGolomb(); bits.Read(1);
        var widthMbs = checked(bits.UnsignedExpGolomb() + 1);
        var heightMbs = checked(bits.UnsignedExpGolomb() + 1);
        if (bits.Read(1) == 0) throw new InvalidDataException("Interlaced H.264 pictures are not supported.");
        bits.Read(1);
        var left = 0; var right = 0; var top = 0; var bottom = 0;
        if (bits.Read(1) != 0) { left = bits.UnsignedExpGolomb(); right = bits.UnsignedExpGolomb(); top = bits.UnsignedExpGolomb(); bottom = bits.UnsignedExpGolomb(); }
        var cropX = chroma is 1 or 2 ? 2 : 1; var cropY = chroma == 1 ? 2 : 1;
        var width = checked(widthMbs * 16 - (left + right) * cropX);
        var height = checked(heightMbs * 16 - (top + bottom) * cropY);
        if (width <= 0 || height <= 0 || width > 16384 || height > 16384) throw new InvalidDataException("Invalid H.264 dimensions.");
        return new Sps(id, width, height, chroma, luma, color, nal);
    }

    private static void SkipScalingList(BitReader bits, int size)
    {
        var last = 8; var next = 8;
        for (var i = 0; i < size; i++)
        {
            if (next != 0) next = (last + bits.SignedExpGolomb() + 256) % 256;
            last = next == 0 ? last : next;
        }
    }

    private sealed class BitReader
    {
        private readonly byte[] _bytes;
        private int _position;
        public BitReader(ReadOnlySpan<byte> nal)
        {
            var bytes = new List<byte>(nal.Length); var zeros = 0;
            foreach (var b in nal)
            {
                if (zeros >= 2 && b == 3) { zeros = 0; continue; }
                bytes.Add(b); zeros = b == 0 ? zeros + 1 : 0;
            }
            _bytes = bytes.ToArray();
        }
        public int Read(int count)
        {
            if (count < 0 || count > 24 || (long)_position + count > (long)_bytes.Length * 8) throw new InvalidDataException("Truncated H.264 syntax.");
            var value = 0;
            for (var i = 0; i < count; i++) { value = value << 1 | ((_bytes[_position / 8] >> (7 - _position % 8)) & 1); _position++; }
            return value;
        }
        public int UnsignedExpGolomb()
        {
            var zeros = 0;
            while (Read(1) == 0) { if (++zeros > 24) throw new InvalidDataException("H.264 Exp-Golomb value is too large."); }
            return checked((1 << zeros) - 1 + Read(zeros));
        }
        public int SignedExpGolomb() { var value = UnsignedExpGolomb(); return (value & 1) != 0 ? (value + 1) / 2 : -(value / 2); }
    }
}

public sealed record H264Picture(byte[] Sps, byte[] Pps, byte[][] NalUnits, int Width, int Height, int Chroma, int LumaDepth, int ChromaDepth)
{
    public byte[] CodecHeader => AnnexB(Sps, Pps);

    public static byte[] AnnexB(params byte[][] units)
    {
        using var data = new MemoryStream();
        foreach (var unit in units) { data.Write([0, 0, 0, 1]); data.Write(unit); }
        return data.ToArray();
    }
}
