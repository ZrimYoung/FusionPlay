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
using System.Runtime.InteropServices;
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
    private readonly Brush charcoal = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 12, 12, 12));
    private readonly Brush captionBackdrop = new SolidColorBrush(global::Windows.UI.Color.FromArgb(100, 20, 20, 20));
    private readonly Brush transparent = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    private readonly ISquareWindow squareSizing;
    private readonly PlayerFullScreen fullScreen;
    private readonly WindowResizeTransition resizeTransition;
    private readonly PlayerLayoutTransition layoutTransition;
    private readonly LyricsView miniLyrics, expandedLyrics;
    private readonly TransportTransition transportTransition, expandedTransportTransition;
    private readonly TransportTransition progressTransition, expandedProgressTransition;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer hideTimer, coverTimer;
    private BitmapImage? lastArtwork;
    private string? progressColorKey;
    private (double Width, double Height, bool Lyrics, bool Progress, bool Transport, double ProgressHeight, double TransportHeight, bool Idle)? appliedLayout;
    private bool? configuredLyricsLayout;
    private bool? requestedLyricsLayout;
    private bool lyricsLayoutTransitioning, contentTransitionDone, nativeTransitionDone, holdExpandedLayout, closeShown = true;
    private long layoutTransitionVersion;
    private bool inputRegionsQueued;
    private bool pointerInside, focusInside, controlsShown = true, captionShown = true, fullscreenCaptionShown = true, progressShown, lyricsVisible, closed, compact = true, rendering = true, revealMiniRequested;
    private string lyricsTrackId = "", lyricsTitle = "";
    private string preferenceError = "";
    private bool animateHiddenLayoutForCheck;
    private bool idle;
    private bool? appliedIdleBackdrop;
    private DesktopAcrylicBackdrop? idleBackdrop;
    internal bool AnimateHiddenLayoutForCheck
    {
        get => animateHiddenLayoutForCheck;
        set
        {
            if (value && !Environment.GetCommandLineArgs().Contains("--lyrics-player-check", StringComparer.Ordinal))
                throw new InvalidOperationException("hidden_layout_check_requires_diagnostic_mode");
            animateHiddenLayoutForCheck = value;
        }
    }
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
            seek.Snapshot = () => model.State with { PositionMs = model.State.HasMedia ? model.DisplayPositionMs : null };
            seek.SeekRequested += SeekRequested;
        }
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = true; presenter.IsMaximizable = false; presenter.IsMinimizable = false;
        }
        WindowSizing.Apply(this, 420, 420, 260, 260);
        squareSizing = WindowSizing.FixedSquare(this, NativeHoverChanged);
        resizeTransition = new WindowResizeTransition(this, squareSizing);
        layoutTransition = new PlayerLayoutTransition(RootGrid,
            [MiniControlsTransitionLayer, ExpandedDetails, MiniLyricsHost, ExpandedLyricsHost],
            [(MiniCoverPanel, true), (CoverFrame, true), (ExpandedDetails, false), (MiniControlsTransitionLayer, false)]);
        squareSizing.MoveSizeStarted += WindowMoveSizeStarted;
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
            CancelLyricsTransition(snapResize: true);
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
            squareSizing.MoveSizeStarted -= WindowMoveSizeStarted; layoutTransition.Dispose(); resizeTransition.Dispose();
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
        CancelLyricsTransition(snapResize: true);
        if (IsFullScreen) fullScreen.Exit();
        revealMiniRequested = true;
        WindowSizing.ResizeContent(this, 420, lyricsVisible ? squareSizing.PreferredLyricsHeight(420) : 420);
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
        string error = preferenceError.Length > 0 ? preferenceError : model.Error;
        bool nextIdle = !model.HasCurrentTrack && !model.MigrationRequired && error.Length == 0;
        if (idle != nextIdle) { idle = nextIdle; appliedLayout = null; }
        ulong? displayPosition = model.DisplayPositionMs;
        RequestLyricsLayout(!idle && LyricsDisplayModes.IsVisible(preferences.LyricsDisplayMode, model.LyricsAvailable));
        squareSizing.SetPlayerLayout(lyricsVisible, IsFullScreen);
        ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
        if (!model.LyricsLoading) { lyricsTrackId = state.TrackId; lyricsTitle = state.Title; }
        bool lyricSeek = model.CanSeek && !model.LyricsLoading && !lyricsLayoutTransitioning;
        miniLyrics.Update(model.Lyrics, model.LyricsPositionMs, lyricSeek, model.LyricsLoading, connected: state.ControlsAvailable, compact: true, preferences: preferences);
        expandedLyrics.Update(model.Lyrics, model.LyricsPositionMs, lyricSeek, model.LyricsLoading, connected: state.ControlsAvailable, compact: false, preferences: preferences);
        UiTypography.Apply(RootGrid, preferences);
        var presentation = model.DisplayMetadata;
        MiniTitle.Text = TitleText.Text = presentation.Title.Length > 0 ? presentation.Title : L.Text(state.HasMedia ? "正在接收音乐" : "让音乐，连接此刻");
        string metadata = string.Join(" · ", new[] { presentation.Artist, presentation.Album }.Where(x => !string.IsNullOrWhiteSpace(x)));
        MiniArtist.Text = ArtistText.Text = metadata.Length > 0 ? metadata : state.HasMedia ? L.Text("来自手机妙播") : L.Text("在手机妙播中选择") + " " + model.Settings.Name;
        StatusText.Text = model.Busy ? L.Text("正在处理…") : L.Text(state.PhaseLabel);
        UpdateCover();
        MiniPlaceholder.Visibility = CoverPlaceholder.Visibility = !idle && model.Artwork == null ? Visibility.Visible : Visibility.Collapsed;
        MiniCover.Visibility = MiniPreviousCover.Visibility = CoverImage.Visibility = PreviousCoverImage.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        bool legacyExpandedEffects = backdrop.SetArtwork(!idle && !compact && !lyricsVisible ? model.ArtworkBytes : null);
        bool expandedLyricEffects = expandedLyricsBackdrop.SetArtwork(!idle && !compact && lyricsVisible ? model.ArtworkBytes : null);
        bool expandedEffects = lyricsVisible ? expandedLyricEffects : legacyExpandedEffects;
        bool effects = miniBackdrop.SetArtwork(!idle && compact ? model.ArtworkBytes : null);
        loadingBackdrop.SetArtwork(!idle && compact && model.ArtworkLoading ? model.ArtworkBytes : null);
        bool miniLyricEffects = lyricsBackdrop.SetArtwork(!idle && compact && lyricsVisible ? model.ArtworkBytes : null);
        bool highContrast = accessibility.HighContrast;
        Brush solid = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        bool idleAcrylic = UpdateIdleBackdrop(idle && !highContrast);
        Brush idleBackground = idleAcrylic ? transparent : solid;
        RootGrid.Background = idle ? idleBackground : solid;
        ExpandedRoot.Background = highContrast ? solid : lyricsVisible ? lyricFallback : expandedEffects ? charcoal : solid;
        ExpandedRoot.RequestedTheme = !highContrast && (lyricsVisible || expandedEffects) ? ElementTheme.Dark : ElementTheme.Default;
        BackdropShade.Background = lyricsVisible ? expandedLyricEffects ? lyricArtShade : lyricEmptyShade : legacyShade;
        BackdropShade.Visibility = !idle && !highContrast && (lyricsVisible || expandedEffects) ? Visibility.Visible : Visibility.Collapsed;
        MiniControls.Background = highContrast ? solid : effects ? null : charcoal;
        MiniRoot.Background = highContrast ? solid : lyricsVisible ? lyricFallback : charcoal;
        MiniRoot.RequestedTheme = highContrast ? ElementTheme.Default : ElementTheme.Dark;
        MiniLyricsGlobalShade.Background = miniLyricEffects ? lyricArtShade : lyricEmptyShade;
        MiniLyricsGlobalShade.Visibility = !idle && lyricsVisible && !highContrast ? Visibility.Visible : Visibility.Collapsed;
        foreach (var button in new[] { CloseButton, PinButton, MiniFullScreenButton })
            button.Background = effects || idleAcrylic ? captionBackdrop : solid;
        MiniShade.Visibility = effects ? Visibility.Visible : Visibility.Collapsed;
        if (idle) ExpandedRoot.Background = MiniRoot.Background = idleBackground;
        IdlePlaceholder.Visibility = idle ? Visibility.Visible : Visibility.Collapsed;
        PlayerLayout.Visibility = ExpandedFooter.Visibility = MiniControlsTransitionLayer.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        ExpandedBrand.Visibility = !idle && !lyricsVisible ? Visibility.Visible : Visibility.Collapsed;
        MiniPreviousButton.IsEnabled = MiniPlayButton.IsEnabled = MiniNextButton.IsEnabled = PreviousButton.IsEnabled = PlayButton.IsEnabled = NextButton.IsEnabled = model.CanControl && !lyricsLayoutTransitioning;
        PlaybackIcons.Update(MiniPreviousIcon, PlaybackCommand.Previous);
        PlaybackIcons.Update(MiniNextIcon, PlaybackCommand.Next);
        PlaybackIcons.Update(MiniPlayIcon, state.Phase == ReceiverPhase.Playing ? PlaybackCommand.Pause : PlaybackCommand.Play);
        PlaybackIcons.Update(PreviousIcon, PlaybackCommand.Previous); PlaybackIcons.Update(NextIcon, PlaybackCommand.Next);
        PlaybackIcons.Update(PlayIcon, state.Phase == ReceiverPhase.Playing ? PlaybackCommand.Pause : PlaybackCommand.Play);
        Label(MiniPlayButton, L.Text(state.Phase == ReceiverPhase.Playing ? "暂停" : "播放"));
        Label(MiniPreviousButton, L.Text("上一曲")); Label(MiniNextButton, L.Text("下一曲"));
        Label(PreviousButton, L.Text("上一曲")); Label(NextButton, L.Text("下一曲")); Label(PlayButton, L.Text(state.Phase == ReceiverPhase.Playing ? "暂停" : "播放"));
        Label(SettingsButton, L.Text("设置")); Label(ExpandedCloseButton, L.Text("关闭窗口", "Close Window"));
        SettingsButton.Visibility = !idle && preferences.ShowSettingsButton ? Visibility.Visible : Visibility.Collapsed;
        MiniFullScreenButton.Visibility = ExpandedFullScreenButton.Visibility = preferences.ShowFullScreenButton ? Visibility.Visible : Visibility.Collapsed;
        Label(CloseButton, L.Text("关闭窗口", "Close Window"));
        string fullScreenLabel = L.Text(IsFullScreen ? "退出全屏" : "全屏", IsFullScreen ? "Exit Full Screen" : "Full Screen");
        Label(MiniFullScreenButton, fullScreenLabel); Label(ExpandedFullScreenButton, fullScreenLabel); FullScreenMenuItem.Text = fullScreenLabel;
        MiniFullScreenIcon.Glyph = ExpandedFullScreenIcon.Glyph = IsFullScreen ? "\uE73F" : "\uE740";
        Label(PinButton, L.Text(preferences.Pinned ? "取消置顶" : "窗口置顶"));
        PinIcon.Opacity = preferences.Pinned ? 1 : 0.6;
        PinButton.Visibility = !idle && preferences.ShowPinButton ? Visibility.Visible : Visibility.Collapsed;
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsAlwaysOnTop = preferences.Pinned && !IsFullScreen;
        bool sectionAnimations = Backdrop.AnimationsEnabled;
        transportTransition.SetVisible(!idle && preferences.ShowTransport && !model.MigrationRequired, sectionAnimations && compact && !idle);
        expandedTransportTransition.SetVisible(!idle && preferences.ShowTransport && !model.MigrationRequired, sectionAnimations && !compact && !idle);
        VolumeSlider.IsEnabled = model.Initialized && !lyricsLayoutTransitioning; VolumeSlider.Value = model.Volume;
        AutomationProperties.SetName(VolumeSlider, L.Text("接收音量"));
        AutomationProperties.SetName(MiniCover, L.Text("专辑封面"));
        AutomationProperties.SetName(MiniProgress, L.Text("播放进度"));
        AutomationProperties.SetName(CoverImage, L.Text("专辑封面")); AutomationProperties.SetName(Progress, L.Text("播放进度"));
        // Sender metadata can arrive in several observations while changing a
        // track. Keep the user's chosen slot stable; data availability controls
        // only its contents and interaction, never the section's layout.
        bool progress = !idle && preferences.ShowProgress && !model.MigrationRequired;
        ulong? position = state.HasMedia ? displayPosition : null;
        ulong? duration = state.HasMedia && state.DurationMs is > 0 ? state.DurationMs : null;
        bool timelineAvailable = position != null && duration != null;
        // Input follows the requested state immediately, while the outgoing
        // visual can remain visible until its fade and height animation finish.
        progressShown = progress;
        foreach (var seek in new[] { ProgressSeek, MiniProgressSeek })
        {
            seek.IsEnabled = progress && timelineAvailable && model.CanSeek && !lyricsLayoutTransitioning;
            if (!seek.IsEnabled) seek.CancelPointer();
            Label(seek, L.Text("播放进度，点击跳转"));
            AutomationProperties.SetHelpText(seek, L.Text("点击跳转；方向键前后 10 秒，Home 到开头，End 到结尾。"));
            seek.RefreshState();
        }
        ApplyProgressColor(preferences);
        MiniProgress.Value = Progress.Value = timelineAvailable ? Math.Clamp(100.0 * position!.Value / duration!.Value, 0, 100) : 0;
        MiniPosition.Text = PositionText.Text = position is { } current ? FormatTime(current) : "--:--";
        MiniDuration.Text = DurationText.Text = duration is { } total ? FormatTime(total) : "--:--";
        progressTransition.SetVisible(progress, sectionAnimations && compact && !idle);
        expandedProgressTransition.SetVisible(progress, sectionAnimations && !compact && !idle);
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
        ShowClose(pointerInside);
        ExpandedDetails.IsHitTestVisible = MiniControlsTransitionLayer.IsHitTestVisible = MiniLyricsHost.IsHitTestVisible = ExpandedLyricsHost.IsHitTestVisible = !lyricsLayoutTransitioning;
        // Requested visibility disables native input holes synchronously; layout
        // callbacks still coalesce the later geometry updates during animations.
        UpdateBlurCoverage(); UpdateInputRegions(); rendering = false;
    }
    private bool UpdateIdleBackdrop(bool enabled)
    {
        if (appliedIdleBackdrop == enabled) return enabled && SystemBackdrop is DesktopAcrylicBackdrop;
        appliedIdleBackdrop = enabled;
        if (!enabled) { SystemBackdrop = null; return false; }
        try
        {
            // The native acrylic controller follows transparency, activation
            // and system fallback colors. No album image is used in idle mode.
            idleBackdrop ??= new DesktopAcrylicBackdrop(); SystemBackdrop = idleBackdrop;
            return true;
        }
        catch (Exception error) when (error is COMException or NotSupportedException or InvalidOperationException)
        { SystemBackdrop = null; return false; }
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
    private void RequestLyricsLayout(bool visible)
    {
        bool animate = RootGrid.IsLoaded && (AppWindow.IsVisible || AnimateHiddenLayoutForCheck) && Backdrop.AnimationsEnabled;
        if (requestedLyricsLayout == visible)
        {
            if (lyricsLayoutTransitioning && !animate) CancelLyricsTransition(snapResize: true);
            return;
        }
        bool first = requestedLyricsLayout == null;
        if (lyricsVisible && !visible) squareSizing.RememberLyricsPaneHeight();
        requestedLyricsLayout = visible;
        if (first) { lyricsVisible = visible; return; }
        if (!animate)
        {
            CancelLyricsTransition(snapResize: false);
            lyricsVisible = visible; appliedLayout = null;
            squareSizing.SetLayoutTransition(true); squareSizing.SetPlayerLayout(visible, IsFullScreen);
            resizeTransition.AnimateLyrics(visible, false, () => { });
            return;
        }

        long request = ++layoutTransitionVersion;
        lyricsLayoutTransitioning = true; contentTransitionDone = nativeTransitionDone = false;
        holdExpandedLayout = RootGrid.ActualWidth >= 600 && !compact;
        ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer();
        ProgressSeek.IsEnabled = MiniProgressSeek.IsEnabled = false;
        ExpandedDetails.IsHitTestVisible = MiniControlsTransitionLayer.IsHitTestVisible = MiniLyricsHost.IsHitTestVisible = ExpandedLyricsHost.IsHitTestVisible = false;
        // The mini cover stays square while the native client height changes.
        // Otherwise closing lyrics would stretch it to the old tall window.
        appliedLayout = null; ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
        UpdateInputRegions();
        resizeTransition.AnimateLyrics(visible, true, () =>
        {
            if (closed || request != layoutTransitionVersion) return;
            nativeTransitionDone = true; CompleteLyricsTransition(request);
        });
        layoutTransition.Run(() =>
        {
            if (closed || request != layoutTransitionVersion) return;
            lyricsVisible = visible; appliedLayout = null;
            squareSizing.SetPlayerLayout(visible, IsFullScreen); Render();
        }, () =>
        {
            if (closed || request != layoutTransitionVersion) return;
            contentTransitionDone = true; CompleteLyricsTransition(request);
        }, true);
    }
    private void CompleteLyricsTransition(long request)
    {
        if (closed || request != layoutTransitionVersion || !contentTransitionDone || !nativeTransitionDone) return;
        lyricsLayoutTransitioning = holdExpandedLayout = false; appliedLayout = null;
        squareSizing.SetLayoutTransition(false); Render();
    }
    private void CancelLyricsTransition(bool snapResize)
    {
        if (!lyricsLayoutTransitioning) return;
        ++layoutTransitionVersion;
        layoutTransition.Cancel(); resizeTransition.Cancel(snapResize);
        lyricsLayoutTransitioning = holdExpandedLayout = false;
        lyricsVisible = requestedLyricsLayout ?? lyricsVisible; appliedLayout = null;
        squareSizing.SetPlayerLayout(lyricsVisible, IsFullScreen); squareSizing.SetLayoutTransition(false);
        // Closing to the tray and requesting mini mode can both happen while
        // paused, with no later receiver notification to restore interaction.
        // An enclosing Render already performs this restoration itself.
        if (!closed && !rendering) Render();
    }
    private void WindowMoveSizeStarted()
    { if (!closed && lyricsLayoutTransitioning) CancelLyricsTransition(snapResize: false); }
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
        UpdateBlurCoverage(); QueueInputRegions();
    }
    private void ApplyPlayerLayout(double width, double height)
    {
        if (width <= 0 || height <= 0) return;
        var preferences = model.Preferences.Value;
        // A fading section still occupies its animated row until it collapses.
        // Do not enlarge the cover from the requested preference ahead of that
        // actual space being released, especially in short wide windows.
        double progressHeight = Math.Max(preferences.ShowProgress ? 45 : 0,
            ProgressPanel.Visibility == Visibility.Visible ? ProgressPanel.ActualHeight : 0);
        double transportHeight = Math.Max(preferences.ShowTransport ? 44 : 0,
            TransportPanel.Visibility == Visibility.Visible ? TransportPanel.ActualHeight : 0);
        var layout = (width, height, lyricsVisible, preferences.ShowProgress, preferences.ShowTransport, progressHeight, transportHeight, idle);
        if (appliedLayout is { } previousLayout && previousLayout == layout) return;
        appliedLayout = layout;
        bool configure = configuredLyricsLayout != lyricsVisible;
        configuredLyricsLayout = lyricsVisible;
        bool nextCompact = !holdExpandedLayout && WindowSizing.IsCompactContent(width, height, lyricsVisible);
        if (compact != nextCompact) { ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer(); }
        compact = nextCompact;
        ExpandedRoot.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        MiniRoot.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        bool squareCover = lyricsVisible || lyricsLayoutTransitioning;
        MiniCoverRow.Height = squareCover ? new GridLength(width) : new GridLength(1, GridUnitType.Star);
        MiniCoverPanel.Height = squareCover ? width : double.NaN;
        MiniCover.Stretch = MiniPreviousCover.Stretch = lyricsVisible ? Stretch.Uniform : Stretch.UniformToFill;
        MiniLyricsGapRow.Height = new GridLength(lyricsVisible ? 8 : 0);
        MiniLyricsRow.Height = lyricsVisible ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        MiniLyricsHost.Visibility = lyricsVisible && !idle ? Visibility.Visible : Visibility.Collapsed;
        MiniLyricsHost.Padding = new Thickness(width < 320 ? 16 : 22, 0, width < 320 ? 16 : 22, 12);
        ExpandedLyricsHost.Visibility = lyricsVisible && !idle ? Visibility.Visible : Visibility.Collapsed;
        MiniTitle.FontSize = width < 320 ? 17 : 20; MiniArtist.FontSize = 14;
        MiniTitle.MaxLines = lyricsVisible ? 1 : 2;

        double side;
        if (lyricsVisible)
        {
            double inset = Math.Max(24, width * .065), vertical = Math.Clamp(height * .055, 20, 64);
            double gap = width * .045;
            double column = Math.Max(1, (width - inset * 2 - gap) * .42);
            double reserved = 76 + progressHeight + transportHeight;
            side = Math.Max(60, Math.Min(column, height - vertical * 2 - reserved));
            ExpandedContent.Padding = new Thickness(inset, vertical, inset, vertical);
            PlayerLayout.ColumnDefinitions[0].Width = new GridLength(column);
            if (configure)
            {
                ExpandedContent.RowSpacing = 0; ExpandedContent.RowDefinitions[0].Height = new GridLength(0);
                Grid.SetRowSpan(ExpandedHeader, 2); Canvas.SetZIndex(ExpandedHeader, 1); ExpandedHeader.VerticalAlignment = VerticalAlignment.Top;
                ExpandedBrand.Visibility = Visibility.Collapsed;
                PlayerLayout.RowSpacing = 0; PlayerLayout.VerticalAlignment = VerticalAlignment.Stretch;
                // Mac's expanded HStack centers the complete cover/metadata/control
                // column, independently of the full-height lyric viewport.
                PlayerLayout.RowDefinitions.Clear();
                PlayerLayout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
                PlayerLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                PlayerLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                PlayerLayout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
                Grid.SetRow(CoverFrame, 1); Grid.SetColumn(ExpandedDetails, 0); Grid.SetRow(ExpandedDetails, 2);
                Grid.SetRow(ExpandedLyricsHost, 0); Grid.SetRowSpan(ExpandedLyricsHost, 4);
                ExpandedDetails.RowSpacing = 0; ExpandedDetails.VerticalAlignment = VerticalAlignment.Top;
                ExpandedDetails.Margin = new Thickness(0, 14, 0, 0); ExpandedMetadata.Margin = new Thickness(0, 0, 0, 10);
                ExpandedDetails.RowDefinitions[0].Height = GridLength.Auto;
                ExpandedMetadata.Spacing = 5; TitleText.FontSize = 20; TitleText.MaxLines = 1; ArtistText.FontSize = 14; ArtistText.MaxLines = 1;
                VolumeRow.Visibility = Visibility.Collapsed;
                PreviousButton.Width = PreviousButton.Height = NextButton.Width = NextButton.Height = 36;
                PlayButton.Width = PlayButton.Height = 44;
            }
            PlayerLayout.ColumnSpacing = gap;
        }
        else
        {
            side = Math.Clamp(Math.Min(height - 126, width * .36), 130, 360);
            if (configure)
            {
                ExpandedContent.Padding = new Thickness(28, 14, 28, 22); ExpandedContent.RowSpacing = 12;
                ExpandedContent.RowDefinitions[0].Height = GridLength.Auto;
                Grid.SetRowSpan(ExpandedHeader, 1); ExpandedBrand.Visibility = Visibility.Visible;
                PlayerLayout.ColumnSpacing = 28; PlayerLayout.RowSpacing = 0; PlayerLayout.VerticalAlignment = VerticalAlignment.Center;
                PlayerLayout.ColumnDefinitions[0].Width = GridLength.Auto; PlayerLayout.RowDefinitions.Clear();
                Grid.SetRow(CoverFrame, 0); Grid.SetColumn(ExpandedDetails, 1); Grid.SetRow(ExpandedDetails, 0);
                Grid.SetRow(ExpandedLyricsHost, 0); Grid.SetRowSpan(ExpandedLyricsHost, 1);
                ExpandedDetails.RowSpacing = 12; ExpandedDetails.VerticalAlignment = VerticalAlignment.Stretch;
                ExpandedDetails.Margin = ExpandedMetadata.Margin = new Thickness(0);
                ExpandedDetails.RowDefinitions[0].Height = new GridLength(1, GridUnitType.Star);
                ExpandedMetadata.Spacing = 7; TitleText.FontSize = 20; TitleText.MaxLines = 2; ArtistText.FontSize = 14; ArtistText.MaxLines = 2;
                VolumeRow.Visibility = Visibility.Visible;
                PreviousButton.Width = PreviousButton.Height = NextButton.Width = NextButton.Height = 40;
                PlayButton.Width = PlayButton.Height = 52;
            }
        }
        CoverFrame.Width = CoverFrame.Height = side; CoverFrame.HorizontalAlignment = HorizontalAlignment.Center; CoverFrame.VerticalAlignment = VerticalAlignment.Top;
    }
    private void MiniControls_SizeChanged(object sender, SizeChangedEventArgs e) { UpdateBlurCoverage(); QueueInputRegions(); }
    private void Root_LayoutUpdated(object? sender, object e)
    {
        // This is a cached comparison, not a forced layout pass. Natural
        // section-height ticks also release the corresponding cover budget.
        if (!closed && lyricsVisible && !compact) ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
        QueueInputRegions();
    }
    private void QueueInputRegions()
    {
        if (closed || inputRegionsQueued) return;
        inputRegionsQueued = DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            inputRegionsQueued = false;
            if (!closed) UpdateInputRegions();
        });
    }
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
            for (DependencyObject? current = element; current != null; current = VisualTreeHelper.GetParent(current))
            {
                if (current is UIElement { IsHitTestVisible: false } or UIElement { Visibility: Visibility.Collapsed }) return;
                if (ReferenceEquals(current, RootGrid)) break;
            }
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
            Add(SettingsButton); Add(ExpandedFullScreenButton); if (closeShown) Add(ExpandedCloseButton);
            if (!lyricsLayoutTransitioning && !idle)
            {
                Add(ExpandedMigrationButton);
                if (VolumeRow.Visibility == Visibility.Visible) Add(VolumeSlider);
                if (lyricsVisible) Add(ExpandedLyricsHost);
                if (progressShown && ProgressPanel.Visibility == Visibility.Visible) Add(ProgressSeek, ProgressPanel);
                if (TransportPanel.Visibility == Visibility.Visible && TransportPanel.ActualHeight > 0) { Add(PreviousButton); Add(PlayButton); Add(NextButton); }
            }
        }
        else
        {
            if (captionShown) { if (closeShown) Add(CloseButton); Add(PinButton); Add(MiniFullScreenButton); }
            if (!lyricsLayoutTransitioning && !idle && lyricsVisible) Add(MiniLyricsHost);
            if (!lyricsLayoutTransitioning && !idle && controlsShown)
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
        ShowClose(pointerInside);
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
    private void ShowClose(bool visible)
    {
        if (CloseButton == null || visible == closeShown) return;
        closeShown = visible;
        foreach (var button in new[] { CloseButton, ExpandedCloseButton })
        {
            AnimateVisibility(button, visible, visible ? .25 : .20, 0);
            button.IsHitTestVisible = visible; button.IsTabStop = visible;
        }
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
    private void SeekRequested(SeekRequest request) { if (!lyricsLayoutTransitioning) _ = model.SeekAsync(request); }
    private void SeekLyric(ulong position)
    {
        if (closed || lyricsLayoutTransitioning || model.LyricsLoading || !model.CanSeek) return;
        var request = new SeekRequest(position, lyricsTrackId, lyricsTitle);
        if (Seeking.MatchesCurrent(model.State, request)) _ = model.SeekAsync(request);
    }
    public void ToggleFullScreen()
    {
        try { CancelLyricsTransition(snapResize: true); squareSizing.RememberLyricsPaneHeight(); fullScreen.Toggle(); }
        catch (Exception) { preferenceError = L.Text("无法切换全屏，请重试。", "Could not change full screen. Try again."); model.Store.EventDiagnostic("fullscreen_failed"); Render(); }
    }
    private void FullScreen_Click(object sender, RoutedEventArgs e) => ToggleFullScreen();
    private void FullScreenChanged()
    {
        if (closed) return;
        CancelLyricsTransition(snapResize: false);
        ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer();
        Render(); UpdateInputRegions();
    }
    private async void Migration_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = RootGrid.XamlRoot, Title = L.Text("为此电脑建立独立身份"), Content = L.Text("将保留名称、音量等设置，并备份旧设备身份。此电脑会作为新的接收设备出现在手机上。"), PrimaryButtonText = L.Text("备份并建立"), CloseButtonText = L.Text("取消"), DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await model.MigrateAsync();
    }
}
