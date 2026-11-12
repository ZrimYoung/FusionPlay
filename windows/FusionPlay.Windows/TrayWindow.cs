using FusionPlay.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using FusionPlay.Windows.Platform;

namespace FusionPlay.Windows;

internal sealed class TrayWindow : Window
{
    private readonly ReceiverController model;
    private readonly TextBlock status = new() { Opacity = 0.65 };
    private readonly TextBlock title = new() { FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, MaxLines = 2, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock artist = new() { Opacity = 0.65, MaxLines = 1, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly Button play = new(), previous = new(), next = new(), receiving = new();
    private readonly Slider volume = new() { Minimum = 0, Maximum = 100, Value = 50, StepFrequency = 1 };
    private bool rendering;
    private bool visible;
    public TrayWindow(ReceiverController controller, Action showPlayer, Action showSettings, Action quit)
    {
        model = controller; Title = "FusionPlay · 接收面板";
        var root = new StackPanel { Padding = new Thickness(22), Spacing = 14, Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"] };
        root.Children.Add(new TextBlock { Text = "FusionPlay", FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        root.Children.Add(status); root.Children.Add(title); root.Children.Add(artist);
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center };
        Setup(previous, "\uE892", "上一曲", () => _ = model.ControlAsync(PlaybackCommand.Previous));
        Setup(play, "\uE768", "播放或暂停", () => _ = model.TogglePlaybackAsync());
        Setup(next, "\uE893", "下一曲", () => _ = model.ControlAsync(PlaybackCommand.Next));
        controls.Children.Add(previous); controls.Children.Add(play); controls.Children.Add(next); root.Children.Add(controls);
        AutomationProperties.SetName(volume, "接收音量");
        MainWindow.AttachVolume(volume, model);
        volume.ValueChanged += (_, args) => { if (!rendering) model.EditVolume(args.NewValue); };
        root.Children.Add(volume);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center };
        Setup(receiving, "\uE768", "开始或停止接收", () => _ = model.WantsReceiving ? model.StopAsync() : model.StartAsync());
        actions.Children.Add(receiving);
        foreach (var (glyph, label, action) in new (string, string, Action)[] {
            ("\uE714", "正在播放", showPlayer), ("\uE713", "设置", showSettings), ("\uE8A5", "打开日志", model.OpenLogs), ("\uE8BB", "退出", quit) })
        {
            var button = new Button(); Setup(button, glyph, label, action); actions.Children.Add(button);
        }
        root.Children.Add(actions); Content = root;
        WindowSizing.Apply(this, 390, 360);
        AppWindow.IsShownInSwitchers = false;
        if (AppWindow.Presenter is OverlappedPresenter presenter) { presenter.SetBorderAndTitleBar(true, false); presenter.IsResizable = false; presenter.IsMaximizable = false; presenter.IsMinimizable = false; }
        Activated += (_, args) => { if (args.WindowActivationState == WindowActivationState.Deactivated) HidePanel(); };
        model.Changed += Render;
        Closed += (_, _) => model.Changed -= Render;
        Render();
    }
    private static void Setup(Button button, string glyph, string label, Action action)
    {
        button.Content = new FontIcon { Glyph = glyph, FontSize = 16 };
        button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.BorderThickness = new Thickness(0);
        ToolTipService.SetToolTip(button, label); AutomationProperties.SetName(button, label);
        button.Click += (_, _) => action();
    }
    private void Render()
    {
        rendering = true; var state = model.State;
        status.Text = model.Busy ? "正在处理…" : state.PhaseLabel;
        title.Text = state.Title.Length > 0 ? state.Title : "等待音乐";
        artist.Text = state.Artist.Length > 0 ? state.Artist : model.Settings.Name;
        previous.IsEnabled = play.IsEnabled = next.IsEnabled = model.CanControl;
        ((FontIcon)play.Content).Glyph = state.Phase == ReceiverPhase.Playing ? "\uE769" : "\uE768";
        ((FontIcon)receiving.Content).Glyph = model.WantsReceiving ? "\uE71A" : "\uE768";
        AutomationProperties.SetName(receiving, model.WantsReceiving ? "停止接收" : "开始接收");
        receiving.IsEnabled = model.Initialized && !model.Busy;
        volume.IsEnabled = model.Initialized; volume.Value = model.Volume; rendering = false;
    }
    public void Toggle()
    {
        if (visible) { HidePanel(); return; }
        var work = DisplayArea.Primary.WorkArea;
        AppWindow.Move(new PointInt32(work.X + work.Width - AppWindow.Size.Width - 16, work.Y + work.Height - AppWindow.Size.Height - 12));
        visible = true; Activate();
    }
    public void HidePanel() { visible = false; AppWindow.Hide(); }
}
