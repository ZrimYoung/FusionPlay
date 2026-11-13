using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using System.Globalization;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
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
    private readonly ISquareWindow squareSizing;
    private readonly TransportTransition transportTransition, expandedTransportTransition;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer hideTimer, coverTimer;
    private BitmapImage? lastArtwork;
    private string? progressColorKey;
    private bool pointerInside, focusInside, controlsShown = true, captionShown = true, closed, compact = true, rendering = true, revealMiniRequested;
    private string preferenceError = "";
    public bool AllowClose { get; set; }
    public event Action? ClosingToTray;
    public void RefreshAppearance() => Render();
    public MainWindow(ReceiverController controller, Action openSettings)
    {
        model = controller; settings = openSettings;
        InitializeComponent();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = true; presenter.IsMaximizable = false; presenter.IsMinimizable = false;
        }
        WindowSizing.Apply(this, 420, 420, 260, 260);
        squareSizing = WindowSizing.FixedSquare(this, NativeHoverChanged);
        transportTransition = new TransportTransition(MiniTransport);
        expandedTransportTransition = new TransportTransition(TransportPanel, 52);
        AttachVolume(VolumeSlider, model);
        RootGrid.Loaded += (_, _) => UpdateInputRegions();
        RootGrid.LayoutUpdated += Root_LayoutUpdated;
        WindowSizing.ResizeContent(this, 420, 420);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Closing += (_, args) =>
        {
            if (AllowClose) return;
            args.Cancel = true; AppWindow.Hide(); ClosingToTray?.Invoke();
        };
        backdrop = new Backdrop(BackdropLayer);
        miniBackdrop = new Backdrop(MiniBackdropLayer, progressive: true);
        loadingBackdrop = new Backdrop(LoadingArtworkLayer, blur: 12);
        backdrop.Changed += Render; miniBackdrop.Changed += Render; loadingBackdrop.Changed += Render;
        backdrop.Failed += LogBackdropFailure; miniBackdrop.Failed += LogBackdropFailure; loadingBackdrop.Failed += LogBackdropFailure;
        hideTimer = DispatcherQueue.CreateTimer(); hideTimer.IsRepeating = false;
        hideTimer.Interval = TimeSpan.FromMilliseconds(400);
        hideTimer.Tick += (_, _) => { if (compact && !pointerInside && !focusInside) { ShowControls(false); ShowCaption(false); } };
        coverTimer = DispatcherQueue.CreateTimer(); coverTimer.IsRepeating = false;
        coverTimer.Interval = TimeSpan.FromMilliseconds(400);
        coverTimer.Tick += (_, _) => { MiniPreviousCover.Source = null; PreviousCoverImage.Source = null; };
        var shortcut = new KeyboardAccelerator { Key = (VirtualKey)0xBC, Modifiers = VirtualKeyModifiers.Control };
        shortcut.Invoked += (_, args) => { openSettings(); args.Handled = true; };
        RootGrid.KeyboardAccelerators.Add(shortcut);
        RootGrid.KeyDown += (_, args) => { if (args.Key == VirtualKey.Tab) { focusInside = true; ShowControls(true); ShowCaption(true); } };
        RootGrid.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => focusInside = false), true);
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated)
            { pointerInside = focusInside = false; ShowCaption(false); ScheduleHide(); }
        };
        model.Changed += Render;
        Closed += (_, _) =>
        {
            closed = true; model.Changed -= Render;
            backdrop.Changed -= Render; miniBackdrop.Changed -= Render; loadingBackdrop.Changed -= Render;
            backdrop.Failed -= LogBackdropFailure; miniBackdrop.Failed -= LogBackdropFailure; loadingBackdrop.Failed -= LogBackdropFailure;
            RootGrid.LayoutUpdated -= Root_LayoutUpdated;
            hideTimer.Stop(); coverTimer.Stop(); transportTransition.Dispose(); expandedTransportTransition.Dispose(); squareSizing.Dispose(); backdrop.Dispose(); miniBackdrop.Dispose(); loadingBackdrop.Dispose();
        };
        Render(); ScheduleHide();
    }
    private void LogBackdropFailure(string code) => model.Store.EventDiagnostic("backdrop:" + code);
    public void RequestMiniPlayer()
    {
        revealMiniRequested = true;
        WindowSizing.ResizeContent(this, 420, 420);
        if (compact) { revealMiniRequested = false; ShowControls(true); ShowCaption(pointerInside); ScheduleHide(); }
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
        if (closed || miniBackdrop == null || backdrop == null) return;
        rendering = true;
        var state = model.State; var preferences = model.Preferences.Value;
        MiniTitle.Text = TitleText.Text = state.Title.Length > 0 ? state.Title : L.Text(state.HasMedia ? "正在接收音乐" : "让音乐，连接此刻");
        string metadata = string.Join(" · ", new[] { state.Artist, state.Album }.Where(x => !string.IsNullOrWhiteSpace(x)));
        MiniArtist.Text = ArtistText.Text = metadata.Length > 0 ? metadata : state.HasMedia ? L.Text("来自手机妙播") : L.Text("在手机妙播中选择") + " " + model.Settings.Name;
        StatusText.Text = model.Busy ? L.Text("正在处理…") : L.Text(state.PhaseLabel);
        UpdateCover();
        MiniPlaceholder.Visibility = CoverPlaceholder.Visibility = model.Artwork == null ? Visibility.Visible : Visibility.Collapsed;
        bool expandedEffects = backdrop.SetArtwork(!compact ? model.ArtworkBytes : null);
        bool effects = miniBackdrop.SetArtwork(compact ? model.ArtworkBytes : null);
        loadingBackdrop.SetArtwork(compact && model.ArtworkLoading ? model.ArtworkBytes : null);
        Brush solid = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        ExpandedRoot.Background = expandedEffects ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 12, 12, 12)) : solid;
        ExpandedRoot.RequestedTheme = expandedEffects ? ElementTheme.Dark : ElementTheme.Default;
        BackdropShade.Visibility = expandedEffects ? Visibility.Visible : Visibility.Collapsed;
        MiniControls.Background = effects ? null : new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 12, 12, 12));
        MiniRoot.Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 12, 12, 12));
        MiniRoot.RequestedTheme = ElementTheme.Dark;
        foreach (var button in new[] { CloseButton, PinButton })
            button.Background = effects ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(100, 20, 20, 20)) : solid;
        MiniShade.Visibility = effects ? Visibility.Visible : Visibility.Collapsed;
        MiniPreviousButton.IsEnabled = MiniPlayButton.IsEnabled = MiniNextButton.IsEnabled = PreviousButton.IsEnabled = PlayButton.IsEnabled = NextButton.IsEnabled = model.CanControl;
        PlaybackIcons.Update(MiniPreviousIcon, PlaybackCommand.Previous);
        PlaybackIcons.Update(MiniNextIcon, PlaybackCommand.Next);
        PlaybackIcons.Update(MiniPlayIcon, state.Phase == ReceiverPhase.Playing ? PlaybackCommand.Pause : PlaybackCommand.Play);
        PlaybackIcons.Update(PreviousIcon, PlaybackCommand.Previous); PlaybackIcons.Update(NextIcon, PlaybackCommand.Next);
        PlaybackIcons.Update(PlayIcon, state.Phase == ReceiverPhase.Playing ? PlaybackCommand.Pause : PlaybackCommand.Play);
        Label(MiniPlayButton, L.Text(state.Phase == ReceiverPhase.Playing ? "暂停" : "播放"));
        Label(MiniPreviousButton, L.Text("上一曲")); Label(MiniNextButton, L.Text("下一曲"));
        Label(PreviousButton, L.Text("上一曲")); Label(NextButton, L.Text("下一曲")); Label(PlayButton, L.Text(state.Phase == ReceiverPhase.Playing ? "暂停" : "播放"));
        Label(SettingsButton, L.Text("设置")); Label(MiniButton, L.Text("迷你播放器")); Label(ExpandedCloseButton, L.Text("关闭窗口", "Close Window"));
        Label(CloseButton, L.Text("关闭窗口", "Close Window"));
        Label(PinButton, L.Text(preferences.Pinned ? "取消置顶" : "窗口置顶"));
        PinIcon.Opacity = preferences.Pinned ? 1 : 0.6;
        PinButton.Visibility = preferences.ShowPinButton ? Visibility.Visible : Visibility.Collapsed;
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsAlwaysOnTop = preferences.Pinned;
        transportTransition.SetVisible(preferences.ShowTransport && !model.MigrationRequired, Backdrop.AnimationsEnabled && compact);
        expandedTransportTransition.SetVisible(preferences.ShowTransport && !model.MigrationRequired, Backdrop.AnimationsEnabled && !compact);
        VolumeSlider.IsEnabled = model.Initialized; VolumeSlider.Value = model.Volume;
        AutomationProperties.SetName(VolumeSlider, L.Text("接收音量"));
        AutomationProperties.SetName(MiniCover, L.Text("专辑封面"));
        AutomationProperties.SetName(MiniProgress, L.Text("播放进度，只读"));
        AutomationProperties.SetName(CoverImage, L.Text("专辑封面")); AutomationProperties.SetName(Progress, L.Text("播放进度，只读"));
        ApplyProgressColor(preferences);
        bool progress = state.HasMedia && state.DurationMs is > 0 && state.PositionMs != null;
        MiniProgressPanel.Visibility = ProgressPanel.Visibility = progress ? Visibility.Visible : Visibility.Collapsed;
        if (progress)
        {
            MiniProgress.Value = Progress.Value = Math.Clamp(100.0 * state.PositionMs!.Value / state.DurationMs!.Value, 0, 100);
            MiniPosition.Text = PositionText.Text = FormatTime(state.PositionMs.Value); MiniDuration.Text = DurationText.Text = FormatTime(state.DurationMs.Value);
        }
        string error = preferenceError.Length > 0 ? preferenceError : model.Error;
        MigrationButton.Content = ExpandedMigrationButton.Content = L.Text("为此电脑建立独立身份");
        MigrationButton.Visibility = ExpandedMigrationButton.Visibility = model.MigrationRequired ? Visibility.Visible : Visibility.Collapsed;
        MiniStatus.Text = ExpandedStatus.Text = L.Text(error.Length > 0 ? error : model.ControlMessage);
        MiniStatus.Visibility = ExpandedStatus.Visibility = MiniStatus.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (compact)
        {
            if (preferences.AlwaysShowControls || WindowSizing.ScreenReaderActive || focusInside || error.Length > 0 || model.MigrationRequired) ShowControls(true);
            else if (!pointerInside) ScheduleHide();
            ShowCaption(pointerInside);
        }
        UpdateBlurCoverage(); UpdateInputRegions(); rendering = false;
    }
    private void ApplyProgressColor(UiPreferences preferences)
    {
        string key = preferences.ProgressColorMode == "custom" ? "custom:" + preferences.ProgressCustomColor : preferences.ProgressColorMode;
        if (progressColorKey == key) return;
        if (preferences.ProgressColorMode == "system")
        {
            // Restore the native theme resource so later system color changes still apply.
            Progress.ClearValue(Control.ForegroundProperty);
            MiniProgress.ClearValue(Control.ForegroundProperty);
        }
        else
        {
            uint rgb = preferences.ProgressColorMode == "white" ? 0xFFFFFF : uint.Parse(preferences.ProgressCustomColor.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            var color = global::Windows.UI.Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
            Progress.Foreground = MiniProgress.Foreground = new SolidColorBrush(color);
        }
        progressColorKey = key;
    }
    private static void Label(Button button, string label)
    { ToolTipService.SetToolTip(button, label); AutomationProperties.SetName(button, label); }
    private void UpdateCover()
    {
        if (ReferenceEquals(lastArtwork, model.Artwork)) return;
        coverTimer.Stop(); MiniPreviousCover.Source = PreviousCoverImage.Source = lastArtwork; MiniCover.Source = CoverImage.Source = model.Artwork;
        bool animate = lastArtwork != null && Backdrop.AnimationsEnabled;
        Fade(MiniPreviousCover, animate ? 1 : 0, 0, animate ? .35 : 0);
        Fade(MiniCover, animate ? 0 : 1, 1, animate ? .35 : 0);
        Fade(PreviousCoverImage, animate ? 1 : 0, 0, animate ? .35 : 0); Fade(CoverImage, animate ? 0 : 1, 1, animate ? .35 : 0);
        lastArtwork = model.Artwork;
        if (animate) coverTimer.Start(); else { MiniPreviousCover.Source = null; PreviousCoverImage.Source = null; }
    }
    private void Root_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        bool nextCompact = WindowSizing.IsCompactContent(e.NewSize.Width, e.NewSize.Height);
        bool changed = compact != nextCompact; compact = nextCompact;
        ExpandedRoot.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        MiniRoot.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        double side = Math.Clamp(Math.Min(e.NewSize.Height - 126, e.NewSize.Width * .36), 130, 360);
        CoverFrame.Width = CoverFrame.Height = side;
        if (changed)
        {
            hideTimer?.Stop(); Render();
            if (compact)
            {
                if (revealMiniRequested || pointerInside) { ShowControls(true); ShowCaption(pointerInside); }
                revealMiniRequested = false; ScheduleHide();
            }
        }
        UpdateBlurCoverage(); UpdateInputRegions();
    }
    private void MiniControls_SizeChanged(object sender, SizeChangedEventArgs e) { UpdateBlurCoverage(); UpdateInputRegions(); }
    private void Root_LayoutUpdated(object? sender, object e) => UpdateInputRegions();
    private void UpdateBlurCoverage() => miniBackdrop?.SetCoverage(RootGrid.ActualHeight > 0 ? Math.Clamp(MiniControls.ActualHeight * 1.35 / RootGrid.ActualHeight, .1, 1) : .65);
    private void Root_PointerEntered(object sender, PointerRoutedEventArgs e) { pointerInside = true; hideTimer?.Stop(); ShowControls(true); ShowCaption(true); }
    private void Root_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(RootGrid).Position;
        if (point.X >= 0 && point.Y >= 0 && point.X < RootGrid.ActualWidth && point.Y < RootGrid.ActualHeight) return;
        pointerInside = false; ShowCaption(false); ScheduleHide();
    }
    private void UpdateInputRegions()
    {
        if (closed || squareSizing == null || RootGrid.XamlRoot == null) return;
        double scale = RootGrid.XamlRoot.RasterizationScale;
        var rectangles = new List<global::Windows.Graphics.RectInt32>();
        void Add(FrameworkElement element)
        {
            if (element.Visibility != Visibility.Visible || element.ActualWidth <= 0 || element.ActualHeight <= 0) return;
            var bounds = element.TransformToVisual(RootGrid).TransformBounds(new global::Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
            int x = (int)Math.Floor(bounds.Left * scale), y = (int)Math.Floor(bounds.Top * scale);
            rectangles.Add(new(x, y, (int)Math.Ceiling(bounds.Right * scale) - x, (int)Math.Ceiling(bounds.Bottom * scale) - y));
        }
        if (!compact)
        {
            Add(SettingsButton); Add(MiniButton); Add(ExpandedCloseButton); Add(VolumeSlider); Add(ExpandedMigrationButton);
            if (TransportPanel.Visibility == Visibility.Visible && TransportPanel.ActualHeight > 0) { Add(PreviousButton); Add(PlayButton); Add(NextButton); }
        }
        else
        {
            if (captionShown) { Add(CloseButton); Add(PinButton); }
            if (controlsShown)
            {
                if (MiniTransport.Visibility == Visibility.Visible && MiniTransport.ActualHeight > 0) { Add(MiniPreviousButton); Add(MiniPlayButton); Add(MiniNextButton); }
                Add(MigrationButton);
            }
        }
        squareSizing.UpdateInputRegions(rectangles.ToArray());
    }
    private void NativeHoverChanged(bool inside)
    {
        if (closed || pointerInside == inside) return;
        pointerInside = inside;
        if (inside) { hideTimer?.Stop(); ShowControls(true); ShowCaption(true); }
        else { ShowCaption(false); ScheduleHide(); }
    }
    private void Root_GotFocus(object sender, RoutedEventArgs e)
    {
        focusInside = RootGrid.XamlRoot != null && FocusManager.GetFocusedElement(RootGrid.XamlRoot) is Control { FocusState: FocusState.Keyboard };
        if (focusInside) { hideTimer?.Stop(); ShowControls(true); ShowCaption(true); }
    }
    private void Root_LostFocus(object sender, RoutedEventArgs e) => DispatcherQueue.TryEnqueue(() =>
    {
        if (closed || RootGrid.XamlRoot == null) return;
        var focused = FocusManager.GetFocusedElement(RootGrid.XamlRoot); var focus = focused as DependencyObject;
        while (focus != null && focus != RootGrid) focus = VisualTreeHelper.GetParent(focus);
        focusInside = focus == RootGrid && focused is Control { FocusState: FocusState.Keyboard };
        if (!focusInside) { ShowCaption(pointerInside); ScheduleHide(); }
    });
    private void ScheduleHide()
    {
        if (hideTimer == null || closed || !compact || pointerInside || focusInside) return;
        if (!hideTimer.IsRunning) hideTimer.Start();
    }
    private void ShowControls(bool visible)
    {
        if (!compact || MiniControls == null) return;
        visible |= model.Preferences.Value.AlwaysShowControls || WindowSizing.ScreenReaderActive || focusInside || model.Error.Length > 0 || preferenceError.Length > 0 || model.MigrationRequired;
        if (visible == controlsShown) return;
        controlsShown = visible;
        // Let the artwork backdrop establish contrast before the information arrives.
        // On exit, information leaves first while the backdrop lingers underneath.
        AnimateVisibility(MiniBackdropLayer, visible, visible ? .70 : .65, visible ? 0 : .10);
        AnimateVisibility(MiniShade, visible, visible ? .70 : .65, visible ? 0 : .10);
        AnimateVisibility(MiniControls, visible, visible ? .60 : .45, visible ? .12 : 0);
        MiniControls.IsHitTestVisible = visible;
        MiniBackdropLayer.IsHitTestVisible = MiniShade.IsHitTestVisible = false;
        UpdateInputRegions();
    }
    private void ShowCaption(bool visible)
    {
        if (!compact || MiniActions == null) return;
        visible |= focusInside || WindowSizing.ScreenReaderActive;
        if (visible == captionShown) return;
        captionShown = visible;
        AnimateVisibility(MiniActions, visible, visible ? .60 : .45, visible ? .12 : 0);
        MiniActions.IsHitTestVisible = visible;
        UpdateInputRegions();
    }
    private static void AnimateVisibility(FrameworkElement element, bool visible, double seconds, double delay)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        if (!Backdrop.AnimationsEnabled)
        {
            visual.StopAnimation("Opacity"); visual.Opacity = visible ? 1 : 0; return;
        }
        using var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
        using var easing = visible
            ? visual.Compositor.CreateCubicBezierEasingFunction(new Vector2(.22f, .61f), new Vector2(.36f, 1))
            : visual.Compositor.CreateCubicBezierEasingFunction(new Vector2(.4f, 0), new Vector2(.85f, .8f));
        // StartingValue samples the presentation value of the animation being
        // replaced. Do not StopAnimation here: that would reset to the base value
        // and flash when a pointer reverses direction partway through a fade.
        animation.InsertExpressionKeyFrame(0, "this.StartingValue");
        animation.InsertKeyFrame(1, visible ? 1 : 0, easing);
        animation.DelayBehavior = AnimationDelayBehavior.SetInitialValueBeforeDelay;
        animation.DelayTime = TimeSpan.FromSeconds(delay);
        animation.Duration = TimeSpan.FromSeconds(seconds);
        visual.StartAnimation("Opacity", animation);
    }
    private static void Fade(FrameworkElement element, double from, double to, double seconds)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element); visual.StopAnimation("Opacity");
        if (seconds == 0) { visual.Opacity = (float)to; return; }
        var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
        animation.InsertKeyFrame(0, (float)from); animation.InsertKeyFrame(1, (float)to); animation.Duration = TimeSpan.FromSeconds(seconds);
        visual.StartAnimation("Opacity", animation); animation.Dispose();
    }
    private static string FormatTime(ulong milliseconds)
    { ulong seconds = milliseconds / 1000; return seconds >= 3600 ? $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}" : $"{seconds / 60}:{seconds % 60:00}"; }
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void Settings_Click(object sender, RoutedEventArgs e) => settings();
    private void Mini_Click(object sender, RoutedEventArgs e) => RequestMiniPlayer();
    private void Volume_Changed(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e) { if (!rendering) model.EditVolume(e.NewValue); }
    private void Pin_Click(object sender, RoutedEventArgs e)
    {
        try { model.Preferences.Update(model.Preferences.Value with { Pinned = !model.Preferences.Value.Pinned }); preferenceError = ""; }
        catch { preferenceError = L.Text("无法保存外观设置，请检查数据目录。"); }
        Render();
    }
    private async void Previous_Click(object sender, RoutedEventArgs e) => await model.ControlAsync(PlaybackCommand.Previous);
    private async void Next_Click(object sender, RoutedEventArgs e) => await model.ControlAsync(PlaybackCommand.Next);
    private async void Play_Click(object sender, RoutedEventArgs e) => await model.TogglePlaybackAsync();
    private async void Migration_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = RootGrid.XamlRoot, Title = L.Text("为此电脑建立独立身份"), Content = L.Text("将保留名称、音量等设置，并备份旧设备身份。此电脑会作为新的接收设备出现在手机上。"), PrimaryButtonText = L.Text("备份并建立"), CloseButtonText = L.Text("取消"), DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await model.MigrateAsync();
    }
}
