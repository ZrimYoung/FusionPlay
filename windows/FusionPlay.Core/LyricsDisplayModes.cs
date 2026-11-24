namespace FusionPlay.Core;

/// <summary>Availability is the parsed, session-scoped value; loading alone never opens a panel.</summary>
public static class LyricsDisplayModes
{
    public static bool IsVisible(string mode, bool available) => mode == "automatic" && available;
}
