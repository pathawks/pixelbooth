using System.Runtime.InteropServices;

namespace PixelBooth.Core.Capture;

/// <summary>Read-only KS property queries through the already opened Media Foundation source.</summary>
internal static class CameraControlReader
{
    private static readonly Guid CameraSet = new("C6E13370-30AC-11D0-A18C-00A0C9118956");
    private static readonly Guid ProcessingSet = new("C6E13360-30AC-11D0-A18C-00A0C9118956");

    private sealed record Property(Guid Set, uint Id, string Name, string? Unit = null);
    private static readonly Property[] Properties =
    [
        new(CameraSet, 0, "Pan"), new(CameraSet, 1, "Tilt"), new(CameraSet, 2, "Roll"),
        new(CameraSet, 3, "Zoom"), new(CameraSet, 4, "Exposure", "log2 seconds"),
        new(CameraSet, 5, "Iris", "f-number times 10"), new(CameraSet, 6, "Focus"),
        new(CameraSet, 7, "ScanMode"), new(CameraSet, 8, "Privacy"),
        new(CameraSet, 19, "AutoExposurePriority"),
        new(ProcessingSet, 0, "Brightness"), new(ProcessingSet, 1, "Contrast"),
        new(ProcessingSet, 2, "Hue"), new(ProcessingSet, 3, "Saturation"),
        new(ProcessingSet, 4, "Sharpness"), new(ProcessingSet, 5, "Gamma"),
        new(ProcessingSet, 6, "ColorEnable"), new(ProcessingSet, 7, "WhiteBalance", "kelvin"),
        new(ProcessingSet, 8, "BacklightCompensation"), new(ProcessingSet, 9, "Gain"),
        new(ProcessingSet, 10, "DigitalMultiplier"), new(ProcessingSet, 11, "DigitalMultiplierLimit"),
        new(ProcessingSet, 12, "WhiteBalanceRed"),
        new(ProcessingSet, 13, "PowerLineFrequency")
    ];

    [StructLayout(LayoutKind.Sequential)]
    private struct KsProperty
    {
        public Guid Set;
        public uint Id;
        public uint Flags;
    }

    // KSPROPERTY's native union has 8-byte alignment, so the containing
    // structure has four trailing padding bytes on Windows.
    [StructLayout(LayoutKind.Sequential, Size = 40)]
    private struct KsValue
    {
        public KsProperty Property;
        public int Value;
        public uint Flags;
        public uint Capabilities;
        public int Value2;
    }

    [ComImport, Guid("28F54685-06FD-11D2-B27A-00A0C9223196"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IKsControl
    {
        [PreserveSig]
        int KsProperty(IntPtr property, uint propertyLength, IntPtr data, uint dataLength, out uint bytesReturned);
    }

    public static unsafe CameraControlSnapshot Read(object source)
    {
        var start = DateTimeOffset.Now;
        var observations = new List<CameraControlObservation>();
        if (source is not IKsControl control)
            return new(start, DateTimeOffset.Now, [], "Camera source does not expose IKsControl");

        foreach (var property in Properties)
        {
            // Property structures can be returned in-place.
            var value = new KsValue { Property = new KsProperty { Set = property.Set, Id = property.Id, Flags = 1 } };
            var hr = control.KsProperty((IntPtr)(&value), (uint)sizeof(KsValue), (IntPtr)(&value), (uint)sizeof(KsValue), out var returned);
            var observedAt = DateTimeOffset.Now;
            if (hr >= 0 && returned >= sizeof(KsValue))
            {
                observations.Add(new(property.Name, property.Set, property.Id, value.Value, value.Flags, value.Capabilities, observedAt, property.Unit));
                if (property.Set == ProcessingSet && property.Id == 12)
                    observations.Add(new("WhiteBalanceBlue", property.Set, property.Id, value.Value2, value.Flags, value.Capabilities, observedAt));
            }
        }

        // This property has three LONG fields, not the usual value/flags/capabilities layout.
        var focal = new KsValue { Property = new KsProperty { Set = CameraSet, Id = 18, Flags = 1 } };
        var focalHr = control.KsProperty((IntPtr)(&focal), (uint)sizeof(KsValue), (IntPtr)(&focal), (uint)sizeof(KsValue), out var focalBytes);
        var focalTime = DateTimeOffset.Now;
        if (focalHr >= 0 && focalBytes >= sizeof(KsValue))
        {
            observations.Add(new("OcularFocalLength", CameraSet, 18, focal.Value, null, null, focalTime));
            observations.Add(new("ObjectiveFocalLengthMinimum", CameraSet, 18, unchecked((int)focal.Flags), null, null, focalTime));
            observations.Add(new("ObjectiveFocalLengthMaximum", CameraSet, 18, unchecked((int)focal.Capabilities), null, null, focalTime));
        }
        return new(start, DateTimeOffset.Now, observations.ToArray(), "Only successful property reads are included");
    }
}
