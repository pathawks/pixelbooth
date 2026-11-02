using System.Xml.Linq;
using PixelBooth.Core.Capture;

namespace PixelBooth.Core.Imaging;

public static class CaptureMetadata
{
    public const string Namespace = "https://pixelbooth.app/ns/capture/1.0/";
    public static readonly XNamespace Rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
    public static readonly XNamespace X = "adobe:ns:meta/";

    public static XElement Description(CameraFrame frame, Guid captureId, bool yuy2CoSited = false)
    {
        XNamespace pb = Namespace;
        var description = new XElement(Rdf + "Description",
            new XAttribute(Rdf + "about", ""),
            new XAttribute(XNamespace.Xmlns + "pb", pb.NamespaceName),
            new XAttribute(pb + "SchemaVersion", "1"),
            new XAttribute(pb + "CaptureId", captureId.ToString("D")),
            new XAttribute(pb + "HostReceivedTime", frame.ReceivedAt.ToString("O")),
            new XAttribute(pb + "MediaTimestamp100ns", frame.MediaTimestamp100ns),
            new XAttribute(pb + "CameraName", frame.Device.Name),
            new XAttribute(pb + "CameraId", frame.Device.Id),
            new XAttribute(pb + "SourceFormat", frame.Mode.FourCC),
            new XAttribute(pb + "Width", frame.Mode.Width),
            new XAttribute(pb + "Height", frame.Mode.Height),
            new XAttribute(pb + "FrameRate", frame.Mode.FramesPerSecond > 0 ? frame.Mode.FramesPerSecond.ToString("R", System.Globalization.CultureInfo.InvariantCulture) : "unknown"),
            new XAttribute(pb + "ColorPrimariesMF", frame.Mode.Primaries?.ToString() ?? "unknown"),
            new XAttribute(pb + "TransferFunctionMF", frame.Mode.Transfer?.ToString() ?? "unknown"),
            new XAttribute(pb + "ColorMatrixMF", frame.Mode.Matrix?.ToString() ?? "unknown"),
            new XAttribute(pb + "NominalRangeMF", frame.Mode.NominalRange?.ToString() ?? "unknown"),
            new XAttribute(pb + "ChromaSitingMF", frame.Mode.ChromaSiting?.ToString() ?? "unknown"),
            frame.Mode.FourCC == "YUY2" && yuy2CoSited
                ? new XAttribute(pb + "OutputChromaInterpretation", "Co-sited (PixelBooth YUY2 policy)") : null,
            frame.Mode.IsRaw && LosslessTiff.RequiresTiff(frame.Mode) && frame.Mode.Transfer is null or 0
                ? new XAttribute(pb + "OutputTransferInterpretation", "BT.709 (Media Foundation default for unknown transfer)") : null,
            new XAttribute(pb + "Acquisition", "Windows Media Foundation delivered; upstream processing unknown"),
            new XAttribute(pb + "Software", "PixelBooth for Windows"));

        if (frame.FrameMetadata is { Values.Length: > 0 })
            description.Add(new XAttribute(pb + "FrameMetadataSource", "Media Foundation capture metadata attached to this sample"));
        if (frame.FrameMetadata is { } frameInfo)
        {
            foreach (var name in new[] { "ExposureTime100ns", "IsoSpeed", "WhiteBalanceKelvin", "LensPosition", "FocusState" })
            {
                var item = frameInfo.Values.FirstOrDefault(value => value.Name == name && value.Type is "UInt32" or "UInt64");
                if (item is not null) description.Add(new XAttribute(pb + ("Frame" + name), item.Value));
            }
        }
        if (frame.Controls is { } controlInfo)
        {
            description.Add(new XAttribute(pb + "ControlObservationSource", "Windows IKsControl GET; near shutter, not frame synchronized"),
                new XAttribute(pb + "ControlReadStarted", controlInfo.StartedAt.ToString("O")),
                new XAttribute(pb + "ControlReadEnded", controlInfo.CompletedAt.ToString("O")),
                new XAttribute(pb + "ControlReadStatus", controlInfo.Status));
            foreach (var name in new[] { "Exposure", "Focus", "WhiteBalance" })
            {
                var item = controlInfo.Values.FirstOrDefault(value => value.Name == name);
                if (item is null) continue;
                description.Add(new XAttribute(pb + ("Control" + name + "Value"), item.Value),
                    new XAttribute(pb + ("Control" + name + "ObservedAt"), item.ObservedAt.ToString("O")));
                if (item.Unit is not null) description.Add(new XAttribute(pb + ("Control" + name + "Unit"), item.Unit));
                var mode = (item.Flags & 3) switch { 1 => "Automatic", 2 => "Manual", _ => null };
                if (mode is not null) description.Add(new XAttribute(pb + ("Control" + name + "Mode"), mode));
            }
        }

        if (frame.FrameMetadata is { Values.Length: > 0 } metadata)
            description.Add(new XElement(pb + "FrameCaptureMetadata",
                new XElement(Rdf + "Bag", metadata.Values.Select(value =>
                    new XElement(Rdf + "li", new XAttribute(Rdf + "parseType", "Resource"),
                        new XElement(pb + "Name", value.Name), new XElement(pb + "Type", value.Type),
                        new XElement(pb + "Value", value.Value))))));

        if (frame.Controls is { } controls)
        {
            if (controls.Values.Length > 0)
                description.Add(new XElement(pb + "CameraControls",
                    new XElement(Rdf + "Bag", controls.Values.Select(value =>
                        new XElement(Rdf + "li", new XAttribute(Rdf + "parseType", "Resource"),
                            new XElement(pb + "Name", value.Name), new XElement(pb + "PropertySet", value.PropertySet.ToString("D")),
                            new XElement(pb + "PropertyId", value.PropertyId), new XElement(pb + "Value", value.Value),
                            value.Flags is null ? null : new XElement(pb + "Flags", value.Flags.Value),
                            value.Capabilities is null ? null : new XElement(pb + "Capabilities", value.Capabilities.Value),
                            (value.Flags & 3) switch
                            {
                                1 => new XElement(pb + "ControlMode", "Automatic"),
                                2 => new XElement(pb + "ControlMode", "Manual"),
                                _ => null
                            },
                            new XElement(pb + "ObservedAt", value.ObservedAt.ToString("O")),
                            value.Unit is null ? null : new XElement(pb + "Unit", value.Unit))))));
        }
        return description;
    }

