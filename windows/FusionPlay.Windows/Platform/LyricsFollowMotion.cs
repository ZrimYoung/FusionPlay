using System.Diagnostics;

namespace FusionPlay.Windows.Platform;

/// <summary>A follow scroll and its bounded, viewport-ranked row lag.</summary>
internal sealed class LyricsFollowMotion
{
    private const int RankSteps = 32;
    private const double MaxLag = 36;
    private readonly long started;
    private readonly double startOffset, targetOffset, duration, span, direction;
    private readonly float[]? carried;

    internal LyricsFollowMotion(long started, double startOffset, double targetOffset, double durationMs, double spanMs, LyricsFollowMotion? previous)
    {
        this.started = started;
        this.startOffset = startOffset;
        this.targetOffset = targetOffset;
        duration = Math.Clamp(durationMs, 100, 1500);
        span = Math.Clamp(spanMs, 0, 1000);
        direction = Math.Sign(targetOffset - startOffset);
        if (previous == null || previous.IsComplete(started)) return;
        // Carry only the current offsets, never a chain of obsolete waves.
        carried = new float[RankSteps + 1];
        for (int rank = 0; rank <= RankSteps; rank++) carried[rank] = previous.RowOffset(started, rank);
    }

    internal bool IsComplete(long now) => Elapsed(now) >= duration + span;

    internal double ScrollOffset(long now) => startOffset + (targetOffset - startOffset) * Ease(Elapsed(now));

    internal float RowOffset(long now, int rank)
    {
        double time = Elapsed(now);
        double progress = Ease(time);
        double delay = span * rank / RankSteps;
        double lag = direction * MaxLag * (progress - Ease(time - delay));
        double residual = (carried?[rank] ?? 0) * (1 - progress);
        double sharedDirection = Math.Max(0, lag >= 0 ? residual : -residual);
        return (float)(residual + lag * (1 - sharedDirection / MaxLag));
    }

    internal static int Rank(double middle, double viewportHeight)
        => (int)Math.Round(Math.Clamp(middle / viewportHeight, 0, 1) * RankSteps);

    private double Elapsed(long now) => Stopwatch.GetElapsedTime(started, now).TotalMilliseconds;

    private double Ease(double elapsed)
    {
        double t = Math.Clamp(elapsed / duration, 0, 1);
        return t * t * (3 - 2 * t);
    }
}
