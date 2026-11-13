using System.Diagnostics;

namespace FusionPlay.Core;

/// <summary>Authoritative source observations and bounded UI feedback are kept separate.</summary>
public sealed class PlaybackTimeline
{
    public static readonly TimeSpan FeedbackTimeout = TimeSpan.FromSeconds(5);
    private sealed record Pending(ulong Token, SeekRequest Request, ulong BaselinePosition, bool WasPlaying, TimeSpan Started);
    private readonly Func<TimeSpan> now;
    private Pending? pending;
    private ulong sequence;
    public ReceiverSnapshot Source { get; private set; } = new();
    public ulong Revision { get; private set; }
    public bool IsPending => pending != null;

    public PlaybackTimeline(Func<TimeSpan>? clock = null)
    {
        var stopwatch = Stopwatch.StartNew();
        now = clock ?? (() => stopwatch.Elapsed);
    }

    public ulong? DisplayPositionMs => pending is { } value
        && now() - value.Started < FeedbackTimeout && Seeking.MatchesCurrent(Source, value.Request)
        ? value.Request.PositionMs : Source.PositionMs;

    public bool Apply(PollResult observation)
    {
        // A delayed UI continuation must never replace a more recent native observation.
        if (observation.Revision < Revision) return false;
        Revision = observation.Revision;
        if (observation.Snapshot is not { } snapshot) return false;
        Source = snapshot;
        if (pending is { } value)
        {
            if (!Seeking.MatchesCurrent(snapshot, value.Request) || now() - value.Started >= FeedbackTimeout)
                pending = null;
            else if (snapshot.PositionMs is { } position && ConfirmsJump(value, position))
                pending = null;
        }
        return true;
    }

    public ulong Begin(SeekRequest request)
    {
        if (!Seeking.MatchesCurrent(Source, request)) return 0;
        pending = new(++sequence, request, Source.PositionMs!.Value, Source.Phase == ReceiverPhase.Playing, now());
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

    public bool Expire(ulong token)
    {
        if (pending?.Token != token || now() - pending.Started < FeedbackTimeout) return false;
        pending = null; return true;
    }

    private bool ConfirmsJump(Pending value, ulong position)
    {
        ulong target = value.Request.PositionMs, baseline = value.BaselinePosition;
        if (Distance(position, target) > 2_000) return false;
        if (target == baseline) return true;
        if (position == baseline) return false;
        if (target < baseline) return position <= target || baseline - Math.Min(baseline, position) > 250;
        // A normal tick just before a nearby forward target is not a seek
        // acknowledgement. Accept crossing the target or a jump beyond ordinary
        // elapsed playback (with a small reporting-jitter allowance).
        ulong advance = value.WasPlaying ? (ulong)Math.Clamp((now() - value.Started).TotalMilliseconds, 0, FeedbackTimeout.TotalMilliseconds) : 0;
        ulong allowance = advance + 250;
        ulong naturalCeiling = baseline > ulong.MaxValue - allowance ? ulong.MaxValue : baseline + allowance;
        return position >= target || position > naturalCeiling;
    }

    private static ulong Distance(ulong left, ulong right) => left >= right ? left - right : right - left;
}
