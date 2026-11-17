using System.Text.Json;
using FusionPlay.Core;

internal static class LyricsDocumentTests
{
    private static readonly ReceiverSnapshot Initial = new()
    {
        ControlsAvailable = true, Phase = ReceiverPhase.Playing, TrackId = "lyrics-a", Title = "Song",
        DurationMs = 200_000, PositionMs = 1_000, LyricsText = "[00:01.000]First"
    };
    public static void Register(Action<string, Action> check)
    {
        check("lyrics: multiple timestamps fractions word tags and translations preserve source order", () =>
        {
            var document = LyricsDocument.Parse("\uFEFF[ar:Artist]\r\n[00:02][00:01.20]First <00:01.250>words\n[00:01.200]译文\n[00:01.200]First words\n[00:03.1]Third\n[00:04.012]Fourth");
            Assert(document.HasLyrics && document.IsTimed && document.Lines.Count == 4, "timed rows missing");
            Assert(document.Lines[0] == new LyricsLine(0, 1_200, "First words", "译文"), "timestamps or translation grouping changed");
            Assert(document.Lines[1].TimeMs == 2_000 && document.Lines[1].Text == "First words", "repeated timestamp was lost");
            Assert(document.Lines[2].TimeMs == 3_100 && document.Lines[3].TimeMs == 4_012, "fraction precision changed");
            Assert(document.ActiveLineIndex(1_199) == -1 && document.ActiveLineIndex(1_200) == 0 && document.ActiveLineIndex(2_999) == 1, "active-line boundary changed");
        });
        check("lyrics: positive offsets advance negative offsets delay and late headers apply once", () =>
        {
            var advanced = LyricsDocument.Parse("[00:01.000]First\n[00:02.000]Second\n[offset:500]");
            Assert(advanced.Lines.Select(line => line.TimeMs).SequenceEqual(new ulong?[] { 500, 1_500 }), "late positive offset did not advance");
            var delayed = LyricsDocument.Parse("[offset:-1500]\n[00:01.000]First");
            Assert(delayed.Lines[0].TimeMs == 2_500, "negative offset did not delay");
            Assert(LyricsDocument.Parse("[offset:999999999]\n[00:01]First").Lines[0].TimeMs == 0, "large positive offset underflowed");
            Assert(LyricsDocument.Parse("[offset:-999999999]\n[00:01]First").Lines[0].TimeMs == (ulong)LyricsDocument.MaxTimestampMs, "large negative offset overflowed");
        });
        check("lyrics: instrumental gaps zero and missing positions never invent a highlighted line", () =>
        {
            var document = LyricsDocument.Parse("[00:00.000]Zero\n[00:01.0]\n[00:02.00]Third");
            Assert(document.Lines.Count == 3 && document.Lines[1].Text == "", "timed gap was discarded");
            Assert(document.ActiveLineIndex(null) == -1 && document.ActiveLineIndex(0) == 0 && document.ActiveLineIndex(1_000) == 1 && document.ActiveLineIndex(ulong.MaxValue) == 2, "zero or gap following changed");
            var plain = LyricsDocument.Parse("[ti:Title]\r\nLine one\rLine two");
            Assert(plain.HasLyrics && !plain.IsTimed && plain.Lines.Count == 2 && plain.ActiveLineIndex(10_000) == -1, "plain text acquired fake timing");
            foreach (var empty in new[] { "", " \n\r", "[ti:Title]\n[ar:Artist]\n[offset:0]", "[00:01]\n[00:02.000]" })
                Assert(!LyricsDocument.Parse(empty).HasLyrics, "metadata/timestamp-only input became lyrics");
            Assert(LyricsDocument.Parse("[00:99]Readable\n[99999:01]Also readable").Lines.All(line => line.TimeMs == null), "invalid timestamp was interpreted as timing");
        });
        check("lyrics: source rows line text translations and timestamp counts are bounded", () =>
        {
            var many = LyricsDocument.Parse(string.Join('\n', Enumerable.Range(0, 5_000).Select(index => $"[{index / 60:00}:{index % 60:00}.000]Line {index}")));
            Assert(many.Lines.Count == LyricsDocument.MaxLines, "timed row limit changed");
            var plain = LyricsDocument.Parse(string.Join('\n', Enumerable.Repeat("Line", 5_000)));
            Assert(plain.Lines.Count == LyricsDocument.MaxLines, "plain row limit changed");
            Assert(!LyricsDocument.Parse(new string('\n', LyricsDocument.MaxSourceBytes) + "[00:01]Outside budget").HasLyrics, "source byte limit was exceeded");
            var unicode = LyricsDocument.Parse(new string('中', LyricsDocument.MaxSourceBytes));
            Assert(unicode.Lines.Count == 1 && unicode.Lines[0].Text.Length == LyricsDocument.MaxLineCharacters && !unicode.Lines[0].Text.Contains('\uFFFD'), "UTF-8 or line clipping broke a character");
            string original = new('a', LyricsDocument.MaxLineCharacters + 50);
            var translation = LyricsDocument.Parse("[00:00]" + original + "\n[00:00]b" + original + "\n[00:00]c" + original + "\n[00:00]d" + original);
            Assert(translation.Lines[0].Text.Length <= LyricsDocument.MaxLineCharacters && translation.Lines[0].Translation != null
                && translation.Lines[0].Translation!.Length <= LyricsDocument.MaxTranslationCharacters, "text/translation limit changed");
            var repeated = LyricsDocument.Parse(string.Concat(Enumerable.Repeat("[00:01]", 80)) + "Repeated");
            Assert(repeated.Lines.Count == 1 && repeated.Lines[0].Text == "Repeated", "timestamp fan-out did not remain bounded and deduplicated");
        });
        check("lyrics: caption updates reuse documents while replacements reject old asynchronous results", () =>
        {
            var state = new LyricsState();
            var first = state.Observe(Initial)!;
            var replacement = Initial with { TrackId = "lyrics-b", LyricsText = "[00:02]Second", PositionMs = 2_000 };
            var second = state.Observe(replacement)!;
            Assert(!state.Complete(first, LyricsDocument.Parse(first.Source)) && state.Loading && !state.Document.HasLyrics, "old track result replaced the new request");
            Assert(state.Complete(second, LyricsDocument.Parse(second.Source)) && state.Available, "new lyric result did not publish");
            var current = state.Document;
            Assert(state.Observe(replacement with { Title = "Second current lyric caption", PositionMs = null }) == null && ReferenceEquals(state.Document, current), "same ID caption reparsed or cleared lyrics");
            var third = state.Observe(replacement with { TrackId = "lyrics-c", LyricsText = "[00:03]Third" })!;
            Assert(state.Loading && state.Available && !state.Document.HasLyrics, "loading replacement collapsed prior availability or exposed old text");
            Assert(state.Complete(third, LyricsDocument.Empty) && !state.Available, "empty parsed result retained visibility");
        });
        check("lyrics: same-track edits disconnect and reconnect invalidate pending publications", () =>
        {
            var state = new LyricsState(); var first = state.Observe(Initial)!;
            var edited = state.Observe(Initial with { LyricsText = "[00:04]Updated" })!;
            Assert(!state.Complete(first, LyricsDocument.Parse(first.Source)), "stale source revision published");
            state.Observe(Initial with { ControlsAvailable = false });
            Assert(!state.Loading && !state.Available && !state.Complete(edited, LyricsDocument.Parse(edited.Source)), "disconnect accepted an old parse");
            var reconnected = state.Observe(Initial)!;
            Assert(reconnected.Version != first.Version && state.Complete(reconnected, LyricsDocument.Parse(reconnected.Source)), "reconnect reused an invalidated request");
            state.Clear(); Assert(!state.Complete(reconnected, state.Document) && !state.Available, "lifecycle clear allowed stale completion");
        });
        check("lyrics: missing positions retain only the last real value while seek previews remain temporary", () =>
        {
            var state = new LyricsState(); state.Observe(Initial);
            state.Observe(Initial with { PositionMs = null });
            Assert(state.Position(null, true) == 1_000, "absent position became zero");
            state.Observe(Initial with { PositionMs = 0 });
            Assert(state.Position(null, true) == 0, "explicit zero was ignored");
            Assert(state.Position(90_000, true) == 90_000 && state.Position(null, true) == 0, "preview changed the last source position");
            state.Observe(Initial with { TrackId = "other", PositionMs = null });
            Assert(state.Position(null, true) == null, "new track inherited the previous time");
            state.Observe(Initial); state.Observe(Initial with { ControlsAvailable = false });
            Assert(state.Position(null, false) == null && state.Position(null, true) == null, "disconnect retained source time");
            var timeline = new PlaybackTimeline(); timeline.Apply(new(1, Initial)); timeline.Begin(new(90_000, Initial.TrackId, Initial.Title));
            state.Observe(Initial); Assert(state.Position(timeline.DisplayPositionMs, true) == 90_000, "lyrics did not follow the presentation seek target");
        });
        check("lyrics: stable IDs protect seeking and raw snapshots keep the ABI wire name", () =>
        {
            var request = Seeking.AtFraction(Initial, 0.5)!;
            Assert(Seeking.MatchesCurrent(Initial with { Title = "Current caption" }, request), "caption invalidated a stable-ID seek");
            Assert(!Seeking.MatchesCurrent(Initial with { TrackId = "other" }, request), "replacement ID matched old seek");
            var fallback = Initial with { TrackId = "" }; var fallbackRequest = Seeking.AtFraction(fallback, 0.5)!;
            Assert(!Seeking.MatchesCurrent(fallback with { Title = "Other" }, fallbackRequest) && !Seeking.SameTrack(fallback, fallback with { Title = "Other" }), "title fallback ignored replacement");
            var json = JsonSerializer.Serialize(Initial, WireJson.Options);
            using var wire = JsonDocument.Parse(json);
            Assert(wire.RootElement.GetProperty("lyrics_text").GetString() == Initial.LyricsText && JsonSerializer.Deserialize<ReceiverSnapshot>(json, WireJson.Options)?.LyricsText == Initial.LyricsText, "raw lyric ABI field did not round-trip");
        });
        check("lyrics: caption-only snapshots keep pending seek feedback but title fallback still guards replacements", () =>
        {
            var timeline = new PlaybackTimeline(); timeline.Apply(new(1, Initial));
            timeline.Begin(new(90_000, Initial.TrackId, Initial.Title));
            timeline.Apply(new(2, Initial with { Title = "First current lyric caption", PositionMs = 1_250 }));
            Assert(timeline.IsPending && timeline.DisplayPositionMs == 90_000, "stable-ID caption cancelled pending feedback");
            var fallback = Initial with { TrackId = "" };
            var fallbackTimeline = new PlaybackTimeline(); fallbackTimeline.Apply(new(1, fallback));
            fallbackTimeline.Begin(new(90_000, "", fallback.Title));
            fallbackTimeline.Apply(new(2, fallback with { Title = "Replacement" }));
            Assert(!fallbackTimeline.IsPending, "fallback title change retained old feedback");
        });
    }
    private static void Assert(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
