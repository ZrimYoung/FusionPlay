using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.ViewManagement;

namespace FusionPlay.Windows;

public sealed partial class MainWindow : Window
{
    private readonly ReceiverController model;
    private readonly Action settings;
    private readonly Backdrop backdrop;
    private bool rendering;
    public bool AllowClose { get; set; }
    public event Action? ClosingToTray;
    public void RefreshAppearance() => Render();
    public MainWindow(ReceiverController controller, Action openSettings)
    {
        model = controller; settings = openSettings;
        InitializeComponent();
        WindowSizing.Apply(this, 820, 480, 680, 440);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Closing += (_, args) =>
        {
            if (AllowClose) return;
            args.Cancel = true; AppWindow.Hide(); ClosingToTray?.Invoke();
        };
        backdrop = new Backdrop(BackdropLayer);
        backdrop.Changed += Render;
        AttachVolume(VolumeSlider, model);
        model.Changed += Render;
        Closed += (_, _) => { model.Changed -= Render; backdrop.Changed -= Render; backdrop.Dispose(); };
        Render();
    }
    internal static void AttachVolume(Slider slider, ReceiverController model)
    {
        slider.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => model.BeginVolume()), true);
        slider.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => _ = model.CommitVolumeAsync()), true);
        slider.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler((_, _) => _ = model.CommitVolumeAsync()), true);
        slider.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler((_, _) => _ = model.CommitVolumeAsync()), true);
        slider.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, args) => { if (args.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End) model.BeginVolume(); }), true);
        slider.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler((_, args) => { if (args.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End) _ = model.CommitVolumeAsync(); }), true);
        slider.LostFocus += (_, _) => _ = model.CommitVolumeAsync();
    }
    private void Render()
    {
        rendering = true;
        var state = model.State;
        StatusText.Text = model.Busy ? "正在处理…" : state.PhaseLabel;
        TitleText.Text = state.Title.Length > 0 ? state.Title : state.HasMedia ? "正在接收音乐" : "让音乐，连接此刻";
        ArtistText.Text = state.Artist.Length > 0 ? state.Artist : state.HasMedia ? "来自手机妙播" : $"在手机妙播中选择 {model.Settings.Name}";
        CoverImage.Source = model.Artwork;
        CoverPlaceholder.Visibility = model.Artwork == null ? Visibility.Visible : Visibility.Collapsed;
        bool effects = backdrop.SetArtwork(model.ArtworkBytes);
        BackdropShade.Visibility = effects ? Visibility.Visible : Visibility.Collapsed;
        RootGrid.RequestedTheme = effects ? ElementTheme.Dark : ElementTheme.Default;
        PreviousButton.IsEnabled = PlayButton.IsEnabled = NextButton.IsEnabled = model.CanControl;
        PlayIcon.Glyph = state.Phase == ReceiverPhase.Playing ? "\uE769" : "\uE768";
        AutomationProperties.SetName(PlayButton, state.Phase == ReceiverPhase.Playing ? "暂停" : "播放");
        VolumeSlider.IsEnabled = model.Initialized;
        VolumeSlider.Value = model.Volume;
        bool progress = state.HasMedia && state.DurationMs is > 0 && state.PositionMs != null;
        ProgressPanel.Visibility = progress ? Visibility.Visible : Visibility.Collapsed;
        if (progress)
        {
            Progress.Value = Math.Clamp(100.0 * state.PositionMs!.Value / state.DurationMs!.Value, 0, 100);
            PositionText.Text = FormatTime(state.PositionMs.Value);
            DurationText.Text = FormatTime(state.DurationMs.Value);
        }
        ErrorBar.Message = model.Error; ErrorBar.IsOpen = model.Error.Length > 0;
        MigrationButton.Visibility = model.MigrationRequired ? Visibility.Visible : Visibility.Collapsed;
        CommandText.Text = model.ControlMessage; CommandText.Visibility = model.ControlMessage.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        rendering = false;
    }
    private static string FormatTime(ulong milliseconds)
    {
        ulong seconds = milliseconds / 1000;
        return seconds >= 3600 ? $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}" : $"{seconds / 60}:{seconds % 60:00}";
    }
    private void Settings_Click(object sender, RoutedEventArgs e) => settings();
    private async void Previous_Click(object sender, RoutedEventArgs e) => await model.ControlAsync(PlaybackCommand.Previous);
    private async void Next_Click(object sender, RoutedEventArgs e) => await model.ControlAsync(PlaybackCommand.Next);
    private async void Play_Click(object sender, RoutedEventArgs e) => await model.TogglePlaybackAsync();
    private void Volume_Changed(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e) { if (!rendering) model.EditVolume(e.NewValue); }
    private void ErrorBar_Closed(InfoBar sender, InfoBarClosedEventArgs args) { if (!rendering) model.ClearError(); }
    private async void Migration_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot, Title = "为此电脑建立独立身份",
            Content = "将保留名称、音量等设置，并备份旧设备身份。此电脑会作为新的接收设备出现在手机上。",
            PrimaryButtonText = "备份并建立", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await model.MigrateAsync();
    }
}
