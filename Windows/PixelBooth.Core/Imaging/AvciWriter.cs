using System.Buffers.Binary;
using System.Text;
using PixelBooth.Core.Capture;

namespace PixelBooth.Core.Imaging;

/// <summary>Wraps a complete AVC IDR picture in a single-image HEIF container without recompression.</summary>
public static class AvciWriter
{
    public static byte[] Write(H264Picture picture, CameraFrame frame, Guid captureId)
    {
        if (picture.Width != frame.Mode.Width || picture.Height != frame.Mode.Height)
            throw new InvalidDataException("The H.264 picture dimensions do not match the selected camera mode.");
        if (picture.Sps.Length > ushort.MaxValue || picture.Pps.Length > ushort.MaxValue || picture.Sps.Length < 4 || picture.NalUnits.Length == 0)
            throw new InvalidDataException("Invalid AVC parameter sets or picture.");
        var image = new MemoryStream();
        foreach (var nal in picture.NalUnits)
        {
            if (nal.Length == 0) throw new InvalidDataException("Empty AVC NAL unit.");
            WriteU32(image, checked((uint)nal.Length)); image.Write(nal);
        }
        var xmp = Encoding.UTF8.GetBytes(CaptureMetadata.NewDocument(frame, captureId).ToString());
        var fileType = Box("ftyp", FourCC("avci"), U32(0), FourCC("mif1"), FourCC("avci"));
        byte[] Meta(uint imageOffset, uint xmpOffset)
        {
            var handler = FullBox("hdlr", 0, U32(0), FourCC("pict"), new byte[12], Z("PixelBooth"));
            var primary = FullBox("pitm", 0, U16(1));
            byte[] Location(ushort id, uint offset, uint length) => Join(U16(id), U16(0), U16(1), U32(offset), U32(length));
            var locations = FullBox("iloc", 0, [0x44, 0], U16(2), Location(1, imageOffset, checked((uint)image.Length)), Location(2, xmpOffset, checked((uint)xmp.Length)));
            var imageInfo = FullBox("infe", 2, U16(1), U16(0), FourCC("avc1"), Z("image"));
            var xmpInfo = FullBox("infe", 2, U16(2), U16(0), FourCC("mime"), Z("XMP"), Z("application/rdf+xml"), Z(""));
            var itemInfo = FullBox("iinf", 0, U16(2), imageInfo, xmpInfo);
            var references = FullBox("iref", 0, Box("cdsc", U16(2), U16(1), U16(1)));
            var dimensions = FullBox("ispe", 0, U32((uint)picture.Width), U32((uint)picture.Height));
            var config = new MemoryStream();
            config.Write([1, picture.Sps[1], picture.Sps[2], picture.Sps[3], 0xff, 0xe1]);
            config.Write(U16((ushort)picture.Sps.Length)); config.Write(picture.Sps);
            config.WriteByte(1); config.Write(U16((ushort)picture.Pps.Length)); config.Write(picture.Pps);
            if (picture.Sps[1] is 100 or 110 or 122 or 144)
                config.Write([(byte)(0xfc | picture.Chroma), (byte)(0xf8 | (picture.LumaDepth - 8)), (byte)(0xf8 | (picture.ChromaDepth - 8)), 0]);
            var avcc = Box("avcC", config.ToArray());
            var pixelInfo = picture.Chroma == 0 ? new byte[] { 1, (byte)picture.LumaDepth } :
                [(byte)3, (byte)picture.LumaDepth, (byte)picture.ChromaDepth, (byte)picture.ChromaDepth];
            var properties = Box("iprp", Box("ipco", dimensions, avcc, FullBox("pixi", 0, pixelInfo)),
                FullBox("ipma", 0, U32(1), U16(1), [3, 0x81, 0x82, 0x03]));
            return FullBox("meta", 0, handler, primary, locations, itemInfo, references, properties);
        }
        var provisional = Meta(0, 0);
        var imageOffset = checked((uint)(fileType.Length + provisional.Length + 8));
        var metadataOffset = checked(imageOffset + (uint)image.Length);
        var metadata = Meta(imageOffset, metadataOffset);
        return Join(fileType, metadata, Box("mdat", image.ToArray(), xmp));
    }

    private static byte[] FullBox(string type, byte version, params byte[][] contents) => Box(type, Join([version, 0, 0, 0], Join(contents)));
    private static byte[] Box(string type, params byte[][] contents)
    {
        var payload = Join(contents);
        return Join(U32(checked((uint)(payload.Length + 8))), FourCC(type), payload);
    }
    private static byte[] Join(params byte[][] parts)
    {
        var result = new byte[parts.Sum(p => p.Length)]; var offset = 0;
        foreach (var part in parts) { part.CopyTo(result, offset); offset += part.Length; }
        return result;
    }
    private static byte[] FourCC(string value) => value.Length == 4 ? Encoding.ASCII.GetBytes(value) : throw new ArgumentException("A box type must have four characters.");
    private static byte[] Z(string value) => Encoding.UTF8.GetBytes(value + "\0");
    private static byte[] U16(ushort value) { var b = new byte[2]; BinaryPrimitives.WriteUInt16BigEndian(b, value); return b; }
    private static byte[] U32(uint value) { var b = new byte[4]; BinaryPrimitives.WriteUInt32BigEndian(b, value); return b; }
    private static void WriteU32(Stream output, uint value) => output.Write(U32(value));
}
