using FusionPlay.Core;

internal static class DisplayMetadataTests
{
    internal static void Register(Action<string, Action> check)
    {
        check("display metadata: 45 Mac parity cases require independent header and caption evidence", () =>
        {
            int cases = 0;
            void Unchanged(string title, string artist = "Example Artist", string album = "Example Album", string lyrics = "")
            {
                Require(DisplayMetadataResolver.Resolve(title, artist, album, lyrics) == new DisplayMetadata(title, artist, album), "unverified metadata changed");
                cases++;
            }
            void Recovered(string title, string artist, string album = "Example Album", string lyrics = "",
                string expectedTitle = "A Synthetic Question (Explicit)", string expectedArtist = "Example Artist", string expectedAlbum = "Example Album")
            {
                var value = DisplayMetadataResolver.Resolve(title, artist, album, lyrics);
                Require(value == new DisplayMetadata(expectedTitle, expectedArtist, expectedAlbum, true), "verified metadata did not recover");
                cases++;
            }
            const string headers = "[ti:A Synthetic Question (Explicit)]\n[ar:Example Artist]\n[al:Example Album]\n";
            const string row = "[00:01.00]Someone may touch her, just once.\n";
            const string composite = "A Synthetic Question (Explicit)-Example Artist";
            Recovered("touch her", composite, lyrics: headers + row);
            Recovered("TOUCH   HER", composite, lyrics: headers + row);
            Recovered("touch her", "A Synthetic Question (Explicit) - Example Artist - Example Album", lyrics: headers + row);
            Recovered("touch her", "A Synthetic Question (Explicit)—Example Artist", lyrics: headers + row);
            Recovered("touch her", "Example Artist", lyrics: headers + row);
            Recovered("touch her", "", lyrics: headers + row);
            Recovered("touch her", composite, album: "", lyrics: headers + row);
            Recovered("", composite, lyrics: headers);
            Recovered("touch her", composite, album: "A Different Album", lyrics: headers + row, expectedAlbum: "A Different Album");

            Unchanged("A Synthetic Question (Explicit)", lyrics: headers + "[00:01]A Synthetic Question (Explicit)");
            Unchanged("a synthetic question (explicit)", lyrics: headers + row);
            Unchanged("An Actual New Song", "Artist-With-Hyphens", lyrics: headers + row);
            Unchanged("touch her", "Artist-With-Hyphens", lyrics: "[00:01]Someone may touch her");
            Unchanged("touch her", composite);
            Recovered("touch her", "Artist-With-Hyphens", lyrics: headers + row, expectedArtist: "Artist-With-Hyphens");
            Recovered("touch her", "Song-With-Hyphens - Band-With-Hyphens", lyrics: "[ti:Song-With-Hyphens]\n[ar:Band-With-Hyphens]\n" + row,
                expectedTitle: "Song-With-Hyphens", expectedArtist: "Band-With-Hyphens");
            Recovered("touch her", "Song-With-Hyphens - Band-With-Hyphens", lyrics: "[ar:Band-With-Hyphens]\n" + row,
                expectedTitle: "Song-With-Hyphens", expectedArtist: "Band-With-Hyphens");
            Recovered("touch her", "Song-With-Hyphens - Band-With-Hyphens", lyrics: "[ti:Song-With-Hyphens]\n" + row,
                expectedTitle: "Song-With-Hyphens", expectedArtist: "Band-With-Hyphens");
            Unchanged("touch her", "Unknown-Composite-Artist", lyrics: row);
            Unchanged("touch her", "Song-Example Artist-Example Artist", album: "Example Artist", lyrics: "[ar:Example Artist]\n" + row);

            Unchanged("touch her", composite, lyrics: headers + "[00:01]Do not untouch her\n");
            Unchanged("touch her", composite, lyrics: headers + "[00:01]She can touch herself\n");
            Unchanged("touch her", composite, lyrics: headers + "[00:01]She can touch her-kind\n");
            Unchanged("touch her", composite, lyrics: headers + "[00:01]Do not pre-touch her\n");
            Unchanged("touch her", composite, lyrics: headers + "[00:01]She can touch her's\n");
            Unchanged("touch her", composite, lyrics: headers + "[00:01]Please touch\n[00:02]her hand\n");
            Unchanged("touch her", composite, lyrics: headers + "Someone may touch her\n");
            Unchanged("touch", composite, lyrics: headers + "[00:01]touch\n");
            Unchanged("I", composite, lyrics: headers + "[00:01]I\n");
            Unchanged("x-ray", composite, lyrics: headers + "[00:01]x-ray\n");
            Recovered("don't leave", composite, lyrics: headers + "[00:01]Please don’t leave today\n");
            Recovered("touch her", composite, lyrics: headers + "[00:01]<00:01.00>touch <00:01.50>her hand\n");
            Recovered("touch her", composite, lyrics: headers + "[00:01]Original row\n[00:01]Please touch her hand\n");
            Recovered("穿过安静", composite, lyrics: headers + "[00:01]我们穿过安静街道\n");
            Unchanged("过安静", composite, lyrics: headers + "[00:01]我们穿过安静街道\n");
            Unchanged("静", composite, lyrics: headers + "[00:01]静\n");

            Unchanged("touch her", composite, lyrics: headers + "[ti:A Conflicting Title]\n" + row);
            Unchanged("touch her", composite, lyrics: headers + "[ar:A Conflicting Artist]\n" + row);
            Recovered("touch her", composite, lyrics: headers + "[TI:A Synthetic Question (Explicit)]\n" + row);
            Recovered("touch her", composite, lyrics: "\uFEFF[ti:A Synthetic Question (Explicit)][ar:Example Artist]\r\n" + row);
            Unchanged("touch her", composite, lyrics: "[00:01][ti:A Synthetic Question (Explicit)]touch her\n");
            Unchanged("touch her", composite, lyrics: "[ti:" + new string('a', 513) + "]\n" + row);
            Unchanged("touch her", composite, lyrics: "[ti:Invalid\u0001Title]\n" + row);
            Unchanged("touch her", composite, lyrics: headers + row + new string('x', LyricsDocument.MaxSourceBytes));
            Recovered("A Synthetic Question (Explicit)", composite, lyrics: headers + row);
            Require(cases == 45, "Mac parity fixture count changed");
        });
        check("display metadata: unicode evidence is bounded and malformed UTF-16 fails closed", () =>
        {
            const string source = "[ti:Ａｃｔｕａｌ Ｓｏｎｇ][ar:Band]\n[00:01]Here are two words\n";
            var wide = DisplayMetadataResolver.Resolve("two words", "Actual Song - Band", "", source);
            Require(wide.Title == "Ａｃｔｕａｌ Ｓｏｎｇ" && wide.Artist == "Band" && wide.WasCorrected, "width-equivalent full fields did not match");
            var malformed = DisplayMetadataResolver.Resolve("two words", "Band", "", "[ti:Invalid\uD800]\n[00:01]two words");
            Require(malformed == new DisplayMetadata("two words", "Band", ""), "invalid UTF-16 supplied header evidence");
            string oversized = new('a', 4_097);
            Require(DisplayMetadataResolver.Resolve("two words", oversized, "", source) == new DisplayMetadata("two words", oversized, ""), "oversized composite field acquired correction evidence");
            const string astralCaption = "𠀀𠀁𠀂𠀃";
            var astral = DisplayMetadataResolver.Resolve(astralCaption, "Band", "", "[ti:Actual Song]\n[00:01]" + astralCaption + "街道");
            Require(astral.Title == "Actual Song" && astral.WasCorrected, "astral CJK caption count used UTF-16 halves");
        });
        check("display metadata: one transient cache is reused and reset without replacing source or seek identity", () =>
        {
            var source = new ReceiverSnapshot
            {
                Phase = ReceiverPhase.Paused, ControlsAvailable = true, TrackId = "fixture-track", Title = "two words", Artist = "Band", Album = "Album",
                LyricsText = "[ti:Actual Song][ar:Band]\n[00:01]Please say two words again", PositionMs = 2_000, DurationMs = 10_000
            };
            var original = source with { };
            var request = Seeking.AtFraction(source, .5)!;
            var cache = new DisplayMetadataCache();
            var first = cache.Resolve(source.Title, source.Artist, source.Album, source.LyricsText);
            Require(ReferenceEquals(first, cache.Resolve(source.Title, source.Artist, source.Album, source.LyricsText)), "unchanged UI tick reparsed lyrics");
            Require(first.Title == "Actual Song" && source == original && request.ExpectedTrackId == "fixture-track" && request.ExpectedTitle == "two words"
                && Seeking.MatchesCurrent(source, request), "display metadata replaced the authoritative playback identity");
            var replacement = cache.Resolve("Fresh Song", "Other", "", "");
            Require(replacement == new DisplayMetadata("Fresh Song", "Other", ""), "one-entry cache retained the previous song");
            cache.Reset();
            Require(!ReferenceEquals(replacement, cache.Resolve("Fresh Song", "Other", "", "")), "session reset retained cached metadata");
        });
        check("display metadata: correction preference defaults off and survives portable reopen", () =>
        {
            using var directory = new TemporaryDirectory();
            File.WriteAllText(Path.Combine(directory.Path, "ui-preferences.json"), "{\"show_progress\":false,\"lyrics_display_mode\":\"never\"}");
            var store = new UiPreferencesStore(directory.Path);
            Require(!store.Value.CorrectLyricTitles, "legacy preferences silently enabled title correction");
            store.Update(store.Value with { CorrectLyricTitles = true });
            var reopened = new UiPreferencesStore(directory.Path);
            Require(reopened.Value.CorrectLyricTitles && !reopened.Value.ShowProgress && reopened.Value.LyricsDisplayMode == "never", "correction preference lost or changed other preferences");
            reopened.Update(reopened.Value with { CorrectLyricTitles = false });
            Require(!new UiPreferencesStore(directory.Path).Value.CorrectLyricTitles, "disabled correction did not persist");
        });
        check("presentation presence: metadata gaps retain controls while idle and disconnected phases stay empty", () =>
        {
            foreach (var phase in new[] { ReceiverPhase.Playing, ReceiverPhase.Paused })
                Require(DisplayMetadataResolver.HasCurrentTrack(new() { Phase = phase, ControlsAvailable = false }), "temporary control loss hid a live track");
            Require(!DisplayMetadataResolver.HasCurrentTrack(new() { Phase = ReceiverPhase.Connected, ControlsAvailable = true }), "a control-only connection displayed a song");
            foreach (var state in new[] { new ReceiverSnapshot { TrackId = "known" }, new ReceiverSnapshot { Title = "Known Song" }, new ReceiverSnapshot { DurationMs = 1000 } })
            {
                Require(DisplayMetadataResolver.HasCurrentTrack(state with { Phase = ReceiverPhase.Connected }), "incomplete known track hid controls");
                foreach (var phase in new[] { ReceiverPhase.Ready, ReceiverPhase.Stopped, ReceiverPhase.Failed })
                    Require(!DisplayMetadataResolver.HasCurrentTrack(state with { Phase = phase, ControlsAvailable = true }), "idle phase retained a previous title");
            }
        });
    }

    private static void Require(bool condition, string message)
    { if (!condition) throw new InvalidOperationException(message); }
}
