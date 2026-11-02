using System.Text.Json;
using PixelBooth.Core.Storage;

namespace PixelBooth;

internal sealed class Settings
{
    private static readonly string FilePath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PixelBooth", "settings.json");
    public string Destination { get; set; } = CaptureStore.DefaultDestination;
    public bool Mirror { get; set; }
    public int Countdown { get; set; }
    public string? CameraId { get; set; }
    public Dictionary<string, string> Modes { get; set; } = new();

    public static Settings Load()
    {
        try { return File.Exists(FilePath) ? JsonSerializer.Deserialize<Settings>(File.ReadAllBytes(FilePath)) ?? new() : new(); }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temporary = FilePath + ".tmp";
        File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(this));
        File.Move(temporary, FilePath, true);
    }
}
