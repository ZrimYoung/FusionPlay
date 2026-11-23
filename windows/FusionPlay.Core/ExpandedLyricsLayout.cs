namespace FusionPlay.Core;

public readonly record struct ExpandedLyricsLayout(
    double ContentWidth, double HorizontalInset, double VerticalInset, double ColumnGap, double ArtworkColumn, double ArtworkSide)
{
    public const double MaximumFullScreenContentWidth = 1440;

    public static ExpandedLyricsLayout ForWindow(double width, double height, bool fullScreen, double reservedHeight)
    {
        double horizontal = Math.Max(24, width * .065);
        double vertical = Math.Clamp(height * .055, 20, 64);
        double contentWidth = Math.Max(1, width - horizontal * 2);
        if (fullScreen) contentWidth = Math.Min(contentWidth, MaximumFullScreenContentWidth);

        double gap = fullScreen ? Math.Clamp(contentWidth * .065, 28, 96) : width * .045;
        double growth = Math.Clamp((width - 900) / 800, 0, 1);
        double artworkRatio = fullScreen ? .44 - .06 * growth * growth * (3 - 2 * growth) : .42;
        double artworkColumn = Math.Max(1, (contentWidth - gap) * artworkRatio);
        double artworkSide = Math.Max(60, Math.Min(artworkColumn, height - vertical * 2 - reservedHeight));
        return new(contentWidth, horizontal, vertical, gap, artworkColumn, artworkSide);
    }
}
