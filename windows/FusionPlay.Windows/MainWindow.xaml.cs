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
    private readonly Backdrop backdrop, miniBackdrop, loadingBackdrop, lyricsBackdrop, expandedLyricsBackdrop;
    private readonly global::Windows.UI.ViewManagement.AccessibilitySettings accessibility = new();
    private readonly global::Windows.UI.ViewManagement.UISettings appearance = new();
    private readonly Brush lyricFallback = Gradient(global::Windows.UI.Color.FromArgb(255, 43, 54, 77), global::Windows.UI.Color.FromArgb(255, 41, 33, 56), global::Windows.UI.Color.FromArgb(255, 20, 26, 41));
    private readonly Brush lyricArtShade = Gradient(global::Windows.UI.Color.FromArgb(122, 0, 0, 0), global::Windows.UI.Color.FromArgb(152, 0, 0, 0));
    private readonly Brush lyricEmptyShade = Gradient(global::Windows.UI.Color.FromArgb(0, 0, 0, 0), global::Windows.UI.Color.FromArgb(56, 0, 0, 0));
    private readonly Brush legacyShade = new SolidColorBrush(global::Windows.UI.Color.FromArgb(153, 0, 0, 0));
    private readonly ISquareWindow squareSizing;
    private readonly PlayerFullScreen fullScreen;
    private readonly LyricsView miniLyrics, expandedLyrics;
    private readonly TransportTransition transportTransition, expandedTransportTransition;
    private readonly TransportTransition progressTransition, expandedProgressTransition;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer hideTimer, coverTimer;
    private BitmapImage? lastArtwork;
    private string? progressColorKey;
    private bool pointerInside, focusInside, controlsShown = true, captionShown = true, fullscreenCaptionShown = true, progressShown, lyricsVisible, closed, compact = true, rendering = true, revealMiniRequested;
    private string lyricsTrackId = "", lyricsTitle = "";
    private string preferenceError = "";
    public bool AllowClose { get; set; }
    public event Action? ClosingToTray;
    public bool IsFullScreen => fullScreen?.IsFullScreen == true;
    public void RefreshAppearance() => Render();
    public MainWindow(ReceiverController controller, Action openSettings)
    {
        model = controller; settings = openSettings;
        InitializeComponent();
        var coverClip = new RectangleGeometry { Rect = new global::Windows.Foundation.Rect(0, 0, MiniCoverPanel.ActualWidth, MiniCoverPanel.ActualHeight) }; MiniCoverPanel.Clip = coverClip;
        MiniCoverPanel.SizeChanged += (_, args) => coverClip.Rect = new global::Windows.Foundation.Rect(0, 0, args.NewSize.Width, args.NewSize.Height);
        miniLyrics = new LyricsView(); expandedLyrics = new LyricsView();
        MiniLyricsHost.Children.Add(miniLyrics); ExpandedLyricsHost.Children.Add(expandedLyrics);
        miniLyrics.SeekRequested += SeekLyric; expandedLyrics.SeekRequested += SeekLyric;
        foreach (var seek in new[] { ProgressSeek, MiniProgressSeek })
        {
            // Only the presentation position can be pending; track identity,
            // duration and command validation always retain source metadata.
            seek.Snapshot = () => model.State with { PositionMs = model.DisplayPositionMs };
            seek.SeekRequested += SeekRequested;
        }
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = true; presenter.IsMaximizable = false; presenter.IsMinimizable = false;
        }
        WindowSizing.Apply(this, 420, 420, 260, 260);
        squareSizing = WindowSizing.FixedSquare(this, NativeHoverChanged);
        fullScreen = new PlayerFullScreen(this, () => model.Preferences.Value.Pinned, active => squareSizing.SetPlayerLayout(lyricsVisible, active));
        fullScreen.Changed += FullScreenChanged;
        transportTransition = new TransportTransition(MiniTransport);
        expandedTransportTransition = new TransportTransition(TransportPanel, 52);
        progressTransition = new TransportTransition(MiniProgressPanel, 48, clipToBounds: true);
        expandedProgressTransition = new TransportTransition(ProgressPanel, 48, clipToBounds: true);
        AttachVolume(VolumeSlider, model);
        RootGrid.Loaded += (_, _) => { UiTypography.Apply(RootGrid, model.Preferences.Value, force: true); UpdateInputRegions(); };
        RootGrid.LayoutUpdated += Root_LayoutUpdated;
        WindowSizing.ResizeContent(this, 420, 420);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Closing += (_, args) =>
        {
            ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer();
            if (AllowClose) return;
            if (IsFullScreen) fullScreen.Exit();
            args.Cancel = true; AppWindow.Hide(); ClosingToTray?.Invoke();
        };
        backdrop = new Backdrop(BackdropLayer);
        miniBackdrop = new Backdrop(MiniBackdropLayer, progressive: true);
        loadingBackdrop = new Backdrop(LoadingArtworkLayer, blur: 12);
        lyricsBackdrop = new Backdrop(MiniLyricsBackground, blur: 48);
        expandedLyricsBackdrop = new Backdrop(ExpandedLyricsBackground, blur: 48);
        backdrop.Changed += Render; miniBackdrop.Changed += Render; loadingBackdrop.Changed += Render;
        backdrop.Failed += LogBackdropFailure; miniBackdrop.Failed += LogBackdropFailure; loadingBackdrop.Failed += LogBackdropFailure;
        lyricsBackdrop.Changed += Render; lyricsBackdrop.Failed += LogBackdropFailure;
        expandedLyricsBackdrop.Changed += Render; expandedLyricsBackdrop.Failed += LogBackdropFailure;
        appearance.ColorValuesChanged += ContrastChanged;
        hideTimer = DispatcherQueue.CreateTimer(); hideTimer.IsRepeating = false;
        hideTimer.Interval = TimeSpan.FromMilliseconds(400);
        hideTimer.Tick += (_, _) => { if (compact && !pointerInside && !focusInside) { ShowControls(false); ShowCaption(false); } };
        coverTimer = DispatcherQueue.CreateTimer(); coverTimer.IsRepeating = false;
        coverTimer.Interval = TimeSpan.FromMilliseconds(400);
        coverTimer.Tick += (_, _) => { MiniPreviousCover.Source = null; PreviousCoverImage.Source = null; };
        var shortcut = new KeyboardAccelerator { Key = (VirtualKey)0xBC, Modifiers = VirtualKeyModifiers.Control };
        shortcut.Invoked += (_, args) => { openSettings(); args.Handled = true; };
        RootGrid.KeyboardAccelerators.Add(shortcut);
        foreach (var key in new[] { new KeyboardAccelerator { Key = VirtualKey.F11 }, new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift } })
        { key.Invoked += (_, args) => { ToggleFullScreen(); args.Handled = true; }; RootGrid.KeyboardAccelerators.Add(key); }
        var escape = new KeyboardAccelerator { Key = VirtualKey.Escape };
        escape.Invoked += (_, args) => { if (IsFullScreen) { ToggleFullScreen(); args.Handled = true; } };
        RootGrid.KeyboardAccelerators.Add(escape);
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
            lyricsBackdrop.Changed -= Render; lyricsBackdrop.Failed -= LogBackdropFailure;
            expandedLyricsBackdrop.Changed -= Render; expandedLyricsBackdrop.Failed -= LogBackdropFailure; appearance.ColorValuesChanged -= ContrastChanged;
            miniLyrics.SeekRequested -= SeekLyric; expandedLyrics.SeekRequested -= SeekLyric;
            miniLyrics.Dispose(); expandedLyrics.Dispose(); fullScreen.Changed -= FullScreenChanged; fullScreen.Dispose();
            RootGrid.LayoutUpdated -= Root_LayoutUpdated;
            ProgressSeek.SeekRequested -= SeekRequested; MiniProgressSeek.SeekRequested -= SeekRequested;
            hideTimer.Stop(); coverTimer.Stop(); transportTransition.Dispose(); expandedTransportTransition.Dispose(); progressTransition.Dispose(); expandedProgressTransition.Dispose(); squareSizing.Dispose(); backdrop.Dispose(); miniBackdrop.Dispose(); loadingBackdrop.Dispose(); lyricsBackdrop.Dispose(); expandedLyricsBackdrop.Dispose();
        };
        Render(); ScheduleHide();
    }
    private void LogBackdropFailure(string code) => model.Store.EventDiagnostic("backdrop:" + code);
    private void ContrastChanged(global::Windows.UI.ViewManagement.UISettings sender, object args)
        => DispatcherQueue.TryEnqueue(() => { if (!closed) Render(); });
    private static Brush Gradient(params global::Windows.UI.Color[] colors)
    {
        var brush = new LinearGradientBrush { StartPoint = new global::Windows.Foundation.Point(0, 0), EndPoint = new global::Windows.Foundation.Point(1, 1) };
        for (int index = 0; index < colors.Length; index++) brush.GradientStops.Add(new GradientStop { Color = colors[index], Offset = (double)index / (colors.Length - 1) });
        return brush;
    }
    public void RequestMiniPlayer()
    {
        if (IsFullScreen) fullScreen.Exit();
        revealMiniRequested = true;
        WindowSizing.ResizeContent(this, 420, lyricsVisible ? 693 : 420);
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
        ulong? displayPosition = model.DisplayPositionMs;
        lyricsVisible = LyricsDisplayModes.IsVisible(preferences.LyricsDisplayMode, model.LyricsAvailable);
        squareSizing.SetPlayerLayout(lyricsVisible, IsFullScreen);
        ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
        if (!model.LyricsLoading) { lyricsTrackId = state.TrackId; lyricsTitle = state.Title; }
        bool lyricSeek = model.CanSeek && !model.LyricsLoading;
        miniLyrics.Update(model.Lyrics, model.LyricsPositionMs, lyricSeek, model.LyricsLoading, connected: state.ControlsAvailable, compact: true, preferences: preferences);
        expandedLyrics.Update(model.Lyrics, model.LyricsPositionMs, lyricSeek, model.LyricsLoading, connected: state.ControlsAvailable, compact: false, preferences: preferences);
        UiTypography.Apply(RootGrid, preferences);
        MiniTitle.Text = TitleText.Text = state.Title.Length > 0 ? state.Title : L.Text(state.HasMedia ? "正在接收音乐" : "让音乐，连接此刻");
        string metadata = string.Join(" · ", new[] { state.Artist, state.Album }.Where(x => !string.IsNullOrWhiteSpace(x)));
        MiniArtist.Text = ArtistText.Text = metadata.Length > 0 ? metadata : state.HasMedia ? L.Text("来自手机妙播") : L.Text("在手机妙播中选择") + " " + model.Settings.Name;
        StatusText.Text = model.Busy ? L.Text("正在处理…") : L.Text(state.PhaseLabel);
        UpdateCover();
        MiniPlaceholder.Visibility = CoverPlaceholder.Visibility = model.Artwork == null ? Visibility.Visible : Visibility.Collapsed;
        bool legacyExpandedEffects = backdrop.SetArtwork(!compact && !lyricsVisible ? model.ArtworkBytes : null);
        bool expandedLyricEffects = expandedLyricsBackdrop.SetArtwork(!compact && lyricsVisible ? model.ArtworkBytes : null);
        bool expandedEffects = lyricsVisible ? expandedLyricEffects : legacyExpandedEffects;
        bool effects = miniBackdrop.SetArtwork(compact ? model.ArtworkBytes : null);
        loadingBackdrop.SetArtwork(compact && model.ArtworkLoading ? model.ArtworkBytes : null);
        bool miniLyricEffects = lyricsBackdrop.SetArtwork(compact && lyricsVisible ? model.ArtworkBytes : null);
        bool highContrast = accessibility.HighContrast;
        Brush solid = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        ExpandedRoot.Background = highContrast ? solid : lyricsVisible ? lyricFallback : expandedEffects ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 12, 12, 12)) : solid;
        ExpandedRoot.RequestedTheme = !highContrast && (lyricsVisible || expandedEffects) ? ElementTheme.Dark : ElementTheme.Default;
        BackdropShade.Background = lyricsVisible ? expandedLyricEffects ? lyricArtShade : lyricEmptyShade : legacyShade;
        BackdropShade.Visibility = !highContrast && (lyricsVisible || expandedEffects) ? Visibility.Visible : Visibility.Collapsed;
        MiniControls.Background = highContrast ? solid : effects ? null : new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 12, 12, 12));
        MiniRoot.Background = highContrast ? solid : lyricsVisible ? lyricFallback : new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 12, 12, 12));
        MiniRoot.RequestedTheme = highContrast ? ElementTheme.Default : ElementTheme.Dark;
        MiniLyricsGlobalShade.Background = miniLyricEffects ? lyricArtShade : lyricEmptyShade;
        MiniLyricsGlobalShade.Visibility = lyricsVisible && !highContrast ? Visibility.Visible : Visibility.Collapsed;
        foreach (var button in new[] { CloseButton, PinButton, MiniFullScreenButton })
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
        string fullScreenLabel = L.Text(IsFullScreen ? "退出全屏" : "全屏", IsFullScreen ? "Exit Full Screen" : "Full Screen");
        Label(MiniFullScreenButton, fullScreenLabel); Label(ExpandedFullScreenButton, fullScreenLabel); FullScreenMenuItem.Text = fullScreenLabel;
        MiniFullScreenIcon.Glyph = ExpandedFullScreenIcon.Glyph = IsFullScreen ? "\uE73F" : "\uE740";
        Label(PinButton, L.Text(preferences.Pinned ? "取消置顶" : "窗口置顶"));
        PinIcon.Opacity = preferences.Pinned ? 1 : 0.6;
        PinButton.Visibility = preferences.ShowPinButton ? Visibility.Visible : Visibility.Collapsed;
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsAlwaysOnTop = preferences.Pinned && !IsFullScreen;
        bool sectionAnimations = Backdrop.AnimationsEnabled;
        transportTransition.SetVisible(preferences.ShowTransport && !model.MigrationRequired, sectionAnimations && compact);
        expandedTransportTransition.SetVisible(preferences.ShowTransport && !model.MigrationRequired, sectionAnimations && !compact);
        VolumeSlider.IsEnabled = model.Initialized; VolumeSlider.Value = model.Volume;
        AutomationProperties.SetName(VolumeSlider, L.Text("接收音量"));
        AutomationProperties.SetName(MiniCover, L.Text("专辑封面"));
        AutomationProperties.SetName(MiniProgress, L.Text("播放进度"));
        AutomationProperties.SetName(CoverImage, L.Text("专辑封面")); AutomationProperties.SetName(Progress, L.Text("播放进度"));
        bool progress = preferences.ShowProgress && state.HasMedia && state.DurationMs is > 0 && displayPosition != null;
        // Input follows the requested state immediately, while the outgoing
        // visual can remain visible until its fade and height animation finish.
        progressShown = progress;
        foreach (var seek in new[] { ProgressSeek, MiniProgressSeek })
        {
            seek.IsEnabled = progress && model.CanSeek;
            if (!seek.IsEnabled) seek.CancelPointer();
            Label(seek, L.Text("播放进度，点击跳转"));
            AutomationProperties.SetHelpText(seek, L.Text("点击跳转；方向键前后 10 秒，Home 到开头，End 到结尾。"));
            seek.RefreshState();
        }
        ApplyProgressColor(preferences);
        if (progress)
        {
            MiniProgress.Value = Progress.Value = Math.Clamp(100.0 * displayPosition!.Value / state.DurationMs!.Value, 0, 100);
            MiniPosition.Text = PositionText.Text = FormatTime(displayPosition.Value); MiniDuration.Text = DurationText.Text = FormatTime(state.DurationMs.Value);
        }
        progressTransition.SetVisible(progress, sectionAnimations && compact);
        expandedProgressTransition.SetVisible(progress, sectionAnimations && !compact);
        string error = preferenceError.Length > 0 ? preferenceError : model.Error;
        MigrationButton.Content = ExpandedMigrationButton.Content = L.Text("为此电脑建立独立身份");
        MigrationButton.Visibility = ExpandedMigrationButton.Visibility = model.MigrationRequired ? Visibility.Visible : Visibility.Collapsed;
        MiniStatus.Text = ExpandedStatus.Text = L.Text(error.Length > 0 ? error : model.ControlMessage);
        MiniStatus.Visibility = ExpandedStatus.Visibility = MiniStatus.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (compact)
        {
            if (pointerInside || preferences.AlwaysShowControls || WindowSizing.ScreenReaderActive || focusInside || error.Length > 0 || model.MigrationRequired) ShowControls(true);
            else if (!pointerInside) ScheduleHide();
            ShowCaption(pointerInside);
        }
        else if (IsFullScreen) ShowCaption(pointerInside);
        else
        {
            ElementCompositionPreview.GetElementVisual(ExpandedHeader).StopAnimation("Opacity");
            ElementCompositionPreview.GetElementVisual(ExpandedHeader).Opacity = 1; ExpandedHeader.IsHitTestVisible = true; fullscreenCaptionShown = true;
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
        bool wasCompact = compact;
        ApplyPlayerLayout(e.NewSize.Width, e.NewSize.Height);
        bool changed = wasCompact != compact;
        if (changed)
        {
            ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer();
            hideTimer?.Stop(); Render();
            if (compact)
            {
                if (revealMiniRequested || pointerInside) { ShowControls(true); ShowCaption(pointerInside); }
                revealMiniRequested = false; ScheduleHide();
            }
        }
        UpdateBlurCoverage(); UpdateInputRegions();
    }
    private void ApplyPlayerLayout(double width, double height)
    {
        if (width <= 0 || height <= 0) return;
        bool nextCompact = WindowSizing.IsCompactContent(width, height, lyricsVisible);
        if (compact != nextCompact) { ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer(); }
        compact = nextCompact;
        ExpandedRoot.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        MiniRoot.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        MiniCoverRow.Height = lyricsVisible ? new GridLength(width) : new GridLength(1, GridUnitType.Star);
        MiniCoverPanel.Height = lyricsVisible ? width : double.NaN;
        MiniCover.Stretch = MiniPreviousCover.Stretch = lyricsVisible ? Stretch.Uniform : Stretch.UniformToFill;
        MiniLyricsGapRow.Height = new GridLength(lyricsVisible ? 8 : 0);
        MiniLyricsRow.Height = lyricsVisible ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        MiniLyricsHost.Visibility = MiniLyricsDivider.Visibility = lyricsVisible ? Visibility.Visible : Visibility.Collapsed;
        MiniLyricsHost.Padding = new Thickness(width < 320 ? 16 : 22, 0, width < 320 ? 16 : 22, 12);
        ExpandedLyricsHost.Visibility = lyricsVisible ? Visibility.Visible : Visibility.Collapsed;
        MiniTitle.FontSize = lyricsVisible && width < 320 ? 17 : 20; MiniArtist.FontSize = lyricsVisible ? 12 : 14;
        MiniTitle.MaxLines = lyricsVisible ? 1 : 2;

        double side;
        if (lyricsVisible)
        {
            double inset = Math.Clamp(width * .04, 36, 48), vertical = height < 360 ? 20 : 32;
            double column = Math.Min(330, width * .38);
            double reserved = 72 + (model.Preferences.Value.ShowProgress ? 45 : 0) + (model.Preferences.Value.ShowTransport ? 44 : 0);
            side = Math.Max(60, Math.Min(column, height - vertical * 2 - reserved));
            ExpandedContent.Padding = new Thickness(inset, vertical, inset, vertical); ExpandedContent.RowSpacing = 0;
            ExpandedContent.RowDefinitions[0].Height = new GridLength(0);
            Grid.SetRowSpan(ExpandedHeader, 2); Canvas.SetZIndex(ExpandedHeader, 1); ExpandedHeader.VerticalAlignment = VerticalAlignment.Top;
            ExpandedBrand.Visibility = Visibility.Collapsed;
            PlayerLayout.ColumnSpacing = 32; PlayerLayout.RowSpacing = 8; PlayerLayout.VerticalAlignment = VerticalAlignment.Stretch;
            PlayerLayout.ColumnDefinitions[0].Width = new GridLength(column);
            if (PlayerLayout.RowDefinitions.Count != 2)
            {
                PlayerLayout.RowDefinitions.Clear(); PlayerLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                PlayerLayout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            }
            Grid.SetColumn(ExpandedDetails, 0); Grid.SetRow(ExpandedDetails, 1);
            ExpandedDetails.RowSpacing = 4; ExpandedDetails.VerticalAlignment = VerticalAlignment.Top;
            ExpandedDetails.RowDefinitions[0].Height = GridLength.Auto;
            ExpandedMetadata.Spacing = 5; TitleText.FontSize = 20; TitleText.MaxLines = 1; ArtistText.FontSize = 12; ArtistText.MaxLines = 1;
            VolumeRow.Visibility = Visibility.Collapsed;
            PreviousButton.Width = PreviousButton.Height = NextButton.Width = NextButton.Height = 36;
            PlayButton.Width = PlayButton.Height = 44;
        }
        else
        {
            side = Math.Clamp(Math.Min(height - 126, width * .36), 130, 360);
            ExpandedContent.Padding = new Thickness(28, 14, 28, 22); ExpandedContent.RowSpacing = 12;
            ExpandedContent.RowDefinitions[0].Height = GridLength.Auto;
            Grid.SetRowSpan(ExpandedHeader, 1); ExpandedBrand.Visibility = Visibility.Visible;
            PlayerLayout.ColumnSpacing = 28; PlayerLayout.RowSpacing = 0; PlayerLayout.VerticalAlignment = VerticalAlignment.Center;
            PlayerLayout.ColumnDefinitions[0].Width = GridLength.Auto;
            if (PlayerLayout.RowDefinitions.Count > 0) PlayerLayout.RowDefinitions.Clear();
            Grid.SetColumn(ExpandedDetails, 1); Grid.SetRow(ExpandedDetails, 0);
            ExpandedDetails.RowSpacing = 12; ExpandedDetails.VerticalAlignment = VerticalAlignment.Stretch;
            ExpandedDetails.RowDefinitions[0].Height = new GridLength(1, GridUnitType.Star);
            ExpandedMetadata.Spacing = 7; TitleText.FontSize = 25; TitleText.MaxLines = 2; ArtistText.FontSize = 14; ArtistText.MaxLines = 2;
            VolumeRow.Visibility = Visibility.Visible;
            PreviousButton.Width = PreviousButton.Height = NextButton.Width = NextButton.Height = 40;
            PlayButton.Width = PlayButton.Height = 52;
        }
        CoverFrame.Width = CoverFrame.Height = side; CoverFrame.HorizontalAlignment = HorizontalAlignment.Center; CoverFrame.VerticalAlignment = VerticalAlignment.Top;
    }
    private void MiniControls_SizeChanged(object sender, SizeChangedEventArgs e) { UpdateBlurCoverage(); UpdateInputRegions(); }
    private void Root_LayoutUpdated(object? sender, object e) => UpdateInputRegions();
    private void UpdateBlurCoverage() => miniBackdrop?.SetCoverage(MiniCoverPanel.ActualHeight > 0 ? Math.Clamp(MiniControls.ActualHeight * 1.35 / MiniCoverPanel.ActualHeight, .1, 1) : .65);
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
        void Add(FrameworkElement element, FrameworkElement? viewport = null)
        {
            if (element.Visibility != Visibility.Visible || element.ActualWidth <= 0 || element.ActualHeight <= 0) return;
            var bounds = element.TransformToVisual(RootGrid).TransformBounds(new global::Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
            if (viewport != null)
            {
                // A 24-DIP child can exceed its animated section's current
                // height. Route input only through the part actually exposed.
                var clip = viewport.TransformToVisual(RootGrid).TransformBounds(new global::Windows.Foundation.Rect(0, 0, viewport.ActualWidth, viewport.ActualHeight));
                double left = Math.Max(bounds.Left, clip.Left), top = Math.Max(bounds.Top, clip.Top);
                double right = Math.Min(bounds.Right, clip.Right), bottom = Math.Min(bounds.Bottom, clip.Bottom);
                if (right <= left || bottom <= top) return;
                bounds = new global::Windows.Foundation.Rect(left, top, right - left, bottom - top);
            }
            int x = (int)Math.Floor(bounds.Left * scale), y = (int)Math.Floor(bounds.Top * scale);
            rectangles.Add(new(x, y, (int)Math.Ceiling(bounds.Right * scale) - x, (int)Math.Ceiling(bounds.Bottom * scale) - y));
        }
        if (!compact)
        {
            Add(SettingsButton); Add(MiniButton); Add(ExpandedFullScreenButton); Add(ExpandedCloseButton); Add(ExpandedMigrationButton);
            if (VolumeRow.Visibility == Visibility.Visible) Add(VolumeSlider);
            if (lyricsVisible) Add(ExpandedLyricsHost);
            if (progressShown && ProgressPanel.Visibility == Visibility.Visible) Add(ProgressSeek, ProgressPanel);
            if (TransportPanel.Visibility == Visibility.Visible && TransportPanel.ActualHeight > 0) { Add(PreviousButton); Add(PlayButton); Add(NextButton); }
        }
        else
        {
            if (captionShown) { Add(CloseButton); Add(PinButton); Add(MiniFullScreenButton); }
            if (lyricsVisible) Add(MiniLyricsHost);
            if (controlsShown)
            {
                if (progressShown && MiniProgressPanel.Visibility == Visibility.Visible) Add(MiniProgressSeek, MiniProgressPanel);
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
        if (!visible) MiniProgressSeek.CancelPointer();
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
        if (MiniActions == null) return;
        visible |= focusInside || WindowSizing.ScreenReaderActive;
        if (!compact)
        {
            if (!IsFullScreen || visible == fullscreenCaptionShown) return;
            fullscreenCaptionShown = visible; AnimateVisibility(ExpandedHeader, visible, visible ? .60 : .45, visible ? .12 : 0);
            ExpandedHeader.IsHitTestVisible = visible; UpdateInputRegions(); return;
        }
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
    private void SeekRequested(SeekRequest request) => _ = model.SeekAsync(request);
    private void SeekLyric(ulong position)
    {
        if (closed || model.LyricsLoading || !model.CanSeek) return;
        var request = new SeekRequest(position, lyricsTrackId, lyricsTitle);
        if (Seeking.MatchesCurrent(model.State, request)) _ = model.SeekAsync(request);
    }
    public void ToggleFullScreen()
    {
        try { fullScreen.Toggle(); }
        catch (Exception) { preferenceError = L.Text("无法切换全屏，请重试。", "Could not change full screen. Try again."); model.Store.EventDiagnostic("fullscreen_failed"); Render(); }
    }
    private void FullScreen_Click(object sender, RoutedEventArgs e) => ToggleFullScreen();
    private void FullScreenChanged()
    {
        if (closed) return;
        ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer();
        Render(); UpdateInputRegions();
    }
    private async void Migration_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = RootGrid.XamlRoot, Title = L.Text("为此电脑建立独立身份"), Content = L.Text("将保留名称、音量等设置，并备份旧设备身份。此电脑会作为新的接收设备出现在手机上。"), PrimaryButtonText = L.Text("备份并建立"), CloseButtonText = L.Text("取消"), DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await model.MigrateAsync();
    }
}
