using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace FusionPlay.Windows;

public sealed partial class MainWindow : Window
{
    private readonly ReceiverController model;
    private readonly Action settings;
    private readonly Backdrop backdrop, miniBackdrop, loadingBackdrop;
    private readonly IDisposable squareSizing;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer hideTimer, coverTimer;
    private BitmapImage? lastArtwork;
    private bool rendering = true, compact, pointerInside, focusInside, controlsShown = true, closed;
    private string preferenceError = "";
    public bool AllowClose { get; set; }
    public event Action? ClosingToTray;
    public void RefreshAppearance() => Render();
    public MainWindow(ReceiverController controller, Action openSettings)
    {
        model = controller; settings = openSettings;
        InitializeComponent();
        WindowSizing.Apply(this, 820, 480, 260, 260);
        squareSizing = WindowSizing.CompactSquare(this);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Closing += (_, args) =>
        {
            if (AllowClose) return;
            args.Cancel = true; AppWindow.Hide(); ClosingToTray?.Invoke();
        };
        backdrop = new Backdrop(BackdropLayer);
        miniBackdrop = new Backdrop(MiniBackdropLayer, progressive: true);
        loadingBackdrop = new Backdrop(LoadingArtworkLayer, blur: 12);
        backdrop.Changed += Render;
        miniBackdrop.Changed += Render; loadingBackdrop.Changed += Render;
        AttachVolume(VolumeSlider, model);
        hideTimer = DispatcherQueue.CreateTimer(); hideTimer.IsRepeating = false;
        hideTimer.Interval = TimeSpan.FromMilliseconds(400);
        hideTimer.Tick += (_, _) => { if (!pointerInside && !focusInside) ShowControls(false); };
        coverTimer = DispatcherQueue.CreateTimer(); coverTimer.IsRepeating = false;
        coverTimer.Interval = TimeSpan.FromMilliseconds(400);
        coverTimer.Tick += (_, _) => { PreviousCoverImage.Source = null; MiniPreviousCover.Source = null; };
        var shortcut = new KeyboardAccelerator { Key = (VirtualKey)0xBC, Modifiers = VirtualKeyModifiers.Control };
        shortcut.Invoked += (_, args) => { settings(); args.Handled = true; };
        RootGrid.KeyboardAccelerators.Add(shortcut);
        RootGrid.KeyDown += (_, args) => { if (args.Key == VirtualKey.Tab) { focusInside = true; ShowControls(true); } };
        RootGrid.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => focusInside = false), true);
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated)
            { pointerInside = focusInside = false; ScheduleHide(); }
        };
        model.Changed += Render;
        Closed += (_, _) =>
        {
            closed = true; model.Changed -= Render; backdrop.Changed -= Render;
            miniBackdrop.Changed -= Render; loadingBackdrop.Changed -= Render;
            hideTimer.Stop(); coverTimer.Stop(); squareSizing.Dispose();
            backdrop.Dispose(); miniBackdrop.Dispose(); loadingBackdrop.Dispose();
        };
        Render();
    }
    public void RequestMiniPlayer()
    {
        double side = Math.Clamp(RootGrid.ActualWidth, 260, 420);
        WindowSizing.ResizeContent(this, side, side);
        ShowControls(true); ScheduleHide();
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
        if (closed || backdrop == null) return;
        rendering = true;
        var state = model.State; var preferences = model.Preferences.Value;
        StatusText.Text = model.Busy ? L.Text("正在处理…") : L.Text(state.PhaseLabel);
        TitleText.Text = MiniTitle.Text = state.Title.Length > 0 ? state.Title : L.Text(state.HasMedia ? "正在接收音乐" : "让音乐，连接此刻");
        string metadata = string.Join(" · ", new[] { state.Artist, state.Album }.Where(x => !string.IsNullOrWhiteSpace(x)));
        ArtistText.Text = MiniArtist.Text = metadata.Length > 0 ? metadata : state.HasMedia ? L.Text("来自手机妙播") : L.Text("在手机妙播中选择") + " " + model.Settings.Name;
        MiniArtist.Visibility = MiniArtist.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateCover();
        CoverPlaceholder.Visibility = MiniPlaceholder.Visibility = model.Artwork == null ? Visibility.Visible : Visibility.Collapsed;
        bool effects = backdrop.SetArtwork(model.ArtworkBytes);
        BackdropShade.Visibility = effects ? Visibility.Visible : Visibility.Collapsed;
        ExpandedRoot.RequestedTheme = effects ? ElementTheme.Dark : ElementTheme.Default;
        bool miniEffects = miniBackdrop.SetArtwork(model.ArtworkBytes);
        loadingBackdrop.SetArtwork(model.ArtworkLoading ? model.ArtworkBytes : null);
        MiniControls.Background = miniEffects ? null : (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        MiniRoot.Background = miniEffects ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 21, 33, 54)) : (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        MiniSettingsButton.Background = PinButton.Background = miniEffects ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(85, 32, 32, 32)) : (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        MiniRoot.RequestedTheme = miniEffects ? ElementTheme.Dark : ElementTheme.Default;
        MiniShade.Visibility = miniEffects ? Visibility.Visible : Visibility.Collapsed;
        PreviousButton.IsEnabled = PlayButton.IsEnabled = NextButton.IsEnabled = model.CanControl;
        MiniPreviousButton.IsEnabled = MiniPlayButton.IsEnabled = MiniNextButton.IsEnabled = model.CanControl;
        PlayIcon.Glyph = MiniPlayIcon.Glyph = state.Phase == ReceiverPhase.Playing ? "\uE769" : "\uE768";
        string playLabel = L.Text(state.Phase == ReceiverPhase.Playing ? "暂停" : "播放");
        Label(PlayButton, playLabel); Label(MiniPlayButton, playLabel);
        foreach (var button in new[] { PreviousButton, MiniPreviousButton }) Label(button, L.Text("上一曲"));
        foreach (var button in new[] { NextButton, MiniNextButton }) Label(button, L.Text("下一曲"));
        Label(SettingsButton, L.Text("设置")); Label(MiniSettingsButton, L.Text("设置")); Label(MiniButton, L.Text("迷你播放器"));
        Label(PinButton, L.Text(preferences.Pinned ? "取消置顶" : "窗口置顶"));
        PinIcon.Opacity = preferences.Pinned ? 1 : 0.6;
        PinButton.Visibility = preferences.ShowPinButton ? Visibility.Visible : Visibility.Collapsed;
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsAlwaysOnTop = preferences.Pinned;
        TransportPanel.Visibility = MiniTransport.Visibility = preferences.ShowTransport ? Visibility.Visible : Visibility.Collapsed;
        VolumeSlider.IsEnabled = model.Initialized; VolumeSlider.Value = model.Volume;
        AutomationProperties.SetName(VolumeSlider, L.Text("接收音量"));
        AutomationProperties.SetName(CoverImage, L.Text("专辑封面")); AutomationProperties.SetName(MiniCover, L.Text("专辑封面"));
        AutomationProperties.SetName(Progress, L.Text("播放进度，只读")); AutomationProperties.SetName(MiniProgress, L.Text("播放进度，只读"));
        bool progress = state.HasMedia && state.DurationMs is > 0 && state.PositionMs != null;
        ProgressPanel.Visibility = MiniProgressPanel.Visibility = progress ? Visibility.Visible : Visibility.Collapsed;
        if (progress)
        {
            Progress.Value = MiniProgress.Value = Math.Clamp(100.0 * state.PositionMs!.Value / state.DurationMs!.Value, 0, 100);
            PositionText.Text = MiniPosition.Text = FormatTime(state.PositionMs.Value);
            DurationText.Text = MiniDuration.Text = FormatTime(state.DurationMs.Value);
        }
        string error = preferenceError.Length > 0 ? preferenceError : model.Error;
        ErrorBar.Message = L.Text(error); ErrorBar.IsOpen = error.Length > 0;
        MigrationButton.Content = L.Text("为此电脑建立独立身份");
        MigrationButton.Visibility = model.MigrationRequired ? Visibility.Visible : Visibility.Collapsed;
        CommandText.Text = L.Text(model.ControlMessage); CommandText.Visibility = model.ControlMessage.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        MiniStatus.Text = L.Text(error.Length > 0 ? error : model.ControlMessage);
        MiniStatus.Visibility = MiniStatus.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (preferences.AlwaysShowControls || WindowSizing.ScreenReaderActive || focusInside) ShowControls(true);
        else if (!pointerInside) ScheduleHide();
        UpdateBlurCoverage(); rendering = false;
    }
    private static void Label(Button button, string label)
    { ToolTipService.SetToolTip(button, label); AutomationProperties.SetName(button, label); }
    private void UpdateCover()
    {
        if (ReferenceEquals(lastArtwork, model.Artwork)) return;
        coverTimer.Stop();
        PreviousCoverImage.Source = MiniPreviousCover.Source = lastArtwork;
        CoverImage.Source = MiniCover.Source = model.Artwork;
        bool animate = lastArtwork != null && Backdrop.AnimationsEnabled;
        foreach (var image in new[] { PreviousCoverImage, MiniPreviousCover }) Fade(image, animate ? 1 : 0, 0, animate ? 0.35 : 0);
        foreach (var image in new[] { CoverImage, MiniCover }) Fade(image, animate ? 0 : 1, 1, animate ? 0.35 : 0);
        lastArtwork = model.Artwork;
        if (animate) coverTimer.Start(); else { PreviousCoverImage.Source = null; MiniPreviousCover.Source = null; }
    }
    private void Root_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        bool next = e.NewSize.Width < 600 || e.NewSize.Height < 360;
        if (compact != next)
        {
            compact = next;
            ExpandedRoot.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
            MiniRoot.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
            ShowControls(true); ScheduleHide();
        }
        double cover = Math.Clamp(Math.Min(e.NewSize.Height - 140, e.NewSize.Width * 0.36), 130, 320);
        CoverFrame.Width = CoverFrame.Height = cover;
        UpdateBlurCoverage();
    }
    private void MiniControls_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateBlurCoverage();
    private void UpdateBlurCoverage() => miniBackdrop?.SetCoverage(RootGrid.ActualHeight > 0 ? Math.Clamp(MiniControls.ActualHeight * 1.35 / RootGrid.ActualHeight, 0.1, 1) : 0.65);
    private void Root_PointerEntered(object sender, PointerRoutedEventArgs e) { pointerInside = true; hideTimer?.Stop(); ShowControls(true); }
    private void Root_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(RootGrid).Position;
        if (point.X >= 0 && point.Y >= 0 && point.X < RootGrid.ActualWidth && point.Y < RootGrid.ActualHeight) return;
        pointerInside = false; ScheduleHide();
    }
    private void Root_GotFocus(object sender, RoutedEventArgs e)
    {
        focusInside = RootGrid.XamlRoot != null && FocusManager.GetFocusedElement(RootGrid.XamlRoot) is Control { FocusState: FocusState.Keyboard };
        if (focusInside) { hideTimer?.Stop(); ShowControls(true); }
    }
    private void Root_LostFocus(object sender, RoutedEventArgs e) => DispatcherQueue.TryEnqueue(() =>
    {
        if (closed || RootGrid.XamlRoot == null) return;
        var focused = FocusManager.GetFocusedElement(RootGrid.XamlRoot);
        var focus = focused as DependencyObject;
        while (focus != null && focus != RootGrid) focus = VisualTreeHelper.GetParent(focus);
        focusInside = focus == RootGrid && focused is Control { FocusState: FocusState.Keyboard };
        if (!focusInside) ScheduleHide();
    });
    private void ScheduleHide()
    {
        if (hideTimer == null || closed || pointerInside || focusInside || model.Preferences.Value.AlwaysShowControls || WindowSizing.ScreenReaderActive) return;
        if (!hideTimer.IsRunning) hideTimer.Start();
    }
    private void ShowControls(bool visible)
    {
        if (MiniControls == null) return;
        visible |= model.Preferences.Value.AlwaysShowControls || WindowSizing.ScreenReaderActive || focusInside;
        if (visible == controlsShown) return;
        controlsShown = visible;
        double seconds = Backdrop.AnimationsEnabled ? visible ? 0.25 : 0.65 : 0;
        foreach (var element in new FrameworkElement[] { MiniControls, MiniActions, MiniBackdropLayer, MiniShade })
        { Fade(element, visible ? 0 : 1, visible ? 1 : 0, seconds); element.IsHitTestVisible = visible && (element == MiniControls || element == MiniActions); }
    }
    private static void Fade(FrameworkElement element, double from, double to, double seconds)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        visual.StopAnimation("Opacity");
        if (seconds == 0) { visual.Opacity = (float)to; return; }
        var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
        animation.InsertKeyFrame(0, (float)from); animation.InsertKeyFrame(1, (float)to); animation.Duration = TimeSpan.FromSeconds(seconds);
        visual.StartAnimation("Opacity", animation); animation.Dispose();
    }
    private static string FormatTime(ulong milliseconds)
    { ulong seconds = milliseconds / 1000; return seconds >= 3600 ? $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}" : $"{seconds / 60}:{seconds % 60:00}"; }
    private void Settings_Click(object sender, RoutedEventArgs e) => settings();
    private void Mini_Click(object sender, RoutedEventArgs e) => RequestMiniPlayer();
    private void Pin_Click(object sender, RoutedEventArgs e)
    {
        try { model.Preferences.Update(model.Preferences.Value with { Pinned = !model.Preferences.Value.Pinned }); preferenceError = ""; }
        catch { preferenceError = L.Text("无法保存外观设置，请检查数据目录。"); }
        Render();
    }
    private async void Previous_Click(object sender, RoutedEventArgs e) => await model.ControlAsync(PlaybackCommand.Previous);
    private async void Next_Click(object sender, RoutedEventArgs e) => await model.ControlAsync(PlaybackCommand.Next);
    private async void Play_Click(object sender, RoutedEventArgs e) => await model.TogglePlaybackAsync();
    private void Volume_Changed(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e) { if (!rendering) model.EditVolume(e.NewValue); }
    private void ErrorBar_Closed(InfoBar sender, InfoBarClosedEventArgs args) { if (!rendering) { preferenceError = ""; model.ClearError(); } }
    private async void Migration_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = RootGrid.XamlRoot, Title = L.Text("为此电脑建立独立身份"), Content = L.Text("将保留名称、音量等设置，并备份旧设备身份。此电脑会作为新的接收设备出现在手机上。"), PrimaryButtonText = L.Text("备份并建立"), CloseButtonText = L.Text("取消"), DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await model.MigrateAsync();
    }
}
