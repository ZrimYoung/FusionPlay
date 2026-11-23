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
        check("lyrics motion and text sizing: defaults, persistence and invalid settings", () =>
        {
            using var temporary = new TemporaryDirectory();
            string path = Path.Combine(temporary.Path, "ui-preferences.json");
            File.WriteAllText(path, "{\"show_progress\":false}");
            var store = new UiPreferencesStore(temporary.Path);
            Require(store.Value is { LyricsStaggerEnabled: true, LyricsStaggerMilliseconds: 140,
                LyricsFollowDurationMilliseconds: 420, LyricsTextScalePercent: 100,
                WrapTrackMetadata: true }, "old files did not receive lyrics and track display defaults");
            store.Update(store.Value with { LyricsStaggerEnabled = false, LyricsStaggerMilliseconds = 1000,
                LyricsFollowDurationMilliseconds = 1500, LyricsTextScalePercent = 200,
                WrapTrackMetadata = false });
            Require(new UiPreferencesStore(temporary.Path).Value == store.Value, "lyrics and track display settings did not persist");
            var before = store.Value;
            byte[] saved = File.ReadAllBytes(path);
            foreach (var invalid in new[] { before with { LyricsStaggerMilliseconds = -1 }, before with { LyricsStaggerMilliseconds = 1001 },
                before with { LyricsFollowDurationMilliseconds = 99 }, before with { LyricsFollowDurationMilliseconds = 1501 },
                before with { LyricsTextScalePercent = 74 }, before with { LyricsTextScalePercent = 201 } })
            {
                try { store.Update(invalid); throw new InvalidOperationException("invalid motion timing accepted"); }
                catch (ArgumentException) { }
                Require(store.Value == before && File.ReadAllBytes(path).AsSpan().SequenceEqual(saved), "invalid timing modified preferences");
            }
        });
        check("compact player layouts: retain legacy paging, inherit shared controls and persist independent mode options", () =>
        {
            using var temporary = new TemporaryDirectory();
            string path = Path.Combine(temporary.Path, "ui-preferences.json");
            const string legacy = """{"narrow_lyrics_paging":true,"show_progress":false,"lyrics_display_mode":"always"}""";
            File.WriteAllText(path, legacy);
            var store = new UiPreferencesStore(temporary.Path);
            Require(store.Value is { NarrowPlayerLayout: "cover", CoverLyricsPane: "collapsed", LyricsDisplayMode: "always",
                ShowPlayerProgress: false, ShowPlayerTransport: true, AlbumLyricsArtwork: true, AlbumLyricsTrackInfo: true },
                "legacy paging or shared controls did not migrate");
            Require(File.ReadAllText(path) == legacy, "loading changed the original preferences file");

            var cover = store.Value with { CoverLyricsPane = "expanded", CoverShowTransport = false, CoverShowProgress = true };
            store.Update(cover);
            var reopened = new UiPreferencesStore(temporary.Path);
            Require(reopened.Value == cover && !reopened.Value.ShowPlayerTransport && reopened.Value.ShowPlayerProgress,
                "cover state or independent controls did not persist");
            Require(!File.ReadAllText(path).Contains("narrow_lyrics_paging", StringComparison.Ordinal), "the legacy flag was written again");
            var album = cover with { NarrowPlayerLayout = "album", AlbumShowProgress = true, AlbumLyricsArtwork = false, AlbumLyricsTrackInfo = false };
            store.Update(album);
            Require(new UiPreferencesStore(temporary.Path).Value == album && album.ShowPlayerTransport && album.ShowPlayerProgress
                && (album with { NarrowPlayerLayout = "cover" }).ShowPlayerTransport == false,
                "album preferences changed the cover controls or failed to inherit defaults");

            try { store.Update(album with { CoverLyricsPane = "unsupported" }); throw new InvalidOperationException("invalid pane state accepted"); }
            catch (ArgumentException) { }
            try { store.Update(album with { NarrowPlayerLayout = "unsupported" }); throw new InvalidOperationException("invalid layout accepted"); }
            catch (ArgumentException) { }
            Require(store.Value == album && new UiPreferencesStore(temporary.Path).Value == album, "invalid write changed layout preferences");
            File.WriteAllText(path, """{"narrow_lyrics_paging":true,"COVER_LYRICS_PANE":"automatic"}""");
            Require(new UiPreferencesStore(temporary.Path).Value.CoverLyricsPane == "automatic", "legacy paging replaced an explicit pane state");
        });
        check("expanded lyrics: fullscreen content stays centered and bounded independently of the cover height", () =>
        {
            var desktop = ExpandedLyricsLayout.ForWindow(2400, 800, fullScreen: false, reservedHeight: 160);
            Require(desktop.ContentWidth > ExpandedLyricsLayout.MaximumFullScreenContentWidth, "normal window unexpectedly received the fullscreen cap");
            var narrowFullScreen = ExpandedLyricsLayout.ForWindow(650, 410, fullScreen: true, reservedHeight: 160);
            Require(narrowFullScreen.ContentWidth < ExpandedLyricsLayout.MaximumFullScreenContentWidth
                && narrowFullScreen.ArtworkSide <= narrowFullScreen.ArtworkColumn, "narrow fullscreen artwork exceeded its layout");
            foreach (double width in new[] { 1920d, 3440d })
            {
                var fullScreen = ExpandedLyricsLayout.ForWindow(width, 900, fullScreen: true, reservedHeight: 160);
                Require(fullScreen.ContentWidth == ExpandedLyricsLayout.MaximumFullScreenContentWidth
                    && fullScreen.ContentWidth + 2 * fullScreen.HorizontalInset <= width
                    && fullScreen.ArtworkColumn + fullScreen.ColumnGap < fullScreen.ContentWidth,
                    "wide fullscreen overflowed the centered reading bounds");
            }
            var shortFullScreen = ExpandedLyricsLayout.ForWindow(1920, 340, fullScreen: true, reservedHeight: 225);
            Require(Math.Abs(shortFullScreen.ArtworkSide - (340 - 2 * shortFullScreen.VerticalInset - 225)) < .01,
                "cover did not leave room for wrapped metadata and playback controls");
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
