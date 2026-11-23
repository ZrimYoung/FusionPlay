namespace FusionPlay.Windows.Platform;

/// <summary>Geometry only. No source text, device state, timers, or persistence.</summary>
internal static class LyricsViewport
{
    internal static bool IntersectsViewport(double y, double height, double viewportHeight, double bleed)
        => double.IsFinite(y) && double.IsFinite(height) && double.IsFinite(viewportHeight) && height > 0 && viewportHeight > 0
            && y < viewportHeight + bleed && y + height > -bleed;
    internal static double EdgeBlur(double middleY, double height, bool compact, bool enabled)
    {
        if (!enabled || !double.IsFinite(middleY) || !double.IsFinite(height) || height <= 0) return 0;
        static double Smooth(double amount) { double t = Math.Clamp(amount, 0, 1); return t * t * (3 - 2 * t); }
        double top = Smooth(1 - middleY / Math.Max(12, height * .30));
        double bottom = Smooth(1 - (height - middleY) / Math.Max(12, height * .45));
        return Math.Max((compact ? 2.5 : 4) * top, (compact ? 8 : 12) * bottom);
    }
    internal static double FollowOffset(double currentOffset, double rowY, double rowHeight, double viewportHeight, double maximumOffset)
    {
        if (!double.IsFinite(currentOffset) || !double.IsFinite(rowY) || !double.IsFinite(rowHeight) || !double.IsFinite(viewportHeight) || !double.IsFinite(maximumOffset)) return 0;
        double target = currentOffset + rowY - .32 * (viewportHeight - rowHeight);
        return double.IsFinite(target) ? Math.Clamp(target, 0, Math.Max(0, maximumOffset)) : target > 0 ? Math.Max(0, maximumOffset) : 0;
    }
    internal static double AnchorOffset(double currentOffset, double rowY, double rememberedY, double maximumOffset)
    {
        if (!double.IsFinite(currentOffset) || !double.IsFinite(rowY) || !double.IsFinite(rememberedY) || !double.IsFinite(maximumOffset)) return 0;
        double target = currentOffset + rowY - rememberedY;
        return Math.Clamp(target, 0, Math.Max(0, maximumOffset));
    }
    internal static double LineOpacity(bool timed, int index, int active, bool highContrast)
    {
        if (!timed) return .88;
        if (index == active) return 1;
        if (highContrast) return .74;
        if (active < 0) return index == 0 ? .72 : .4;
        return Math.Abs(index - active) <= 1 ? .56 : .3;
    }
}