    // Standard EXIF-in-XMP fields are populated only from documented per-frame
    // measurements, never from unsynchronized control reads.
    public static XElement? StandardDescription(CameraFrame frame)
    {
        var values = frame.FrameMetadata?.Values;
        if (values is null || values.Any(value => value.Name == "SourceExif")) return null;
        XNamespace exif = "http://ns.adobe.com/exif/1.0/";
        var description = new XElement(Rdf + "Description", new XAttribute(Rdf + "about", ""),
            new XAttribute(XNamespace.Xmlns + "exif", exif));
        var exposure = values.FirstOrDefault(value => value.Name == "ExposureTime100ns" && value.Type == "UInt64");
        if (exposure is not null && ulong.TryParse(exposure.Value, out var ticks) && ticks > 0)
        {
            const ulong denominator = 10_000_000;
            static ulong Gcd(ulong a, ulong b) { while (b != 0) (a, b) = (b, a % b); return a; }
            var gcd = Gcd(ticks, denominator);
            var numerator = ticks / gcd;
            if (numerator <= uint.MaxValue)
                description.Add(new XAttribute(exif + "ExposureTime", $"{numerator}/{denominator / gcd}"));
        }
        var iso = values.FirstOrDefault(value => value.Name == "IsoSpeed" && value.Type == "UInt32");
        if (iso is not null && uint.TryParse(iso.Value, out var speed) && speed is > 0 and <= ushort.MaxValue)
            description.Add(new XElement(exif + "ISOSpeedRatings", new XElement(Rdf + "Seq", new XElement(Rdf + "li", speed))));
        return description.HasElements || description.Attribute(exif + "ExposureTime") is not null ? description : null;
    }

    public static XDocument NewDocument(CameraFrame frame, Guid captureId, bool yuy2CoSited = false, bool includeStandard = true) =>
        new(new XElement(X + "xmpmeta", new XAttribute(XNamespace.Xmlns + "x", X),
            new XElement(Rdf + "RDF", new XAttribute(XNamespace.Xmlns + "rdf", Rdf),
                includeStandard ? StandardDescription(frame) : null, Description(frame, captureId, yuy2CoSited))));
}
