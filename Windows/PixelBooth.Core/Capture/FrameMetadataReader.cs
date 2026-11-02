using System.Globalization;
using System.Runtime.InteropServices;
using MediaFoundation;

namespace PixelBooth.Core.Capture;

/// <summary>Copies documented camera settings from an individual sample's metadata bag.</summary>
internal static class FrameMetadataReader
{
    internal static readonly Guid CaptureMetadata = new("2EBE23A8-FAF5-444A-A6A2-EB810880AB5D");
    internal static readonly Guid Exposure = new("16B9AE99-CD84-4063-879D-A28C7633729E");
    internal static readonly Guid IsoSpeed = new("E528A68F-B2E3-44FE-8B65-07BF4B5A13FF");
    private const int MaximumBlobBytes = 256 * 1024;

    private static readonly (string Name, Guid Key)[] Properties =
    [
        ("ExposureTime100ns", Exposure),
        ("ExposureCompensation", new("D198AA75-4B62-4345-ABF3-3C31FA12C299")),
        ("IsoSpeed", IsoSpeed),
        ("FocusState", new("A87EE154-997F-465D-B91F-29D53B982B88")),
        ("LensPosition", new("B5FC8E86-11D1-4E70-819B-723A89FA4520")),
        ("SceneMode", new("9CC3B54D-5ED3-4BAE-B388-7670AEF59E13")),
        ("Flash", new("4A51520B-FB36-446C-9DF2-68171B9A0389")),
        ("FlashPower", new("9C0E0D49-0205-491A-BC9D-2D6E1F4D5684")),
        ("WhiteBalanceKelvin", new("C736FD77-0FB9-4E2E-97A2-FCD490739EE9")),
        ("ZoomFactorQ16", new("E50B0B81-E501-42C2-ABF2-857ECB13FA5C")),
        ("IsoGains", new("05802AC9-0E1D-41C7-A8C8-7E7369F84E1E")),
        ("WhiteBalanceGains", new("E7570C8F-2DCB-4C7C-AACE-22ECE7CCE647")),
        ("SensorFrameRate", new("DB51357E-9D3D-4962-B06D-07CE650D9A0A")),
        ("SourceExif", new("2E9575B8-8C31-4A02-8575-42B197B71592")),
        ("RequestedFrameSettingId", new("BB3716D9-8A61-47A4-8197-459C7FF174D5"))
    ];

    public static FrameCaptureMetadata? Read(IMFSample sample)
    {
        object? bagObject = null;
        try
        {
            if ((int)sample.GetUnknown(CaptureMetadata, typeof(IMFAttributes).GUID, out bagObject) < 0 || bagObject is not IMFAttributes bag)
                return null;
            var values = new List<FrameMetadataValue>();
            foreach (var (name, key) in Properties)
            {
                if ((int)bag.GetItemType(key, out var type) < 0) continue;
                if (type == MFAttributeType.Uint32 && (int)bag.GetUINT32(key, out var value32) >= 0)
                    values.Add(new(name, "UInt32", unchecked((uint)value32).ToString(CultureInfo.InvariantCulture)));
                else if (type == MFAttributeType.Uint64 && (int)bag.GetUINT64(key, out var value64) >= 0)
                    values.Add(new(name, "UInt64", unchecked((ulong)value64).ToString(CultureInfo.InvariantCulture)));
                else if (type == MFAttributeType.Blob && (int)bag.GetBlobSize(key, out var length) >= 0 && length >= 0)
                {
                    if (length > MaximumBlobBytes)
                        values.Add(new(name, "BlobOmittedTooLarge", length.ToString(CultureInfo.InvariantCulture)));
                    else
                    {
                        var bytes = new byte[length];
                        if ((int)bag.GetBlob(key, bytes, length, out var actual) >= 0 && actual == length)
                            values.Add(new(name, "BlobBase64", Convert.ToBase64String(bytes)));
                    }
                }
                else values.Add(new(name, "UnsupportedAttributeType", type.ToString()));
            }
            return values.Count == 0 ? null : new(values.ToArray());
        }
        catch (Exception e) when (e is COMException or InvalidCastException or ArgumentException)
        {
            // An optional, malformed driver attribute must not prevent capture.
            return null;
        }
        finally { if (bagObject is not null && Marshal.IsComObject(bagObject)) Marshal.ReleaseComObject(bagObject); }
    }
}
