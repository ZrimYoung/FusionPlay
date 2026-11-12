using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace FusionPlay.Windows;

internal sealed class TrayWindow : Window
{
    private readonly ReceiverController model;
    private readonly Image cover = new() { Width = 60, Height = 60, Stretch = Stretch.UniformToFill };
    private readonly TextBlock title = new() { FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, MaxLines = 2, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock artist = new() { Opacity = 0.65, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock status = new() { FontSize = 12, Opacity = 0.65 };
    private readonly Button play = new(), previous = new(), next = new();
    private readonly Button artworkButton = new(), trackButton = new(), settingsButton = new(), quitButton = new();
    private readonly Slider volume = new() { Minimum = 0, Maximum = 100, Value = 50, StepFrequency = 1, Height = 24 };
    private bool rendering, visible;
    public TrayWindow(ReceiverController controller, Action showMiniPlayer, Action showSettings, Action quit)
    {
        model = controller;
        var root = new StackPanel { Padding = new Thickness(18), Spacing = 8, Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"] };
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
        Setup(previous, "\uE892", () => _ = model.ControlAsync(PlaybackCommand.Previous));
        Setup(play, "\uE768", () => _ = model.TogglePlaybackAsync());
        Setup(next, "\uE893", () => _ = model.ControlAsync(PlaybackCommand.Next));
        controls.Children.Add(previous); controls.Children.Add(play); controls.Children.Add(next); right.Children.Add(controls);
        top.Children.Add(right); root.Children.Add(top); root.Children.Add(volume); root.Children.Add(status);
        MainWindow.AttachVolume(volume, model);
        volume.ValueChanged += (_, args) => { if (!rendering) model.EditVolume(args.NewValue); };
        var footer = new Grid();
        Setup(settingsButton, "\uE713", showSettings); Setup(quitButton, "\uE8BB", quit);
        settingsButton.HorizontalAlignment = HorizontalAlignment.Left; quitButton.HorizontalAlignment = HorizontalAlignment.Right;
        footer.Children.Add(settingsButton); footer.Children.Add(quitButton); root.Children.Add(footer);
        foreach (var b in new[] { artworkButton, trackButton }) { b.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); b.BorderThickness = new Thickness(0); }
        Content = root; WindowSizing.Apply(this, 340, 240); AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter presenter) { presenter.SetBorderAndTitleBar(true, false); presenter.IsResizable = false; presenter.IsMaximizable = false; presenter.IsMinimizable = false; }
        Activated += (_, args) => { if (args.WindowActivationState == WindowActivationState.Deactivated) HidePanel(); };
        model.Changed += Render; Closed += (_, _) => model.Changed -= Render; Render();
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
        rendering = true; var state = model.State; Title = "FusionPlay · " + L.Text("接收面板");
        cover.Source = model.Artwork;
        status.Text = L.Text(model.Busy ? "正在处理…" : state.PhaseLabel);
        title.Text = state.Title.Length > 0 ? state.Title : L.Text("等待音乐");
        artist.Text = string.Join(" · ", new[] { state.Artist, state.Album }.Where(x => x.Length > 0));
        if (artist.Text.Length == 0) artist.Text = model.Settings.Name;
        previous.IsEnabled = play.IsEnabled = next.IsEnabled = model.CanControl;
        ((FontIcon)play.Content).Glyph = state.Phase == ReceiverPhase.Playing ? "\uE769" : "\uE768";
        foreach (var b in new[] { artworkButton, trackButton }) Label(b, "迷你播放器");
        Label(previous, "上一曲"); Label(play, state.Phase == ReceiverPhase.Playing ? "暂停" : "播放"); Label(next, "下一曲");
        Label(settingsButton, "设置"); Label(quitButton, "退出"); Label(volume, "接收音量");
        volume.IsEnabled = model.Initialized; volume.Value = model.Volume; rendering = false;
    }
    public void Toggle()
    {
        if (visible) { HidePanel(); return; }
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        AppWindow.Move(new PointInt32(work.X + work.Width - AppWindow.Size.Width - 16, work.Y + work.Height - AppWindow.Size.Height - 12));
        visible = true; Activate();
    }
    public void HidePanel() { visible = false; AppWindow.Hide(); }
}
