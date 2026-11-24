namespace FusionPlay.Windows;

public sealed partial class MainWindow
{
    private void HandoffLyricsReadingPosition(bool nextCompact)
    {
        if (compact == nextCompact || idle) return;
        var outgoing = compact ? miniLyrics : expandedLyrics;
        var incoming = nextCompact ? miniLyrics : expandedLyrics;
        if (outgoing.CaptureReadingPosition() is { } position) incoming.ReceiveReadingPosition(position);
    }
}
