using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Runtime.InteropServices;
using Windows.Foundation;
using Windows.Graphics;

namespace FusionPlay.Windows;

internal sealed class TrayWindow : Window
{
    private readonly ReceiverController model;
    private const double PanelWidth = 340;
    private readonly StackPanel root;
    private readonly Image cover = new() { Width = 60, Height = 60, Stretch = Stretch.UniformToFill };
    private readonly TextBlock title = new() { FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, MaxLines = 2, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock artist = new() { Opacity = 0.65, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock status = new() { FontSize = 12, Opacity = 0.65 };
    private readonly Button play = new(), previous = new(), next = new();
    private readonly Button artworkButton = new(), trackButton = new(), settingsButton = new(), quitButton = new();
    private readonly Slider volume = new() { Minimum = 0, Maximum = 100, Value = 50, StepFrequency = 1, MinHeight = 44, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center };
    private readonly FontIcon speaker = new() { Glyph = "\uE767", FontSize = 14, Width = 18, VerticalAlignment = VerticalAlignment.Center };
    private bool rendering, visible, closed, fitQueued;
    private double contentHeight;
    private readonly Func<RectInt32?> anchor;
    private long closedByTrayClick = long.MinValue / 2;
    public TrayWindow(ReceiverController controller, Action showMiniPlayer, Action showSettings, Action quit, Func<RectInt32?> trayAnchor)
    {
        model = controller; anchor = trayAnchor;
        root = new StackPanel { Padding = new Thickness(16, 12, 16, 10), Spacing = 6 };
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
        var top = new Grid { ColumnSpacing = 12 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var art = new Grid();
        art.Children.Add(new FontIcon { Glyph = "\uEC4F", Opacity = 0.2, FontSize = 28 }); art.Children.Add(cover);
        artworkButton.Content = art; artworkButton.Padding = new Thickness(0); artworkButton.CornerRadius = new CornerRadius(8);
        artworkButton.Click += (_, _) => showMiniPlayer();
        top.Children.Add(artworkButton);
        var right = new StackPanel { Spacing = 4 }; Grid.SetColumn(right, 1);
        var info = new StackPanel { Spacing = 2 }; info.Children.Add(title); info.Children.Add(artist);
        trackButton.Content = info; trackButton.HorizontalContentAlignment = HorizontalAlignment.Left;
        trackButton.HorizontalAlignment = HorizontalAlignment.Stretch; trackButton.Padding = new Thickness(0);
        trackButton.Click += (_, _) => showMiniPlayer(); right.Children.Add(trackButton);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        Setup(previous, "", () => _ = model.ControlAsync(PlaybackCommand.Previous)); previous.Content = PlaybackIcons.Create(PlaybackCommand.Previous);
        Setup(play, "", () => _ = model.TogglePlaybackAsync()); play.Content = PlaybackIcons.Create(PlaybackCommand.Play);
        Setup(next, "", () => _ = model.ControlAsync(PlaybackCommand.Next)); next.Content = PlaybackIcons.Create(PlaybackCommand.Next);
        controls.Children.Add(previous); controls.Children.Add(play); controls.Children.Add(next); right.Children.Add(controls);
        top.Children.Add(right); root.Children.Add(top);
        var volumeRow = new Grid { ColumnSpacing = 8, MinHeight = 44 };
        volumeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        volumeRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        volumeRow.Children.Add(speaker); Grid.SetColumn(volume, 1); volumeRow.Children.Add(volume);
        root.Children.Add(volumeRow);
        MainWindow.AttachVolume(volume, model);
        volume.ValueChanged += (_, args) => { if (!rendering) model.EditVolume(args.NewValue); };
        var footer = new Grid { ColumnSpacing = 8 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Setup(settingsButton, "\uE713", showSettings); Setup(quitButton, "\uE7E8", quit);
        foreach (var button in new[] { settingsButton, quitButton })
        {
            button.Width = button.Height = 28; button.MinWidth = button.MinHeight = 0; button.Padding = new Thickness(0);
            button.HorizontalContentAlignment = HorizontalAlignment.Center; button.VerticalContentAlignment = VerticalAlignment.Center;
            ((FontIcon)button.Content).FontSize = 14;
        }
        status.VerticalAlignment = VerticalAlignment.Center; status.HorizontalAlignment = HorizontalAlignment.Center;
        status.MaxLines = 1; status.TextTrimming = TextTrimming.CharacterEllipsis;
        Grid.SetColumn(status, 1); Grid.SetColumn(quitButton, 2);
        footer.Children.Add(settingsButton); footer.Children.Add(status); footer.Children.Add(quitButton); root.Children.Add(footer);
        foreach (var b in new[] { artworkButton, trackButton }) { b.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); b.BorderThickness = new Thickness(0); }
        Content = root; WindowSizing.Apply(this, PanelWidth, 220); AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter presenter) { presenter.SetBorderAndTitleBar(true, false); presenter.IsResizable = false; presenter.IsMaximizable = false; presenter.IsMinimizable = false; presenter.IsAlwaysOnTop = true; }
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != WindowActivationState.Deactivated) return;
            if (visible && anchor() is { } bounds && TrayIcon.Native.GetCursorPos(out var point)
                && point.X >= bounds.X && point.X < bounds.X + bounds.Width && point.Y >= bounds.Y && point.Y < bounds.Y + bounds.Height)
                closedByTrayClick = Environment.TickCount64;
            HidePanel();
        };
        root.Loaded += (_, _) => QueueFit(); root.SizeChanged += (_, _) => QueueFit();
        model.Changed += Render; Closed += (_, _) => { closed = true; model.Changed -= Render; }; Render();
    }
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
        rendering = true; var state = model.State; Title = "FusionPlay · " + L.Text("接收面板");
        cover.Source = model.Artwork;
        string oldTitle = title.Text, oldArtist = artist.Text, oldStatus = status.Text;
        status.Text = L.Text(model.Busy ? "正在处理…" : state.PhaseLabel);
        title.Text = state.Title.Length > 0 ? state.Title : L.Text("等待音乐");
        artist.Text = string.Join(" · ", new[] { state.Artist, state.Album }.Where(x => x.Length > 0));
        if (artist.Text.Length == 0) artist.Text = model.Settings.Name;
        previous.IsEnabled = play.IsEnabled = next.IsEnabled = model.CanControl;
        PlaybackIcons.Update((PathIcon)play.Content, state.Phase == ReceiverPhase.Playing ? PlaybackCommand.Pause : PlaybackCommand.Play);
        foreach (var b in new[] { artworkButton, trackButton }) Label(b, "迷你播放器");
        Label(previous, "上一曲"); Label(play, state.Phase == ReceiverPhase.Playing ? "暂停" : "播放"); Label(next, "下一曲");
        Label(settingsButton, "设置"); Label(quitButton, "退出"); Label(volume, "接收音量"); Label(speaker, "接收音量");
        volume.IsEnabled = model.Initialized; volume.Value = model.Volume; rendering = false;
        if (oldTitle != title.Text || oldArtist != artist.Text || oldStatus != status.Text || contentHeight == 0) QueueFit();
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
    public void HidePanel() { visible = false; if (!closed) AppWindow.Hide(); }
}
