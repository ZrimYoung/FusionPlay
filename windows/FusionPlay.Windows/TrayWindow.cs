using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using System.Numerics;
using System.Runtime.InteropServices;
using Windows.Foundation;
using Windows.Graphics;

namespace FusionPlay.Windows;

internal sealed class TrayWindow : Window
{
    private readonly ReceiverController model;
    private const double PanelWidth = 340;
    private const double HeaderInset = 4, HeaderGap = 12, VolumeWidth = 104;
    private readonly StackPanel root;
    private readonly StackPanel trackColumn = new() { Name = "TrackColumn", Spacing = 6, VerticalAlignment = VerticalAlignment.Top };
    private readonly Image cover = new() { Name = "AlbumCover", Stretch = Stretch.UniformToFill, IsHitTestVisible = false };
    private readonly PlayerText title = new() { Name = "TrackTitle", FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, MaxLines = 2, TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly PlayerText artist = new() { Name = "TrackArtist", FontSize = 13, Opacity = 0.9, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Button play = new(), previous = new(), next = new();
    private readonly Button artworkButton = new(), trackButton = new(), settingsButton = new(), quitButton = new();
    private readonly MenuVolumeSlider volumeControl = new();
    private Slider volume => volumeControl.Slider;
    private readonly FontIcon speaker = new() { Glyph = "\uE767", FontSize = 14 };
    private readonly ToggleButton volumeButton = new() { Name = "VolumeButton" };
    private readonly Grid volumeViewport = new() { Name = "VolumeViewport", Width = 0, Height = 28, Opacity = 0, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly RectangleGeometry volumeClip = new();
    private readonly CompositionRoundedRectangleGeometry artworkGeometry;
    private readonly CompositionGeometricClip artworkClip;
    private Storyboard? volumeAnimation;
    private bool rendering, visible, closed, fitQueued, volumeExpanded;
    private double contentHeight;
    private readonly Func<RectInt32?> anchor;
    private long closedByTrayClick = long.MinValue / 2;
    public TrayWindow(ReceiverController controller, Action showMiniPlayer, Action showSettings, Action quit, Func<RectInt32?> trayAnchor)
    {
        model = controller; anchor = trayAnchor;
        root = new StackPanel { Name = "TrayRoot", Padding = new Thickness(HeaderInset), Spacing = 10 };
        try
        {
            // The system backdrop supplies solid theme/high-contrast colors whenever acrylic is unavailable.
            SystemBackdrop = new DesktopAcrylicBackdrop();
            root.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
        catch (Exception error) when (error is COMException or NotSupportedException)
        {
            root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        }
        var top = new Grid { ColumnSpacing = HeaderGap };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var art = new Grid();
        art.Children.Add(new FontIcon { Glyph = "\uEC4F", Opacity = 0.2, FontSize = 28 }); art.Children.Add(cover);
        double artworkRadius = OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) ? 4 : 0;
        artworkButton.Name = "ArtworkButton"; artworkButton.Content = art; artworkButton.Padding = new Thickness(0);
        artworkButton.MinWidth = artworkButton.MinHeight = 0;
        artworkButton.Width = artworkButton.Height = 72;
        artworkButton.VerticalAlignment = VerticalAlignment.Top; artworkButton.CornerRadius = new CornerRadius(artworkRadius);
        var artVisual = ElementCompositionPreview.GetElementVisual(art);
        artworkGeometry = artVisual.Compositor.CreateRoundedRectangleGeometry();
        artworkGeometry.CornerRadius = new Vector2((float)artworkRadius);
        artworkGeometry.Size = new Vector2(72);
        artworkClip = artVisual.Compositor.CreateGeometricClip(artworkGeometry); artVisual.Clip = artworkClip;
        artworkButton.Click += (_, _) => showMiniPlayer();
        top.Children.Add(artworkButton);
        Grid.SetColumn(trackColumn, 1);
        var info = new StackPanel { Spacing = 4 }; info.Children.Add(title); info.Children.Add(artist);
        trackButton.Name = "TrackButton"; trackButton.Content = info; trackButton.HorizontalContentAlignment = HorizontalAlignment.Left;
        trackButton.VerticalContentAlignment = VerticalAlignment.Top; trackButton.MinWidth = trackButton.MinHeight = 0;
        trackButton.HorizontalAlignment = HorizontalAlignment.Stretch; trackButton.Padding = new Thickness(0);
        trackButton.Click += (_, _) => showMiniPlayer(); trackColumn.Children.Add(trackButton);
        var controls = new StackPanel { Name = "TransportControls", Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Left };
        Setup(previous, "", () => _ = model.ControlAsync(PlaybackCommand.Previous)); previous.Content = PlaybackIcons.Create(PlaybackCommand.Previous);
        Setup(play, "", () => _ = model.TogglePlaybackAsync()); play.Content = PlaybackIcons.Create(PlaybackCommand.Play);
        Setup(next, "", () => _ = model.ControlAsync(PlaybackCommand.Next)); next.Content = PlaybackIcons.Create(PlaybackCommand.Next);
        previous.Name = "PreviousButton";
        foreach (var button in new[] { previous, play, next })
        {
            button.Width = button.Height = 28; button.MinWidth = button.MinHeight = 0; button.Padding = new Thickness(0);
            button.HorizontalContentAlignment = HorizontalAlignment.Left; button.VerticalContentAlignment = VerticalAlignment.Center;
        }
        controls.Children.Add(previous); controls.Children.Add(play); controls.Children.Add(next); trackColumn.Children.Add(controls);
        top.Children.Add(trackColumn); root.Children.Add(top);
        volume.Name = "VolumeSlider"; volume.IsTabStop = false;
        volumeControl.Visibility = Visibility.Collapsed;
        volumeViewport.Clip = volumeClip; volumeViewport.Children.Add(volumeControl);
        volumeViewport.SizeChanged += (_, _) => volumeClip.Rect = new Rect(0, 0, volumeViewport.ActualWidth, 28);
        MainWindow.AttachVolume(volume, model);
        volume.ValueChanged += (_, args) => { if (!rendering) model.EditVolume(args.NewValue); };
        var footer = new Grid { ColumnSpacing = 8, Margin = new Thickness(8, 0, 8, 4) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Setup(settingsButton, "\uE713", showSettings); Setup(quitButton, "\uE7E8", quit);
        settingsButton.Name = "SettingsButton"; quitButton.Name = "QuitButton";
        volumeButton.Content = speaker; volumeButton.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); volumeButton.BorderThickness = new Thickness(0);
        foreach (var button in new ButtonBase[] { settingsButton, quitButton, volumeButton })
        {
            button.Width = button.Height = 28; button.MinWidth = button.MinHeight = 0; button.Padding = new Thickness(0);
            button.HorizontalContentAlignment = HorizontalAlignment.Center; button.VerticalContentAlignment = VerticalAlignment.Center;
            ((FontIcon)button.Content).FontSize = 14;
        }
        volumeButton.Checked += (_, _) => SetVolumeExpanded(true, Backdrop.AnimationsEnabled);
        volumeButton.Unchecked += (_, _) => SetVolumeExpanded(false, Backdrop.AnimationsEnabled);
        var volumeGroup = new Grid { ColumnSpacing = 8 };
        volumeGroup.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        volumeGroup.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        volumeGroup.Children.Add(volumeButton); Grid.SetColumn(volumeViewport, 1); volumeGroup.Children.Add(volumeViewport);
        Grid.SetColumn(volumeGroup, 1); Grid.SetColumn(quitButton, 3);
        footer.Children.Add(settingsButton); footer.Children.Add(volumeGroup); footer.Children.Add(quitButton); root.Children.Add(footer);
        foreach (var b in new[] { artworkButton, trackButton }) { b.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); b.BorderThickness = new Thickness(0); }
        Content = root; WindowSizing.Apply(this, PanelWidth, 220); AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter presenter) { presenter.SetBorderAndTitleBar(true, false); presenter.IsResizable = false; presenter.IsMaximizable = false; presenter.IsMinimizable = false; presenter.IsAlwaysOnTop = true; }
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            int round = 2; // DWMWCP_ROUND: retain native antialiasing, shadow and acrylic.
            _ = DwmSetWindowAttribute(WinRT.Interop.WindowNative.GetWindowHandle(this), 33, ref round, sizeof(int));
        }
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated) return;
            if (visible && anchor() is { } bounds && TrayIcon.Native.GetCursorPos(out var point)
                && point.X >= bounds.X && point.X < bounds.X + bounds.Width && point.Y >= bounds.Y && point.Y < bounds.Y + bounds.Height)
                closedByTrayClick = Environment.TickCount64;
            HidePanel();
        };
        root.Loaded += (_, _) => { UiTypography.Apply(root, model.Preferences.Value, force: true); QueueFit(); };
        root.SizeChanged += (_, _) => QueueFit(); trackColumn.SizeChanged += (_, _) => QueueFit();
        model.Changed += Render;
        Closed += (_, _) =>
        {
            closed = true; volumeAnimation?.Stop(); model.Changed -= Render;
            artVisual.Clip = null; artworkClip.Dispose(); artworkGeometry.Dispose();
        };
        Render();
    }
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
    private static void Setup(Button button, string glyph, Action action)
    {
        button.Content = new FontIcon { Glyph = glyph, FontSize = 16 };
        button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); button.BorderThickness = new Thickness(0);
        button.Padding = new Thickness(6); button.Click += (_, _) => action();
    }
    private static void Label(DependencyObject element, string label)
    {
        AutomationProperties.SetName(element, L.Text(label)); ToolTipService.SetToolTip(element, L.Text(label));
    }
    private void Render()
    {
        if (closed) return;
        UiTypography.Apply(root, model.Preferences.Value);
        rendering = true; var state = model.State; Title = "FusionPlay · " + L.Text("接收面板");
        cover.Source = model.Artwork;
        string oldTitle = title.Text, oldArtist = artist.Text;
        title.Text = state.Title.Length > 0 ? state.Title : L.Text("等待音乐");
        artist.Text = string.Join(" · ", new[] { state.Artist, state.Album }.Where(x => x.Length > 0));
        if (artist.Text.Length == 0) artist.Text = model.Settings.Name;
        previous.IsEnabled = play.IsEnabled = next.IsEnabled = model.CanControl;
        PlaybackIcons.Update((PathIcon)play.Content, state.Phase == ReceiverPhase.Playing ? PlaybackCommand.Pause : PlaybackCommand.Play);
        foreach (var b in new[] { artworkButton, trackButton }) Label(b, "迷你播放器");
        Label(previous, "上一曲"); Label(play, state.Phase == ReceiverPhase.Playing ? "暂停" : "播放"); Label(next, "下一曲");
        Label(settingsButton, "设置"); Label(quitButton, "退出"); Label(volume, "接收音量"); Label(volumeButton, volumeExpanded ? "收起音量" : "展开音量");
        speaker.Glyph = model.Volume == 0 ? "\uE74F" : "\uE767";
        volume.IsEnabled = model.Initialized; volume.Value = model.Volume; rendering = false;
        if (oldTitle != title.Text || oldArtist != artist.Text || contentHeight == 0) QueueFit();
    }
    private void QueueFit()
    {
        if (closed || fitQueued) return;
        fitQueued = true;
        if (!DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            fitQueued = false;
            if (!closed) FitToContent();
        })) fitQueued = false;
    }
    private void FitToContent()
    {
        if (root.XamlRoot == null) return;
        // Measure the text/transport independently: the album square must follow
        // their natural height, rather than stretching both columns recursively.
        double scale = root.XamlRoot.RasterizationScale;
        double side = artworkButton.Width;
        for (int pass = 0; pass < 6; pass++)
        {
            trackColumn.Measure(new Size(Math.Max(1, PanelWidth - HeaderInset * 2 - HeaderGap - side), double.PositiveInfinity));
            double desired = Math.Round(trackColumn.DesiredSize.Height * scale, MidpointRounding.AwayFromZero) / scale;
            if (!double.IsFinite(desired) || desired <= 0) break;
            if (Math.Abs(desired - side) < 0.1 / scale) break;
            side = desired;
        }
        artworkButton.Width = artworkButton.Height = cover.Width = cover.Height = side;
        artworkGeometry.Size = new Vector2((float)side);
        root.Measure(new Size(PanelWidth, double.PositiveInfinity));
        double height = Math.Ceiling(root.DesiredSize.Height);
        if (!double.IsFinite(height) || height <= 0) return;
        if (Math.Abs(height - contentHeight) > 0.5 || Math.Abs(root.ActualWidth - PanelWidth) > 1 || Math.Abs(root.ActualHeight - height) > 1)
        {
            contentHeight = height;
            WindowSizing.ResizeContent(this, PanelWidth, height);
        }
        if (visible) PositionAtTray();
    }
    internal void RefreshLayout() => FitToContent();
    internal void SetVolumeExpanded(bool expanded, bool animate)
    {
        if (closed) return;
        bool changed = volumeExpanded != expanded; volumeExpanded = expanded;
        if (volumeButton.IsChecked != expanded) volumeButton.IsChecked = expanded;
        if (!changed && animate) return;
        double fromWidth = volumeViewport.Width, fromOpacity = volumeViewport.Opacity;
        volumeAnimation?.Stop(); volumeAnimation = null;
        volumeControl.Visibility = Visibility.Visible;
        volumeViewport.IsHitTestVisible = expanded; volume.IsTabStop = expanded;
        Label(volumeButton, expanded ? "收起音量" : "展开音量");
        if (!animate)
        {
            volumeViewport.Width = expanded ? VolumeWidth : 0; volumeViewport.Opacity = expanded ? 1 : 0;
            volumeControl.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed; return;
        }
        volumeViewport.Width = fromWidth; volumeViewport.Opacity = fromOpacity;
        var storyboard = new Storyboard(); var duration = new Duration(TimeSpan.FromMilliseconds(250));
        var width = new DoubleAnimation { From = fromWidth, To = expanded ? VolumeWidth : 0, Duration = duration, EnableDependentAnimation = true, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } };
        var opacity = new DoubleAnimation { From = fromOpacity, To = expanded ? 1 : 0, Duration = duration, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } };
        Storyboard.SetTarget(width, volumeViewport); Storyboard.SetTargetProperty(width, "Width");
        Storyboard.SetTarget(opacity, volumeViewport); Storyboard.SetTargetProperty(opacity, "Opacity");
        storyboard.Children.Add(width); storyboard.Children.Add(opacity);
        storyboard.Completed += (_, _) =>
        {
            if (closed || !ReferenceEquals(volumeAnimation, storyboard)) return;
            storyboard.Stop(); volumeAnimation = null;
            volumeViewport.Width = volumeExpanded ? VolumeWidth : 0; volumeViewport.Opacity = volumeExpanded ? 1 : 0;
            volumeControl.Visibility = volumeExpanded ? Visibility.Visible : Visibility.Collapsed;
        };
        volumeAnimation = storyboard; storyboard.Begin();
    }
    public void Toggle()
    {
        if (visible) { HidePanel(); return; }
        if (Environment.TickCount64 - closedByTrayClick < 600) { closedByTrayClick = long.MinValue / 2; return; }
        FitToContent(); PositionAtTray();
        visible = true; AppWindow.Show(); TrayIcon.Native.SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)); Activate();
        QueueFit();
    }
    private void PositionAtTray()
    {
        var bounds = anchor();
        var work = bounds is { } icon ? DisplayArea.GetFromPoint(new PointInt32(icon.X, icon.Y), DisplayAreaFallback.Nearest).WorkArea : DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        int x = bounds is { } b ? b.X + b.Width / 2 - AppWindow.Size.Width / 2 : work.X + work.Width - AppWindow.Size.Width - 16;
        int y = bounds is { } a ? a.Y - AppWindow.Size.Height - 8 : work.Y + work.Height - AppWindow.Size.Height - 12;
        if (y < work.Y && bounds is { } top) y = top.Y + top.Height + 8;
        x = Math.Clamp(x, work.X, Math.Max(work.X, work.X + work.Width - AppWindow.Size.Width));
        y = Math.Clamp(y, work.Y, Math.Max(work.Y, work.Y + work.Height - AppWindow.Size.Height));
        AppWindow.Move(new PointInt32(x, y));
    }
    public void HidePanel() { visible = false; SetVolumeExpanded(false, false); if (!closed) AppWindow.Hide(); }
}
