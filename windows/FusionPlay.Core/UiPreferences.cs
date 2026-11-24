using System.Text.Json;
using System.Text.Json.Serialization;

namespace FusionPlay.Core;

public sealed record UiPreferences
{
    public string Language { get; init; } = "zh-Hans";
    public bool ShowTransport { get; init; } = true;
    public bool ShowProgress { get; init; } = true;
    public bool? CoverShowTransport { get; init; }
    public bool? CoverShowProgress { get; init; }
    public bool? AlbumShowTransport { get; init; }
    public bool? AlbumShowProgress { get; init; }
    [JsonIgnore]
    public bool ShowPlayerTransport => (NarrowPlayerLayout == "album" ? AlbumShowTransport : CoverShowTransport) ?? ShowTransport;
    [JsonIgnore]
    public bool ShowPlayerProgress => (NarrowPlayerLayout == "album" ? AlbumShowProgress : CoverShowProgress) ?? ShowProgress;
    public string LyricsDisplayMode { get; init; } = "automatic";
    public string LyricsBackgroundMode { get; init; } = "album";
    public int AlbumBlurStrength { get; init; } = 100;
    public int LyricsTextScalePercent { get; init; } = 100;
    public bool LyricsStaggerEnabled { get; init; } = true;
    public int LyricsStaggerMilliseconds { get; init; } = 140;
    public int LyricsFollowDurationMilliseconds { get; init; } = 420;
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    public bool NarrowLyricsPaging { get; init; }
    public string NarrowPlayerLayout { get; init; } = "cover";
    public string CoverLyricsPane { get; init; } = "automatic";
    public bool AlbumLyricsArtwork { get; init; } = true;
    public bool AlbumLyricsTrackInfo { get; init; } = true;
    public bool CorrectLyricTitles { get; init; }
    public bool WrapTrackMetadata { get; init; } = true;
    public bool AlwaysShowControls { get; init; }
    public bool Pinned { get; init; }
    public bool ShowPinButton { get; init; }
    public bool ShowSettingsButton { get; init; } = true;
    public bool ShowFullScreenButton { get; init; } = true;
    public bool ShowLyricsButton { get; init; } = true;
    public bool ShowTaskbarIcon { get; init; } = true;
    public bool ShowTrayIcon { get; init; } = true;
    public bool AutoStartReceiving { get; init; } = true;
    public string ProgressColorMode { get; init; } = "system";
    public string ProgressCustomColor { get; init; } = "#FFFFFF";
    public string UiFontFamily { get; init; } = "";
    public int UiFontWeight { get; init; } = 400;
    public string PlayerTextRendering { get; init; } = "enhanced";
}

/// <summary>Portable application preferences, independent of receiver identity and audio settings.</summary>
public sealed class UiPreferencesStore
{
    private readonly string path;
    private readonly object gate = new();
    public UiPreferences Value { get; private set; } = new();
    public string LoadError { get; private set; } = "";
    public event Action? Changed;

    public UiPreferencesStore(string dataDirectory)
    {
        path = Path.Combine(dataDirectory, "ui-preferences.json");
        if (!File.Exists(path)) return;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            Value = document.RootElement.Deserialize<UiPreferences>(WireJson.Options)
                ?? throw new JsonException("UI preferences are empty.");
            if (Value.LyricsDisplayMode == "always")
                Value = Value with { LyricsDisplayMode = "automatic" };
            if (Value.NarrowLyricsPaging)
            {
                bool hasPanePreference = document.RootElement.EnumerateObject().Any(property =>
                    string.Equals(property.Name, "cover_lyrics_pane", StringComparison.OrdinalIgnoreCase));
                Value = Value with { NarrowLyricsPaging = false, CoverLyricsPane = hasPanePreference ? Value.CoverLyricsPane : "collapsed" };
            }
            Validate(Value);
        }
        catch (Exception error) when (error is JsonException or ArgumentException)
        {
            // Keep the exact original, so a malformed preference never destroys recoverable data.
            File.Move(path, path + ".invalid-" + Guid.NewGuid().ToString("N"));
            Value = new();
            LoadError = "界面设置无法读取，已保留原文件并恢复默认外观。";
        }
    }

    public void Update(UiPreferences preferences)
    {
        Validate(preferences);
        lock (gate)
        {
            if (preferences == Value) return;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            string temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(temporary, JsonSerializer.Serialize(preferences, WireJson.Options));
                File.Move(temporary, path, true);
                Value = preferences;
                LoadError = "";
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
            }
        }
        Changed?.Invoke();
    }

    private static void Validate(UiPreferences preferences)
    {
        if (preferences.Language is not ("zh-Hans" or "en"))
            throw new ArgumentException("Unsupported interface language.", nameof(preferences));
        if (preferences.UiFontFamily == null || preferences.UiFontFamily.Length > 256 || preferences.UiFontFamily.Any(char.IsControl))
            throw new ArgumentException("Invalid interface font family.", nameof(preferences));
        if (preferences.UiFontWeight is < 1 or > 999)
            throw new ArgumentException("Invalid interface font weight.", nameof(preferences));
        if (preferences.PlayerTextRendering is not ("system" or "enhanced"))
            throw new ArgumentException("Unsupported player text rendering.", nameof(preferences));
        if (preferences.LyricsDisplayMode is not ("automatic" or "never"))
            throw new ArgumentException("Unsupported lyrics display mode.", nameof(preferences));
        if (preferences.NarrowPlayerLayout is not ("cover" or "album"))
            throw new ArgumentException("Unsupported mini player layout.", nameof(preferences));
        if (preferences.CoverLyricsPane is not ("automatic" or "expanded" or "collapsed"))
            throw new ArgumentException("Unsupported cover lyrics pane state.", nameof(preferences));
        if (preferences.LyricsBackgroundMode is not ("album" or "acrylic"))
            throw new ArgumentException("Unsupported lyrics background mode.", nameof(preferences));
        if (preferences.AlbumBlurStrength is < 0 or > 100)
            throw new ArgumentException("Invalid album blur strength.", nameof(preferences));
        if (preferences.LyricsTextScalePercent is < 75 or > 200)
            throw new ArgumentException("Invalid lyrics text scale.", nameof(preferences));
        if (preferences.LyricsStaggerMilliseconds is < 0 or > 1000
            || preferences.LyricsFollowDurationMilliseconds is < 100 or > 1500)
            throw new ArgumentException("Invalid lyrics motion timing.", nameof(preferences));
        if (preferences.ProgressColorMode is not ("system" or "white" or "custom"))
            throw new ArgumentException("Unsupported progress color mode.", nameof(preferences));
        string? color = preferences.ProgressCustomColor;
        if (color == null || color.Length != 7 || color[0] != '#' || color.Skip(1).Any(value => !char.IsAsciiHexDigit(value)))
            throw new ArgumentException("Progress color must be an opaque #RRGGBB value.", nameof(preferences));
    }
}
