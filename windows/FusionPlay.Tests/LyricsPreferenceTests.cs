using FusionPlay.Core;

internal static class LyricsPreferenceTests
{
    internal static void Register(Action<string, Action> check)
    {
        check("lyrics preferences: display and background modes persist with compatible defaults and isolated invalid values", () =>
        {
            using var temporary = new TemporaryDirectory();
            string path = Path.Combine(temporary.Path, "ui-preferences.json");
            File.WriteAllText(path, "{\"show_progress\":false,\"progress_custom_color\":\"#83BFE3\"}");
            var store = new UiPreferencesStore(temporary.Path);
            Require(store.Value.LyricsDisplayMode == "automatic" && store.Value.LyricsBackgroundMode == "album" && !store.Value.ShowProgress, "old preferences changed");
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
            foreach (string mode in new[] { "acrylic", "album", "acrylic" })
            {
                store.Update(store.Value with { LyricsBackgroundMode = mode });
                Require(new UiPreferencesStore(temporary.Path).Value.LyricsBackgroundMode == mode, "lyrics background did not persist");
                Require(store.Value.LyricsDisplayMode == "never" && store.Value.ProgressCustomColor == "#83BFE3" && !store.Value.ShowProgress, "lyrics background changed other preferences");
            }
            before = File.ReadAllBytes(path);
            foreach (string? invalid in new string?[] { "glass", null })
            {
                try { store.Update(store.Value with { LyricsBackgroundMode = invalid! }); throw new InvalidOperationException("invalid background accepted"); }
                catch (ArgumentException) { }
                Require(File.ReadAllBytes(path).AsSpan().SequenceEqual(before) && store.Value.LyricsBackgroundMode == "acrylic", "invalid background replaced preferences");
            }
            File.WriteAllText(path, "{\"lyrics_background_mode\":\"glass\",\"show_progress\":false}");
            byte[] corrupt = File.ReadAllBytes(path);
            var recovered = new UiPreferencesStore(temporary.Path);
            string backup = Directory.GetFiles(temporary.Path, "ui-preferences.json.invalid-*").Single();
            Require(recovered.Value.LyricsBackgroundMode == "album" && recovered.LoadError.Length > 0
                && File.ReadAllBytes(backup).AsSpan().SequenceEqual(corrupt), "invalid stored background did not preserve its original and recover defaults");
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
