namespace FusionPlay.Core;

/// <summary>Converts a captured, source-reported timeline into a bounded request for that exact track.</summary>
public static class Seeking
{
    public static bool CanSeek(ReceiverSnapshot snapshot) =>
        snapshot is { ControlsAvailable: true, Phase: ReceiverPhase.Playing or ReceiverPhase.Paused, DurationMs: > 0, PositionMs: not null }
        && snapshot.TrackId != null && snapshot.Title != null
        && (!string.IsNullOrWhiteSpace(snapshot.TrackId) || !string.IsNullOrWhiteSpace(snapshot.Title));

    public static SeekRequest? AtFraction(ReceiverSnapshot snapshot, double fraction)
    {
        if (!CanSeek(snapshot) || !double.IsFinite(fraction)) return null;
        ulong duration = snapshot.DurationMs!.Value;
        // Converting ulong.MaxValue through double rounds it to 2^64. Preserve exact endpoints
        // and use decimal for intermediate multiplication and nearest-millisecond rounding.
        ulong position = fraction <= 0 ? 0 : fraction >= 1 ? duration
            : (ulong)decimal.Round(duration * (decimal)fraction, 0, MidpointRounding.AwayFromZero);
        return new SeekRequest(Math.Min(position, duration), snapshot.TrackId, snapshot.Title);
    }

    public static SeekRequest? AtPoint(ReceiverSnapshot snapshot, double x, double width)
    {
        if (!double.IsFinite(x) || !double.IsFinite(width) || width <= 0) return null;
        // Bound coordinates before division, which can overflow for a tiny positive width.
        return AtFraction(snapshot, x <= 0 ? 0 : x >= width ? 1 : x / width);
    }

    public static bool MatchesCurrent(ReceiverSnapshot snapshot, SeekRequest request) =>
        request != null && request.ExpectedTrackId != null && request.ExpectedTitle != null
        && CanSeek(snapshot) && request.PositionMs <= snapshot.DurationMs!.Value
        && (request.ExpectedTrackId.Length > 0
            ? string.Equals(snapshot.TrackId, request.ExpectedTrackId, StringComparison.Ordinal)
            : snapshot.TrackId.Length == 0 && string.Equals(snapshot.Title, request.ExpectedTitle, StringComparison.Ordinal));

    /// <summary>A stable sender ID wins over changing per-line lyric captions.</summary>
    public static bool SameTrack(ReceiverSnapshot left, ReceiverSnapshot right) =>
        left.ControlsAvailable && right.ControlsAvailable
        && (!string.IsNullOrEmpty(left.TrackId) || !string.IsNullOrEmpty(right.TrackId)
            ? !string.IsNullOrEmpty(left.TrackId) && string.Equals(left.TrackId, right.TrackId, StringComparison.Ordinal)
            : string.Equals(left.Title, right.Title, StringComparison.Ordinal));
}
