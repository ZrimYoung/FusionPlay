using System.Diagnostics;

namespace FusionPlay.Core;

/// <summary>Authoritative source observations and bounded UI feedback are kept separate.</summary>
public sealed class PlaybackTimeline
{
    public static readonly TimeSpan FeedbackTimeout = TimeSpan.FromSeconds(5);
    private const ulong BackwardJitterMs = 500;
    private sealed record Pending(ulong Token, SeekRequest Request, ulong BaselinePosition, bool WasPlaying, TimeSpan Started);
    private readonly Func<TimeSpan> now;
    private Pending? pending;
    private ulong sequence;
    private ulong? lastReportedPosition;
    private ulong? positionAnchor;
    private ulong positionFloor;
    private TimeSpan anchoredAt;
    public ReceiverSnapshot Source { get; private set; } = new();
    public ulong Revision { get; private set; }
    public bool IsPending => pending != null;

    public PlaybackTimeline(Func<TimeSpan>? clock = null)
    {
        var stopwatch = Stopwatch.StartNew();
        now = clock ?? (() => stopwatch.Elapsed);
    }

    public ulong? DisplayPositionMs
    {
        get
        {
            var time = now();
            return SeekFeedback(time) ?? PositionAt(time);
        }
    }

    public bool IsAdvancing
    {
        get
        {
            var time = now();
            return Source.Phase == ReceiverPhase.Playing && SeekFeedback(time) == null
                && PositionAt(time) is { } position && position < PositionLimit;
        }
    }

    public bool Apply(PollResult observation)
    {
        // A delayed UI continuation must never replace a more recent native observation.
        if (observation.Revision < Revision) return false;
        Revision = observation.Revision;
        if (observation.Snapshot is not { } snapshot) return false;
        var time = now();
        bool sameTrack = Source.HasMedia && snapshot.HasMedia && Seeking.SameTrack(Source, snapshot);
        var projected = sameTrack ? PositionAt(time) : null;
        bool wasPlaying = Source.Phase == ReceiverPhase.Playing;
        var previousReport = sameTrack ? lastReportedPosition : null;
        var freshPosition = snapshot.PositionMs != previousReport ? snapshot.PositionMs : null;
        bool confirmedSeek = false;
        if (pending is { } value)
        {
            bool valid = time - value.Started < FeedbackTimeout && Seeking.MatchesCurrent(snapshot, value.Request);
            confirmedSeek = valid && sameTrack && freshPosition is { } position && ConfirmsJump(value, position, time);
            if (!valid || confirmedSeek)
                pending = null;
        }
        Source = snapshot;
        if (!sameTrack) ResetPosition();
        if (!snapshot.HasMedia) return true;

        bool playing = snapshot.Phase == ReceiverPhase.Playing;
        if (freshPosition is { } sample)
        {
            lastReportedPosition = sample;
            // A slightly late forward report can catch up without reversing the lyric highlight.
            bool lateReport = !confirmedSeek && wasPlaying && playing && previousReport is { } previous && sample > previous
                && projected is { } estimate && estimate > sample && estimate - sample <= BackwardJitterMs;
            Anchor(sample, time, lateReport ? projected!.Value : 0);
        }
        else if (wasPlaying != playing && projected is { } position)
        {
            // A play/pause packet can arrive without a new position sample.
            Anchor(position, time);
        }
        return true;
    }

    public ulong Begin(SeekRequest request)
    {
        if (!Seeking.MatchesCurrent(Source, request)) return 0;
        var time = now();
        pending = new(++sequence, request, PositionAt(time) ?? Source.PositionMs!.Value, Source.Phase == ReceiverPhase.Playing, time);
        return sequence;
    }

    public void Complete(ulong token, bool dispatched)
    {
        if (pending?.Token == token && !dispatched) pending = null;
    }

    public bool Cancel(ulong token)
    {
        if (pending?.Token != token) return false;
        pending = null; return true;
    }

    public void Cancel() => pending = null;

    public void ResetPosition()
    {
        lastReportedPosition = null;
        positionAnchor = null;
        positionFloor = 0;
    }

    public bool Expire(ulong token)
    {
        if (pending?.Token != token || now() - pending.Started < FeedbackTimeout) return false;
        pending = null; return true;
    }

    private ulong? SeekFeedback(TimeSpan time) => pending is { } value
        && time - value.Started < FeedbackTimeout && Seeking.MatchesCurrent(Source, value.Request) ? value.Request.PositionMs : null;

    private ulong PositionLimit => Source.DurationMs is > 0 ? Source.DurationMs.Value : ulong.MaxValue;

    private ulong? PositionAt(TimeSpan time)
    {
        if (positionAnchor is not { } position) return null;
        ulong limit = PositionLimit;
        position = Math.Min(position, limit);
        ulong elapsed = Source.Phase == ReceiverPhase.Playing
            ? (ulong)(Math.Max(0, (time - anchoredAt).Ticks) / TimeSpan.TicksPerMillisecond) : 0;
        ulong projected = position + Math.Min(limit - position, elapsed);
        return Math.Max(projected, Math.Min(positionFloor, limit));
    }

    private void Anchor(ulong position, TimeSpan time, ulong floor = 0)
    {
        positionAnchor = position;
        anchoredAt = time;
        positionFloor = floor;
    }

    private static bool ConfirmsJump(Pending value, ulong position, TimeSpan time)
    {
        ulong target = value.Request.PositionMs, baseline = value.BaselinePosition;
        if (Distance(position, target) > 2_000) return false;
        if (target == baseline) return true;
        if (position == baseline) return false;
        if (target < baseline) return position <= target || baseline - Math.Min(baseline, position) > 250;
        // A normal tick just before a nearby forward target is not a seek
        // acknowledgement. Accept crossing the target or a jump beyond ordinary
        // elapsed playback (with a small reporting-jitter allowance).
        ulong advance = value.WasPlaying ? (ulong)Math.Clamp((time - value.Started).TotalMilliseconds, 0, FeedbackTimeout.TotalMilliseconds) : 0;
        ulong allowance = advance + 250;
        ulong naturalCeiling = baseline > ulong.MaxValue - allowance ? ulong.MaxValue : baseline + allowance;
        return position >= target || position > naturalCeiling;
    }

    private static ulong Distance(ulong left, ulong right) => left >= right ? left - right : right - left;
}
