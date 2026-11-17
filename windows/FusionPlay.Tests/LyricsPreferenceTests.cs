using FusionPlay.Core;

internal static class LyricsPreferenceTests
{
    internal static void Register(Action<string, Action> check)
    {
        check("lyrics preferences: modes persist, old data defaults to automatic, invalid writes stay isolated", () =>
        {
            using var temporary = new TemporaryDirectory();
            string path = Path.Combine(temporary.Path, "ui-preferences.json");
            File.WriteAllText(path, "{\"show_progress\":false,\"progress_custom_color\":\"#83BFE3\"}");
            var store = new UiPreferencesStore(temporary.Path);
            Require(store.Value.LyricsDisplayMode == "automatic" && !store.Value.ShowProgress, "old preferences changed");
            foreach (string mode in new[] { "automatic", "always", "never" })
            {
                store.Update(store.Value with { LyricsDisplayMode = mode });
                Require(new UiPreferencesStore(temporary.Path).Value.LyricsDisplayMode == mode, "lyrics mode did not persist");
                Require(store.Value.ProgressCustomColor == "#83BFE3" && !store.Value.ShowProgress, "other preferences changed");
            }
            byte[] before = File.ReadAllBytes(path);
            try { store.Update(store.Value with { LyricsDisplayMode = "unsupported" }); throw new InvalidOperationException("invalid mode accepted"); }
            catch (ArgumentException) { }
            Require(File.ReadAllBytes(path).AsSpan().SequenceEqual(before) && store.Value.LyricsDisplayMode == "never", "invalid mode replaced preferences");
        });
        check("lyrics display: automatic follows parsed availability, explicit choices stay stable", () =>
        {
            foreach (bool available in new[] { false, true })
            {
                Require(LyricsDisplayModes.IsVisible("automatic", available) == available, "automatic visibility incorrect");
                Require(LyricsDisplayModes.IsVisible("always", available), "always-on visibility incorrect");
                Require(!LyricsDisplayModes.IsVisible("never", available), "always-off visibility incorrect");
            }
        });
    }
    private static void Require(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
}
