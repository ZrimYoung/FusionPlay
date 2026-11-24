using System.Diagnostics;

namespace FusionPlay.Windows.Platform;

/// <summary>A follow scroll and its bounded, viewport-ranked row lag.</summary>
internal sealed class LyricsFollowMotion
{
    private const int RankSteps = 32;
    internal const double MaxLag = 36;
    internal const int MaximumTrackedRows = 128;
    private readonly long started;
    private readonly double startOffset, targetOffset, duration, span, direction;
    private readonly Dictionary<int, RowMotion> rows = [];
    private readonly record struct RowMotion(int Rank, float CarriedOffset);

    internal LyricsFollowMotion(long started, double startOffset, double targetOffset, double durationMs, double spanMs)
    {
        this.started = started;
        this.startOffset = startOffset;
        this.targetOffset = targetOffset;
        duration = Math.Clamp(durationMs, 100, 1500);
        span = Math.Clamp(spanMs, 0, 1000);
        direction = Math.Sign(targetOffset - startOffset);
    }

    internal bool IsComplete(long now) => Elapsed(now) >= duration + span;
    internal double Duration => duration;
    internal double TotalDuration => duration + span;
    internal double TargetOffset => targetOffset;

    internal double ScrollOffset(long now) => startOffset + (targetOffset - startOffset) * Ease(Elapsed(now));

    internal void CaptureRank(int index, double middle, double viewportHeight, float presentedOffset) =>
        TryGetRow(index, middle, viewportHeight, presentedOffset, out _);
    internal double RowDelay(int index) => rows.TryGetValue(index, out var row) ? span * row.Rank / RankSteps : 0;

    internal float RowOffset(long now, int index, double middle, double viewportHeight)
    {
        if (!TryGetRow(index, middle, viewportHeight, 0, out var row)) return 0;
        double time = Elapsed(now);
        double progress = Ease(time);
        double delay = span * row.Rank / RankSteps;
        double lag = direction * MaxLag * (progress - Ease(time - delay));
        double residual = row.CarriedOffset * (1 - progress);
        double sharedDirection = Math.Max(0, lag >= 0 ? residual : -residual);
        return (float)(residual + lag * (1 - sharedDirection / MaxLag));
    }

    private bool TryGetRow(int index, double middle, double viewportHeight, float presentedOffset, out RowMotion row)
    {
        if (rows.TryGetValue(index, out row)) return true;
        if (rows.Count == MaximumTrackedRows) return false;
        // The document's index identifies the row even when its container is recycled.
        // A newly visible row joins using its position on the first visible frame.
        int rank = (int)Math.Round(Math.Clamp(middle / viewportHeight, 0, 1) * RankSteps);
        row = new(rank, presentedOffset);
        rows.Add(index, row);
        return true;
    }

    private double Elapsed(long now) => Stopwatch.GetElapsedTime(started, now).TotalMilliseconds;

    private double Ease(double elapsed)
    {
        double t = Math.Clamp(elapsed / duration, 0, 1);
        return t * t * (3 - 2 * t);
    }
}
