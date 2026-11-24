using FusionPlay.Core;

internal static class PlaybackTimelineTests
{
    private static readonly ReceiverSnapshot Initial = new()
    {
        Phase = ReceiverPhase.Playing, ControlsAvailable = true, TrackId = "track", Title = "Song",
        DurationMs = 200_000, PositionMs = 20_000
    };
    public static void Register(Action<string, Action> check)
    {
        check("timeline: seek feedback is immediate while repeated old source positions remain authoritative", () =>
        {
            var timeline = new PlaybackTimeline(() => TimeSpan.Zero); timeline.Apply(new(1, Initial));
            ulong token = timeline.Begin(new(120_000, Initial.TrackId, Initial.Title));
            Assert(token != 0 && timeline.DisplayPositionMs == 120_000 && timeline.Source.PositionMs == 20_000, "click feedback or authoritative position changed");
            timeline.Apply(new(2, Initial)); timeline.Complete(token, dispatched: true);
            Assert(timeline.IsPending && timeline.DisplayPositionMs == 120_000 && timeline.Source.PositionMs == 20_000, "old position erased pending feedback");
            timeline.Apply(new(3, Initial with { PositionMs = 120_500 }));
            Assert(!timeline.IsPending && timeline.DisplayPositionMs == 120_500, "phone report did not replace feedback");
        });
        check("timeline: out-of-order poll continuations cannot rewind a newer post-seek observation", () =>
        {
            var timeline = new PlaybackTimeline(() => TimeSpan.Zero); timeline.Apply(new(10, Initial));
            timeline.Begin(new(120_000, Initial.TrackId, Initial.Title));
            timeline.Apply(new(12, Initial with { PositionMs = 120_250 }));
            Assert(!timeline.Apply(new(11, Initial)) && !timeline.Apply(new(9, null)), "older poll was accepted");
            Assert(timeline.Revision == 12 && timeline.Source.PositionMs == 120_250 && timeline.DisplayPositionMs == 120_250, "older continuation rewound progress");
            Assert(!timeline.Apply(new(12, null)) && timeline.DisplayPositionMs == 120_250, "unchanged poll removed the source position");
        });
        check("timeline: failed or unsent commands restore the latest source, stale completions do not cancel a newer click", () =>
        {
            var timeline = new PlaybackTimeline(() => TimeSpan.Zero); timeline.Apply(new(1, Initial));
            ulong first = timeline.Begin(new(80_000, Initial.TrackId, Initial.Title));
            ulong second = timeline.Begin(new(150_000, Initial.TrackId, Initial.Title));
            timeline.Complete(first, dispatched: false);
            Assert(!timeline.Cancel(first) && !timeline.Expire(first) && timeline.DisplayPositionMs == 150_000, "old completion erased a newer click");
            timeline.Apply(new(2, Initial with { PositionMs = 21_000 }));
            timeline.Complete(second, dispatched: false);
            Assert(!timeline.IsPending && timeline.DisplayPositionMs == 21_000, "failed command did not restore the actual source");
        });
        check("timeline: timeout is bounded and unchanged near-target reports do not prematurely cancel feedback", () =>
        {
            TimeSpan elapsed = TimeSpan.Zero;
            var timeline = new PlaybackTimeline(() => elapsed); timeline.Apply(new(1, Initial));
            ulong token = timeline.Begin(new(21_000, Initial.TrackId, Initial.Title));
            timeline.Apply(new(2, Initial));
            Assert(timeline.IsPending && timeline.DisplayPositionMs == 21_000, "duplicate old position was treated as a seek acknowledgement");
            elapsed = PlaybackTimeline.FeedbackTimeout - TimeSpan.FromMilliseconds(1);
            Assert(!timeline.Expire(token) && timeline.DisplayPositionMs == 21_000, "feedback expired too soon");
            elapsed = PlaybackTimeline.FeedbackTimeout;
            Assert(timeline.DisplayPositionMs == 25_000 && timeline.Expire(token) && !timeline.IsPending, "timeout did not restore the advancing source timeline");
        });
        check("timeline: ordinary near-target playback ticks do not undo a forward seek", () =>
        {
            TimeSpan elapsed = TimeSpan.Zero;
            var timeline = new PlaybackTimeline(() => elapsed); timeline.Apply(new(1, Initial));
            timeline.Begin(new(21_000, Initial.TrackId, Initial.Title));
            elapsed = TimeSpan.FromMilliseconds(250); timeline.Apply(new(2, Initial with { PositionMs = 20_250 }));
            elapsed = TimeSpan.FromMilliseconds(500); timeline.Apply(new(3, Initial with { PositionMs = 20_500 }));
            Assert(timeline.IsPending && timeline.DisplayPositionMs == 21_000 && timeline.Source.PositionMs == 20_500, "normal ticks erased the requested position");
            elapsed = TimeSpan.FromMilliseconds(600); timeline.Apply(new(4, Initial with { PositionMs = 21_250 }));
            Assert(!timeline.IsPending && timeline.DisplayPositionMs == 21_250, "actual target report did not settle the display");
        });
        check("timeline: track, connection and duration changes invalidate feedback without changing the new source", () =>
        {
            foreach (var replacement in new[]
            {
                Initial with { TrackId = "next", PositionMs = 500 },
                Initial with { ControlsAvailable = false, Phase = ReceiverPhase.Ready, PositionMs = null },
                Initial with { DurationMs = 30_000, PositionMs = 3_000 }
            })
            {
                var timeline = new PlaybackTimeline(() => TimeSpan.Zero); timeline.Apply(new(1, Initial));
                ulong token = timeline.Begin(new(120_000, Initial.TrackId, Initial.Title)); timeline.Apply(new(2, replacement));
                timeline.Complete(token, dispatched: true);
                Assert(!timeline.IsPending && timeline.DisplayPositionMs == replacement.PositionMs && timeline.Source == replacement, "old feedback leaked into replacement media");
            }
        });
        check("timeline: sparse source reports keep lyrics advancing through unchanged and partial observations", () =>
        {
            TimeSpan elapsed = TimeSpan.Zero;
            var timeline = new PlaybackTimeline(() => elapsed);
            timeline.Apply(new(1, Initial));
            elapsed = TimeSpan.FromMilliseconds(2_500);
            timeline.Apply(new(2, Initial with { LyricsText = "[00:22.00]Synthetic lyric" }));
            elapsed = TimeSpan.FromMilliseconds(3_000);
            timeline.Apply(new(3, Initial with { PositionMs = null }));
            elapsed = TimeSpan.FromMilliseconds(8_000);
            Assert(timeline.DisplayPositionMs == 28_000 && timeline.IsAdvancing && timeline.Source.PositionMs == null,
                "unrelated metadata stopped progress or mutated the authoritative snapshot");
            timeline.Apply(new(4, Initial));
            Assert(timeline.DisplayPositionMs == 28_000, "a duplicate after omitted progress re-anchored playback");
        });
        check("timeline: pauses freeze without a fresh position and resuming excludes time spent paused", () =>
        {
            TimeSpan elapsed = TimeSpan.Zero;
            var timeline = new PlaybackTimeline(() => elapsed);
            timeline.Apply(new(1, Initial));
            elapsed = TimeSpan.FromSeconds(3);
            timeline.Apply(new(2, Initial with { Phase = ReceiverPhase.Paused }));
            elapsed = TimeSpan.FromSeconds(12);
            Assert(timeline.DisplayPositionMs == 23_000 && !timeline.IsAdvancing, "time spent paused advanced playback");
            timeline.Apply(new(3, Initial));
            elapsed = TimeSpan.FromSeconds(13);
            Assert(timeline.DisplayPositionMs == 24_000 && timeline.IsAdvancing, "resume lost the paused position");
            timeline.Apply(new(4, Initial with { Phase = ReceiverPhase.Paused, PositionMs = 23_750 }));
            Assert(timeline.DisplayPositionMs == 23_750, "a fresh pause position did not supersede the estimate");
        });
        check("timeline: late forward samples reconcile without rewinding while real jumps and zero remain authoritative", () =>
        {
            TimeSpan elapsed = TimeSpan.Zero;
            var timeline = new PlaybackTimeline(() => elapsed);
            timeline.Apply(new(1, Initial));
            elapsed = TimeSpan.FromSeconds(5);
            timeline.Apply(new(2, Initial with { PositionMs = 24_700 }));
            Assert(timeline.DisplayPositionMs == 25_000, "small receive jitter rewound a lyric");
            elapsed += TimeSpan.FromMilliseconds(500);
            Assert(timeline.DisplayPositionMs == 25_200, "late sample did not reconcile after the brief hold");
            timeline.Apply(new(3, Initial with { PositionMs = 24_000 }));
            Assert(timeline.DisplayPositionMs == 24_000, "backward source seek was smoothed away");
            timeline.Apply(new(4, Initial with { PositionMs = 0 }));
            Assert(timeline.DisplayPositionMs == 0, "explicit seek to zero was ignored");
        });
        check("timeline: estimates clamp to duration and never carry to a new or disconnected track", () =>
        {
            TimeSpan elapsed = TimeSpan.Zero;
            var timeline = new PlaybackTimeline(() => elapsed);
            timeline.Apply(new(1, Initial with { PositionMs = 199_000 }));
            elapsed = TimeSpan.FromSeconds(5);
            Assert(timeline.DisplayPositionMs == 200_000 && !timeline.IsAdvancing, "player ran beyond the track end");
            var next = Initial with { TrackId = "next", PositionMs = null };
            timeline.Apply(new(2, next));
            Assert(timeline.DisplayPositionMs == null && !timeline.IsAdvancing, "new track inherited prior timing");
            timeline.Apply(new(3, next with { PositionMs = 1_000 }));
            Assert(timeline.DisplayPositionMs == 1_000 && timeline.IsAdvancing, "first position for new track did not start playback");
            timeline.Apply(new(4, next with { ControlsAvailable = false, Phase = ReceiverPhase.Ready, PositionMs = 1_000 }));
            Assert(timeline.DisplayPositionMs == null && !timeline.IsAdvancing, "disconnected state retained a cursor");
        });
    }
    private static void Assert(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
