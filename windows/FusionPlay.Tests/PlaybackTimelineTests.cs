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
            var timeline = new PlaybackTimeline(); timeline.Apply(new(1, Initial));
            ulong token = timeline.Begin(new(120_000, Initial.TrackId, Initial.Title));
            Assert(token != 0 && timeline.DisplayPositionMs == 120_000 && timeline.Source.PositionMs == 20_000, "click feedback or authoritative position changed");
            timeline.Apply(new(2, Initial)); timeline.Complete(token, dispatched: true);
            Assert(timeline.IsPending && timeline.DisplayPositionMs == 120_000 && timeline.Source.PositionMs == 20_000, "old position erased pending feedback");
            timeline.Apply(new(3, Initial with { PositionMs = 120_500 }));
            Assert(!timeline.IsPending && timeline.DisplayPositionMs == 120_500, "phone report did not replace feedback");
        });
        check("timeline: out-of-order poll continuations cannot rewind a newer post-seek observation", () =>
        {
            var timeline = new PlaybackTimeline(); timeline.Apply(new(10, Initial));
            timeline.Begin(new(120_000, Initial.TrackId, Initial.Title));
            timeline.Apply(new(12, Initial with { PositionMs = 120_250 }));
            Assert(!timeline.Apply(new(11, Initial)) && !timeline.Apply(new(9, null)), "older poll was accepted");
            Assert(timeline.Revision == 12 && timeline.Source.PositionMs == 120_250 && timeline.DisplayPositionMs == 120_250, "older continuation rewound progress");
            Assert(!timeline.Apply(new(12, null)) && timeline.DisplayPositionMs == 120_250, "unchanged poll removed the source position");
        });
        check("timeline: failed or unsent commands restore the latest source, stale completions do not cancel a newer click", () =>
        {
            var timeline = new PlaybackTimeline(); timeline.Apply(new(1, Initial));
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
            Assert(timeline.DisplayPositionMs == 20_000 && timeline.Expire(token) && !timeline.IsPending, "timeout kept unconfirmed progress indefinitely");
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
                Initial with { TrackId = "next", PositionMs = 500 }, Initial with { Title = "Other", PositionMs = 700 },
                Initial with { ControlsAvailable = false, Phase = ReceiverPhase.Ready, PositionMs = null },
                Initial with { DurationMs = 30_000, PositionMs = 3_000 }
            })
            {
                var timeline = new PlaybackTimeline(); timeline.Apply(new(1, Initial));
                ulong token = timeline.Begin(new(120_000, Initial.TrackId, Initial.Title)); timeline.Apply(new(2, replacement));
                timeline.Complete(token, dispatched: true);
                Assert(!timeline.IsPending && timeline.DisplayPositionMs == replacement.PositionMs && timeline.Source == replacement, "old feedback leaked into replacement media");
            }
        });
    }
    private static void Assert(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
