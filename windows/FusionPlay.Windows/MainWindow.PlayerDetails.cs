using FusionPlay.Windows.Platform;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.UI.ViewManagement;

namespace FusionPlay.Windows;

public sealed partial class MainWindow
{
    private double metadataTextScale = 1;

    private void Root_PointerMoved(object sender, PointerRoutedEventArgs args)
    {
        if (args.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse)
            squareSizing.RefreshCoverResizeCue();
    }

    private void CoverResizeCueChanged(CoverResizeCue cue)
    {
        if (closed) return;
        float opacity = cue switch { CoverResizeCue.Hover => .52f, CoverResizeCue.Dragging => .84f, _ => 0 };
        if (RootGrid.IsLoaded)
            AnimateVisibility(CoverResizeHint, opacity > 0, .12, 0, opacity);
        else Fade(CoverResizeHint, 0, opacity, 0);
    }

    private void UpdateTrackTitleLineLimits(bool wraps, double width, double height, bool album)
    {
        // Scale the spare-height allowance with accessibility text size. The
        // cover layout uses its square artwork height, even above stacked lyrics.
        double compactSpace = album ? height : Math.Min(width, height);
        int compactLimit = !wraps ? 1 : compactSpace >= 345 + 80 * (metadataTextScale - 1) ? 3 : 2;
        int wideLimit = !wraps ? 1 : height >= 400 + 110 * (metadataTextScale - 1) ? 3 : 2;
        if (MiniTitle.MaxLines != compactLimit) MiniTitle.MaxLines = compactLimit;
        if (TitleText.MaxLines != wideLimit) TitleText.MaxLines = wideLimit;
    }

    private void PlayerTextScaleChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (closed) return;
        double scale = sender.TextScaleFactor;
        if (metadataTextScale == scale) return;
        metadataTextScale = scale;
        appliedLayout = null;
        ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
    });

    private void PlayerMenu_Opening(object sender, object args)
    {
        CopyTrackTitleMenuItem.Text = L.Text("复制歌名", "Copy title");
        CopyTrackInfoMenuItem.Text = L.Text("复制曲目信息", "Copy track information");
        CopyTrackTitleMenuItem.IsEnabled = TrackClipboardText(titleOnly: true) != null;
        CopyTrackInfoMenuItem.IsEnabled = TrackClipboardText(titleOnly: false) != null;
    }

    private void CopyTrackTitle_Click(object sender, RoutedEventArgs args) => CopyTrackMetadata(titleOnly: true);
    private void CopyTrackInfo_Click(object sender, RoutedEventArgs args) => CopyTrackMetadata(titleOnly: false);

    private string? TrackClipboardText(bool titleOnly)
    {
        if (!model.HasCurrentTrack) return null;
        var track = model.DisplayMetadata;
        if (titleOnly) return string.IsNullOrWhiteSpace(track.Title) ? null : track.Title;
        var text = string.Join(" · ", new[] { track.Title, track.Artist, track.Album }.Where(value => !string.IsNullOrWhiteSpace(value)));
        return text.Length == 0 ? null : text;
    }

    private bool CopyTrackMetadata(bool titleOnly)
    {
        if (closed || TrackClipboardText(titleOnly) is not { } text) return false;
        try
        {
            var data = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
            data.SetText(text);
            Clipboard.SetContent(data);
            Clipboard.Flush();
            return true;
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            model.Store.EventDiagnostic("copy_track_information_failed");
            return false;
        }
    }
}
