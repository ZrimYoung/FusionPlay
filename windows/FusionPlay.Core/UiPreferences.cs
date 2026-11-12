using System.Text.Json;

namespace FusionPlay.Core;

public sealed record UiPreferences
{
    public string Language { get; init; } = "zh-Hans";
    public bool ShowTransport { get; init; } = true;
    public bool AlwaysShowControls { get; init; }
    public bool Pinned { get; init; }
    public bool ShowPinButton { get; init; }
    public bool ShowTaskbarIcon { get; init; } = true;
    public bool ShowTrayIcon { get; init; } = true;
}

/// <summary>Portable presentation preferences, independent of receiver identity and audio settings.</summary>
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
            Value = JsonSerializer.Deserialize<UiPreferences>(File.ReadAllText(path), WireJson.Options)
                ?? throw new JsonException("UI preferences are empty.");
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
    }
}
