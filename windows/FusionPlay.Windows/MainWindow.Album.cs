using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;

namespace FusionPlay.Windows;

public sealed partial class MainWindow
{
    private bool albumLayoutActive;
    private (LyricsLine? Line, bool HasLyrics, bool Loading, string Language)? albumSummary;
    private (bool Artwork, bool TrackInfo)? albumHeaderOptions;
    private string? albumHeaderLanguage;

    private void ApplyAlbumLayout(bool active, double width, double height, bool showProgress, bool showTransport)
    {
        if (albumLayoutActive != active)
        {
            albumLayoutActive = active;
            // Move the existing cover and controls only when switching layout.
            // Paging and resizing leave the playback tree and glyph caches in place.
            var cover = MiniCoverPanel.Children;
            if (active)
            {
                cover.Remove(MiniArtworkLayer);
                cover.Remove(MiniControlsTransitionLayer);
                MiniAlbumArtworkFrame.Child = MiniArtworkLayer;
                MiniAlbumColumn.Children.Add(MiniControlsTransitionLayer);
            }
            else
            {
                MiniAlbumColumn.Children.Remove(MiniControlsTransitionLayer);
                MiniAlbumArtworkFrame.Child = null;
                cover.Insert(0, MiniArtworkLayer);
                cover.Insert(2, MiniControlsTransitionLayer);
                AlbumLyricsHeader.Visibility = Visibility.Collapsed;
                AlbumLyricsArtwork.Source = null;
                albumHeaderOptions = null;
                if (MiniAlbumScroll.VerticalOffset > 0) MiniAlbumScroll.ChangeView(null, 0, null, disableAnimation: true);
            }
            MiniCoverEffects.Visibility = active ? Visibility.Collapsed : Visibility.Visible;
            AlbumLyricSummary.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
            MiniControlsTransitionLayer.VerticalAlignment = active ? VerticalAlignment.Stretch : VerticalAlignment.Bottom;
            MiniControls.VerticalAlignment = active ? VerticalAlignment.Stretch : VerticalAlignment.Bottom;
            MiniControls.Padding = active ? new Thickness(0) : new Thickness(18, 20, 18, 14);
            MiniControls.Spacing = active ? 8 : 6;
        }

        var playbackVisibility = active && !idle ? Visibility.Visible : Visibility.Collapsed;
        if (MiniAlbumScroll.Visibility != playbackVisibility) MiniAlbumScroll.Visibility = playbackVisibility;
        if (!active || idle) return;
        double inset = width < 320 ? 24 : Math.Min(48, 32 + (width - 320) * .04);
        double maximum = Math.Max(1, width - 2 * inset);
        double metadata = model.Preferences.Value.WrapTrackMetadata ? 88 : 52;
        double reserved = CompactLyricsPager.HeaderHeight + 24 + 16 + metadata + 48
            + (showProgress ? 48 : 0) + (showTransport ? 52 : 0);
        // Short windows scroll once the minimum readable cover will no longer fit.
        double side = Math.Clamp(height - reserved, Math.Min(maximum, 180), maximum);
        if (MiniAlbumColumn.Width == side) return;
        MiniAlbumColumn.Width = MiniAlbumArtworkFrame.Height = side;
    }

    private void UpdateAlbumPages(UiPreferences preferences)
    {
        if (!albumLayoutActive || !compact || idle) return;

        var options = (Artwork: preferences.AlbumLyricsArtwork, TrackInfo: preferences.AlbumLyricsTrackInfo);
        if (albumHeaderOptions != options)
        {
            albumHeaderOptions = options;
            AlbumLyricsHeader.Visibility = options.Artwork || options.TrackInfo ? Visibility.Visible : Visibility.Collapsed;
            AlbumLyricsArtworkFrame.Visibility = options.Artwork ? Visibility.Visible : Visibility.Collapsed;
            AlbumLyricsMetadata.Visibility = options.TrackInfo ? Visibility.Visible : Visibility.Collapsed;
            if (!options.Artwork) AlbumLyricsArtwork.Source = null;
        }
        if (albumHeaderLanguage != L.Language)
        {
            albumHeaderLanguage = L.Language;
            Label(AlbumLyricsHeader, L.Text("返回播放页", "Return to player"));
        }
        if (miniPager.ShowingLyrics)
        {
            var artwork = options.Artwork ? model.Artwork : null;
            if (!ReferenceEquals(AlbumLyricsArtwork.Source, artwork)) AlbumLyricsArtwork.Source = artwork;
            if (options.TrackInfo)
            {
                if (AlbumLyricsTitle.Text != MiniTitle.Text) AlbumLyricsTitle.Text = MiniTitle.Text;
                if (AlbumLyricsArtist.Text != MiniArtist.Text) AlbumLyricsArtist.Text = MiniArtist.Text;
            }
            return;
        }

        var document = model.Lyrics;
        int index = document.IsTimed ? document.ActiveLineIndex(model.LyricsPositionMs) : 0;
        var line = index >= 0 && index < document.Lines.Count ? document.Lines[index] : null;
        var summary = (Line: line, HasLyrics: document.HasLyrics, Loading: model.LyricsLoading, Language: L.Language);
        if (albumSummary == summary) return;
        albumSummary = summary;
        var caption = summary.Loading ? L.Text("正在载入歌词…", "Loading lyrics…")
            : summary.Line == null ? summary.HasLyrics ? L.Text("查看歌词", "View lyrics") : L.Text("暂无歌词", "No lyrics available")
            : summary.Line.Text.Length == 0 ? "•••" : summary.Line.Text;
        AlbumLyricSummaryText.Text = caption;
        Label(AlbumLyricSummary, L.Text("查看歌词", "View lyrics"));
        AutomationProperties.SetItemStatus(AlbumLyricSummary, caption);
    }

    private void AlbumLyricSummary_Click(object sender, RoutedEventArgs args) => miniPager.Navigate(true);
    private void AlbumLyricsHeader_Click(object sender, RoutedEventArgs args) => miniPager.Navigate(false);
}
