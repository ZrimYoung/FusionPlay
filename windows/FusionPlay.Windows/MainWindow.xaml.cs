using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using System.Globalization;
using System.Numerics;
using System.Runtime.InteropServices;
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
    private readonly Backdrop backdrop, miniBackdrop, loadingBackdrop, lyricsBackdrop, expandedLyricsBackdrop, sceneBackdrop;
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
    private readonly PlayerAcrylic acrylic;
    private readonly WindowResizeTransition resizeTransition;
    private readonly PlayerLayoutTransition layoutTransition;
    private readonly CompactLyricsPager miniPager;
    private readonly LyricsView miniLyrics, expandedLyrics;
    private readonly TransportTransition transportTransition, expandedTransportTransition;
    private readonly TransportTransition progressTransition, expandedProgressTransition;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer hideTimer, coverTimer;
    private BitmapImage? lastArtwork;
    private string? progressColorKey;
    private (double Width, double Height, bool Lyrics, bool Progress, bool Transport, double ProgressHeight, double TransportHeight,
        double MetadataHeight, bool WrapMetadata, bool FullScreen, bool Idle, bool Paged, bool Stacked, bool Album)? appliedLayout;
    private bool? configuredLyricsLayout, configuredMiniLyricsLayout;
    private bool presenterTransitionPending, geometryCommitQueued;
    private long geometryQueuedVersion;
    private bool? requestedLyricsLayout;
    private (ReceiverSnapshot Track, string Mode, bool Visible)? currentLyricsOverride;
    private (bool Available, bool Visible, bool Paged, bool LyricsPage, string Language)? lyricsTogglePresentation;
    private bool coverLyricsResizing, coverResizeExpanded;
    private bool lyricsLayoutTransitioning, contentTransitionDone, nativeTransitionDone, holdExpandedLayout;
    private bool? windowActionsShown;
    private long layoutTransitionVersion;
    private bool inputRegionsQueued;
    private bool interactiveResize;
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
        acrylic = new PlayerAcrylic(this);
        var coverClip = new RectangleGeometry { Rect = new global::Windows.Foundation.Rect(0, 0, MiniCoverPanel.ActualWidth, MiniCoverPanel.ActualHeight) }; MiniCoverPanel.Clip = coverClip;
        MiniCoverPanel.SizeChanged += (_, args) => coverClip.Rect = new global::Windows.Foundation.Rect(0, 0, args.NewSize.Width, args.NewSize.Height);
        miniLyrics = new LyricsView(); expandedLyrics = new LyricsView();
        MiniLyricsHost.Children.Insert(0, miniLyrics); Grid.SetRow(miniLyrics, 1);
        ExpandedLyricsHost.Children.Add(expandedLyrics);
        miniPager = new CompactLyricsPager(MiniRoot, MiniCoverPanel, MiniLyricsHost, MiniLyricsToggleButton,
            () => !closed && compact && !idle && !interactiveResize && !lyricsLayoutTransitioning && !presenterTransitionPending && !MiniProgressSeek.PointerSeekActive,
            () => CanAnimateLayout && !WindowSizing.ScreenReaderActive, MiniPageChanged);
        miniLyrics.SeekRequested += SeekLyric; expandedLyrics.SeekRequested += SeekLyric;
        foreach (var seek in new[] { ProgressSeek, MiniProgressSeek })
        {
            // Only the presentation position can be pending; track identity,
            // duration and command validation always retain source metadata.
            seek.Snapshot = () => model.State with { PositionMs = model.State.HasMedia ? model.DisplayPositionMs : null };
            seek.SeekRequested += SeekRequested;
            seek.PointerPreviewChanged += UpdateScrubPreview;
            seek.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) =>
            {
                miniLyrics.CancelFollowAnimation();
                expandedLyrics.CancelFollowAnimation();
            }), true);
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
            [(MiniArtworkLayer, true), (CoverFrame, true), (ExpandedDetails, false), (MiniControlsTransitionLayer, false)],
            [MiniRoot, ExpandedRoot], () => compact ? MiniRoot : ExpandedRoot,
            [(MiniArtworkLayer, CoverFrame), (MiniControlsTransitionLayer, ExpandedDetails)], ClientFrame);
        squareSizing.MoveSizeStarted += WindowMoveSizeStarted;
        squareSizing.ResizeStarted += WindowResizeStarted;
        squareSizing.MoveSizeEnded += WindowMoveSizeEnded;
        squareSizing.CoverLyricsResizeStarted += CoverLyricsResizeStarted;
        squareSizing.CoverLyricsResizeExpanded += CoverLyricsResizeExpanded;
        squareSizing.CoverLyricsResizeCompleted += CoverLyricsResizeCompleted;
        squareSizing.CoverLyricsResizeCanceled += CoverLyricsResizeCanceled;
        fullScreen = new PlayerFullScreen(this, () => model.Preferences.Value.Pinned,
            active => SetNativePlayerLayout(lyricsVisible, active));
        fullScreen.Changed += FullScreenChanged;
        fullScreen.Changing += FullScreenChanging;
        transportTransition = new TransportTransition(MiniTransport);
        expandedTransportTransition = new TransportTransition(TransportPanel, 52);
        progressTransition = new TransportTransition(MiniProgressPanel, 48, clipToBounds: true);
        expandedProgressTransition = new TransportTransition(ProgressPanel, 48, clipToBounds: true);
        AttachVolume(VolumeSlider, model);
        RootGrid.Loaded += (_, _) => { UiTypography.Apply(RootGrid, model.Preferences.Value, force: true); UpdateInputRegions(); layoutTransition.Remember(); };
        RootGrid.LayoutUpdated += Root_LayoutUpdated;
        AppWindow.Changed += WindowFrameChanged;
        WindowSizing.ResizeContent(this, 420, 420);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Closing += (_, args) =>
        {
            miniPager.FinishInteraction();
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
        sceneBackdrop = new Backdrop(SceneBackingLayer, blur: 48);
        backdrop.Changed += Render; miniBackdrop.Changed += Render; loadingBackdrop.Changed += Render;
        backdrop.Failed += LogBackdropFailure; miniBackdrop.Failed += LogBackdropFailure; loadingBackdrop.Failed += LogBackdropFailure;
        lyricsBackdrop.Changed += Render; lyricsBackdrop.Failed += LogBackdropFailure;
        expandedLyricsBackdrop.Changed += Render; expandedLyricsBackdrop.Failed += LogBackdropFailure;
        sceneBackdrop.Changed += Render; sceneBackdrop.Failed += LogBackdropFailure;
        appearance.ColorValuesChanged += ContrastChanged;
        appearance.AdvancedEffectsEnabledChanged += ContrastChanged;
        hideTimer = DispatcherQueue.CreateTimer(); hideTimer.IsRepeating = false;
        hideTimer.Interval = TimeSpan.FromMilliseconds(400);
        hideTimer.Tick += (_, _) =>
        {
            if (compact && !pointerInside && !focusInside && !MiniProgressSeek.PointerSeekActive)
            { ShowControls(false); ShowCaption(false); }
        };
        coverTimer = DispatcherQueue.CreateTimer(); coverTimer.IsRepeating = false;
        coverTimer.Interval = TimeSpan.FromMilliseconds(400);
        coverTimer.Tick += (_, _) => { MiniPreviousCover.Source = null; PreviousCoverImage.Source = null; };
        var shortcut = new KeyboardAccelerator { Key = (VirtualKey)0xBC, Modifiers = VirtualKeyModifiers.Control };
        shortcut.Invoked += (_, args) => { openSettings(); args.Handled = true; };
        RootGrid.KeyboardAccelerators.Add(shortcut);
        foreach (var key in new[] { new KeyboardAccelerator { Key = VirtualKey.F11 }, new KeyboardAccelerator { Key = VirtualKey.F, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift } })
        { key.Invoked += (_, args) => { ToggleFullScreen(); args.Handled = true; }; RootGrid.KeyboardAccelerators.Add(key); }
        var lyricsKey = new KeyboardAccelerator { Key = VirtualKey.L, Modifiers = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift };
        lyricsKey.Invoked += (_, args) => args.Handled = ToggleCurrentLyrics();
        RootGrid.KeyboardAccelerators.Add(lyricsKey);
        var escape = new KeyboardAccelerator { Key = VirtualKey.Escape };
        escape.Invoked += (_, args) => { if (IsFullScreen) { ToggleFullScreen(); args.Handled = true; } };
        RootGrid.KeyboardAccelerators.Add(escape);
        foreach (var direction in new[] { VirtualKey.Left, VirtualKey.Right })
        {
            var pageKey = new KeyboardAccelerator { Key = direction, Modifiers = VirtualKeyModifiers.Control };
            pageKey.Invoked += (_, args) => args.Handled = miniPager.Navigate(direction == VirtualKey.Right);
            RootGrid.KeyboardAccelerators.Add(pageKey);
        }
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
            expandedLyricsBackdrop.Changed -= Render; expandedLyricsBackdrop.Failed -= LogBackdropFailure; appearance.ColorValuesChanged -= ContrastChanged; appearance.AdvancedEffectsEnabledChanged -= ContrastChanged;
            sceneBackdrop.Changed -= Render; sceneBackdrop.Failed -= LogBackdropFailure;
            miniLyrics.SeekRequested -= SeekLyric; expandedLyrics.SeekRequested -= SeekLyric;
            miniPager.Dispose(); miniLyrics.Dispose(); expandedLyrics.Dispose(); fullScreen.Changed -= FullScreenChanged; fullScreen.Changing -= FullScreenChanging; fullScreen.Dispose(); acrylic.Dispose();
            squareSizing.MoveSizeStarted -= WindowMoveSizeStarted;
            squareSizing.ResizeStarted -= WindowResizeStarted;
            squareSizing.MoveSizeEnded -= WindowMoveSizeEnded;
            squareSizing.CoverLyricsResizeStarted -= CoverLyricsResizeStarted;
            squareSizing.CoverLyricsResizeExpanded -= CoverLyricsResizeExpanded;
            squareSizing.CoverLyricsResizeCompleted -= CoverLyricsResizeCompleted;
            squareSizing.CoverLyricsResizeCanceled -= CoverLyricsResizeCanceled;
            layoutTransition.Dispose(); resizeTransition.Dispose();
            RootGrid.LayoutUpdated -= Root_LayoutUpdated;
            AppWindow.Changed -= WindowFrameChanged;
            ProgressSeek.SeekRequested -= SeekRequested; MiniProgressSeek.SeekRequested -= SeekRequested;
            ProgressSeek.PointerPreviewChanged -= UpdateScrubPreview; MiniProgressSeek.PointerPreviewChanged -= UpdateScrubPreview;
            hideTimer.Stop(); coverTimer.Stop(); transportTransition.Dispose(); expandedTransportTransition.Dispose(); progressTransition.Dispose(); expandedProgressTransition.Dispose(); squareSizing.Dispose(); backdrop.Dispose(); miniBackdrop.Dispose(); loadingBackdrop.Dispose(); lyricsBackdrop.Dispose(); expandedLyricsBackdrop.Dispose(); sceneBackdrop.Dispose();
        };
        Render(); ScheduleHide();
    }
    private void LogBackdropFailure(string code) => model.Store.EventDiagnostic("backdrop:" + code);
    [StructLayout(LayoutKind.Sequential)] private struct ClientPoint { public int X, Y; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ClientToScreen(nint window, ref ClientPoint point);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    private (global::Windows.Foundation.Point Origin, double Scale) ClientFrame()
    {
        nint handle = WinRT.Interop.WindowNative.GetWindowHandle(this); var point = new ClientPoint();
        ClientToScreen(handle, ref point);
        return (new(point.X, point.Y), Math.Max(96, GetDpiForWindow(handle)) / 96.0);
    }
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
        double height = model.Preferences.Value.NarrowPlayerLayout == "album" ? Math.Max(260, RootGrid.ActualHeight)
            : StackedLyrics(lyricsVisible, 420, false) ? squareSizing.PreferredLyricsHeight(420) : 420;
        WindowSizing.ResizeContent(this, 420, height);
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
        if (closed || presenterTransitionPending || miniBackdrop == null || backdrop == null || sceneBackdrop == null) return;
        rendering = true;
        var state = model.State; var preferences = model.Preferences.Value;
        string error = preferenceError.Length > 0 ? preferenceError : model.Error;
        bool nextIdle = !model.HasCurrentTrack && !model.MigrationRequired && error.Length == 0;
        if (idle != nextIdle) { idle = nextIdle; appliedLayout = null; if (idle) miniPager.ResetToPlayer(); }
        ulong? displayPosition = model.DisplayPositionMs;
        bool canToggleLyrics = CanToggleCurrentLyrics(state);
        if (currentLyricsOverride is { } choice && (!canToggleLyrics || choice.Mode != preferences.LyricsDisplayMode || !Seeking.SameTrack(choice.Track, state)))
            currentLyricsOverride = null;
        bool showLyrics = !idle && (coverLyricsResizing ? coverResizeExpanded : currentLyricsOverride?.Visible
            ?? (preferences.NarrowPlayerLayout == "cover" && preferences.CoverLyricsPane == "expanded"
                || LyricsDisplayModes.IsVisible(preferences.LyricsDisplayMode, model.LyricsAvailable)));
        RequestLyricsLayout(showLyrics);
        ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
        SetNativePlayerLayout(lyricsVisible, IsFullScreen);
        if (!model.LyricsLoading) { lyricsTrackId = state.TrackId; lyricsTitle = state.Title; }
        bool lyricSeek = model.CanSeek && !model.LyricsLoading && !lyricsLayoutTransitioning;
        bool allowStagger = state.Phase == ReceiverPhase.Playing && !model.SeekPending && !lyricsLayoutTransitioning
            && !MiniProgressSeek.PointerSeekActive && !ProgressSeek.PointerSeekActive && !miniPager.Animating;
        miniLyrics.Update(model.Lyrics, model.LyricsPositionMs, lyricSeek, model.LyricsLoading, connected: state.ControlsAvailable, compact: true, preferences: preferences, allowStagger: allowStagger);
        expandedLyrics.Update(model.Lyrics, model.LyricsPositionMs, lyricSeek, model.LyricsLoading, connected: state.ControlsAvailable, compact: false, preferences: preferences, allowStagger: allowStagger);
        UiTypography.Apply(RootGrid, preferences);
        var presentation = model.DisplayMetadata;
        MiniTitle.Text = TitleText.Text = presentation.Title.Length > 0 ? presentation.Title : L.Text(state.HasMedia ? "正在接收音乐" : "让音乐，连接此刻");
        string metadata = string.Join(" · ", new[] { presentation.Artist, presentation.Album }.Where(x => !string.IsNullOrWhiteSpace(x)));
        MiniArtist.Text = ArtistText.Text = metadata.Length > 0 ? metadata : state.HasMedia ? L.Text("来自手机妙播") : L.Text("在手机妙播中选择") + " " + model.Settings.Name;
        StatusText.Text = model.Busy ? L.Text("正在处理…") : L.Text(state.PhaseLabel);
        UpdateCover();
        UpdateAlbumPages(preferences);
        MiniPlaceholder.Visibility = CoverPlaceholder.Visibility = !idle && model.Artwork == null ? Visibility.Visible : Visibility.Collapsed;
        MiniCover.Visibility = MiniPreviousCover.Visibility = CoverImage.Visibility = PreviousCoverImage.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        // Retain each scene's prepared artwork through responsive/full-screen
        // transitions, but never cover the native acrylic of the idle window.
        byte[]? artwork = idle ? null : model.ArtworkBytes;
        bool legacyExpandedEffects = backdrop.SetArtwork(artwork);
        bool expandedLyricEffects = expandedLyricsBackdrop.SetArtwork(artwork);
        bool expandedLyricsMode = !compact ? lyricsVisible : configuredLyricsLayout == true;
        bool miniLyricsMode = configuredMiniLyricsLayout == true;
        bool expandedEffects = expandedLyricsMode ? expandedLyricEffects : legacyExpandedEffects;
        bool effects = miniBackdrop.SetArtwork(artwork);
        loadingBackdrop.SetArtwork(model.ArtworkLoading ? artwork : null);
        bool miniLyricEffects = lyricsBackdrop.SetArtwork(artwork);
        bool sceneEffects = sceneBackdrop.SetArtwork(artwork);
        bool highContrast = accessibility.HighContrast;
        bool acrylicRequested = !idle && (compact ? miniLyricsMode : lyricsVisible) && preferences.LyricsBackgroundMode == "acrylic";
        // Both backdrops use Window.SystemBackdrop. Detach the outgoing one
        // before updating the material for the incoming mode.
        if (idle) acrylic.Update(false, highContrast);
        bool idleAcrylic = UpdateIdleBackdrop(idle && !highContrast);
        if (!idle) acrylic.Update(acrylicRequested, highContrast);
        bool expandedAcrylic = acrylicRequested && expandedLyricsMode;
        bool miniAcrylic = acrylicRequested && miniLyricsMode;
        RootGrid.RequestedTheme = acrylicRequested && !highContrast ? ElementTheme.Dark : ElementTheme.Default;
        BackdropLayer.Visibility = expandedLyricsMode ? Visibility.Collapsed : Visibility.Visible;
        ExpandedLyricsBackground.Visibility = !idle && expandedLyricsMode && !expandedAcrylic ? Visibility.Visible : Visibility.Collapsed;
        bool pagedAcrylic = miniPager.Active && miniAcrylic;
        MiniLyricsBackground.Visibility = !idle && (miniLyricsMode || miniPager.Active) && !pagedAcrylic ? Visibility.Visible : Visibility.Collapsed;
        Grid.SetRowSpan(MiniLyricsBackground, miniAcrylic ? 1 : 3);
        Grid.SetRowSpan(MiniLyricsGlobalShade, miniAcrylic ? 1 : 3);
        SceneBacking.Visibility = !idle && lyricsLayoutTransitioning ? Visibility.Visible : Visibility.Collapsed;
        Brush solid = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        Brush idleBackground = idleAcrylic ? transparent : solid;
        Brush materialBackground = highContrast ? solid : acrylic.IsActive ? transparent : charcoal;
        RootGrid.Background = idle ? idleBackground : acrylicRequested ? materialBackground : solid;
        MiniLyricsBackground.Background = miniAcrylic ? highContrast ? solid : lyricFallback : null;
        SceneBacking.Background = acrylicRequested ? materialBackground : highContrast ? solid : lyricFallback;
        SceneBackingLayer.Visibility = acrylicRequested ? Visibility.Collapsed : Visibility.Visible;
        SceneBackingShade.Background = sceneEffects ? lyricArtShade : lyricEmptyShade;
        SceneBackingShade.Visibility = idle || highContrast || acrylicRequested ? Visibility.Collapsed : Visibility.Visible;
        ExpandedRoot.Background = expandedAcrylic ? materialBackground : highContrast ? solid : expandedLyricsMode ? lyricFallback : expandedEffects ? charcoal : solid;
        ExpandedRoot.RequestedTheme = !highContrast && (expandedLyricsMode || expandedEffects) ? ElementTheme.Dark : ElementTheme.Default;
        BackdropShade.Background = expandedLyricsMode ? expandedLyricEffects ? lyricArtShade : lyricEmptyShade : legacyShade;
        BackdropShade.Visibility = !idle && !highContrast && !expandedAcrylic && (expandedLyricsMode || expandedEffects) ? Visibility.Visible : Visibility.Collapsed;
        MiniControls.Background = albumLayoutActive ? null : highContrast ? solid : effects ? null : charcoal;
        MiniRoot.Background = miniAcrylic ? materialBackground : highContrast ? solid : miniLyricsMode ? lyricFallback : charcoal;
        MiniRoot.RequestedTheme = highContrast ? ElementTheme.Default : ElementTheme.Dark;
        MiniLyricsGlobalShade.Background = miniLyricEffects ? lyricArtShade : lyricEmptyShade;
        MiniLyricsGlobalShade.Visibility = !idle && miniLyricsMode && !highContrast && !pagedAcrylic ? Visibility.Visible : Visibility.Collapsed;
        foreach (var button in new[] { CloseButton, PinButton, MiniFullScreenButton, MiniLyricsToggleButton })
            button.Background = effects || idleAcrylic ? captionBackdrop : solid;
        MiniShade.Visibility = effects ? Visibility.Visible : Visibility.Collapsed;
        if (idle) ExpandedRoot.Background = MiniRoot.Background = idleBackground;
        IdlePlaceholder.Visibility = idle ? Visibility.Visible : Visibility.Collapsed;
        PlayerLayout.Visibility = ExpandedFooter.Visibility = MiniControlsTransitionLayer.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        ExpandedBrand.Visibility = !idle && !expandedLyricsMode ? Visibility.Visible : Visibility.Collapsed;
        if (idle) MiniLyricsHost.Visibility = ExpandedLyricsHost.Visibility = Visibility.Collapsed;
        MiniPreviousButton.IsEnabled = MiniPlayButton.IsEnabled = MiniNextButton.IsEnabled = PreviousButton.IsEnabled = PlayButton.IsEnabled = NextButton.IsEnabled = model.CanControl && !lyricsLayoutTransitioning;
        PlaybackIcons.Update(MiniPreviousIcon, PlaybackCommand.Previous);
        PlaybackIcons.Update(MiniNextIcon, PlaybackCommand.Next);
        bool playing = state.Phase == ReceiverPhase.Playing;
        bool animateTransport = !idle && !lyricsLayoutTransitioning && preferences.ShowPlayerTransport && AppWindow.IsVisible;
        MiniPlayIcon.Update(playing, allowAnimation: animateTransport && compact && controlsShown && (!miniPager.Active || !miniPager.ShowingLyrics));
        PlaybackIcons.Update(PreviousIcon, PlaybackCommand.Previous); PlaybackIcons.Update(NextIcon, PlaybackCommand.Next);
        PlayIcon.Update(playing, allowAnimation: animateTransport && !compact);
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
        UpdateLyricsToggle(canToggleLyrics, showLyrics);
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsAlwaysOnTop = preferences.Pinned && !IsFullScreen;
        bool sectionAnimations = Backdrop.AnimationsEnabled;
        transportTransition.SetVisible(!idle && preferences.ShowPlayerTransport && !model.MigrationRequired, sectionAnimations && compact && !idle);
        expandedTransportTransition.SetVisible(!idle && preferences.ShowPlayerTransport && !model.MigrationRequired, sectionAnimations && !compact && !idle);
        VolumeSlider.IsEnabled = model.Initialized && !lyricsLayoutTransitioning; VolumeSlider.Value = model.Volume;
        AutomationProperties.SetName(VolumeSlider, L.Text("接收音量"));
        AutomationProperties.SetName(MiniCover, L.Text("专辑封面"));
        AutomationProperties.SetName(MiniProgress, L.Text("播放进度"));
        AutomationProperties.SetName(CoverImage, L.Text("专辑封面")); AutomationProperties.SetName(Progress, L.Text("播放进度"));
        // Sender metadata can arrive in several observations while changing a
        // track. Keep the user's chosen slot stable; data availability controls
        // only its contents and interaction, never the section's layout.
        bool progress = !idle && preferences.ShowPlayerProgress && !model.MigrationRequired;
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
            Label(seek, L.Text("播放进度，拖动可预览", "Playback progress, drag to preview"));
            AutomationProperties.SetHelpText(seek, L.Text("点击跳转或拖动预览，松手跳转。方向键前后 10 秒，Home 到开头，End 到结尾。",
                "Click to seek, or drag to preview and release to seek. Use arrows to move ten seconds, Home for the start, and End for the end."));
            seek.RefreshState();
        }
        ApplyProgressColor(preferences);
        RenderProgressPresentation();
        progressTransition.SetVisible(progress, sectionAnimations && compact && !idle);
        expandedProgressTransition.SetVisible(progress, sectionAnimations && !compact && !idle);
        MigrationButton.Content = ExpandedMigrationButton.Content = L.Text("为此电脑建立独立身份");
        MigrationButton.Visibility = ExpandedMigrationButton.Visibility = model.MigrationRequired ? Visibility.Visible : Visibility.Collapsed;
        MiniStatus.Text = ExpandedStatus.Text = L.Text(error.Length > 0 ? error : model.ControlMessage);
        MiniStatus.Visibility = ExpandedStatus.Visibility = MiniStatus.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (compact)
        {
            if (albumLayoutActive || pointerInside || preferences.AlwaysShowControls || WindowSizing.ScreenReaderActive || focusInside || error.Length > 0 || model.MigrationRequired) ShowControls(true);
            else if (!pointerInside) ScheduleHide();
            ShowCaption(pointerInside);
        }
        else if (IsFullScreen) ShowCaption(pointerInside);
        else
        {
            ElementCompositionPreview.GetElementVisual(ExpandedHeader).StopAnimation("Opacity");
            ElementCompositionPreview.GetElementVisual(ExpandedHeader).Opacity = 1; ExpandedHeader.IsHitTestVisible = true; fullscreenCaptionShown = true;
        }
        ShowWindowActions(pointerInside);
        ExpandedDetails.IsHitTestVisible = ExpandedLyricsHost.IsHitTestVisible = !lyricsLayoutTransitioning;
        ApplyMiniPageInput();
        // Requested visibility disables native input holes synchronously; layout
        // callbacks still coalesce the later geometry updates during animations.
        UpdateBlurCoverage(); UpdateInputRegions(); rendering = false;
    }
    private void UpdateScrubPreview()
    {
        if (closed) return;
        RenderProgressPresentation();
        if (!MiniProgressSeek.PointerSeekActive) ScheduleHide();
    }

    private void RenderProgressPresentation()
    {
        var state = model.State;
        ulong? position = state.HasMedia ? model.DisplayPositionMs : null;
        ulong? duration = state.HasMedia && state.DurationMs is > 0 ? state.DurationMs : null;
        SetProgressPresentation(MiniProgress, MiniPosition, MiniProgressSeek.PointerPreviewPositionMs ?? position, duration);
        SetProgressPresentation(Progress, PositionText, ProgressSeek.PointerPreviewPositionMs ?? position, duration);
        MiniDuration.Text = DurationText.Text = duration is { } total ? FormatTime(total) : "--:--";
    }

    private static void SetProgressPresentation(PlayerProgressBar progress, PlayerText time, ulong? position, ulong? duration)
    {
        progress.Value = position is { } value && duration is { } total ? Math.Clamp(100.0 * value / total, 0, 100) : 0;
        time.Text = position is { } current ? FormatTime(current) : "--:--";
    }

    private void MiniPageChanged()
    {
        UpdateAlbumPages(model.Preferences.Value);
        UpdateLyricsToggle(CanToggleCurrentLyrics(model.State), requestedLyricsLayout ?? lyricsVisible);
        ApplyMiniPageInput();
        UpdateInputRegions();
    }
    private void ApplyMiniPageInput()
    {
        bool available = !coverLyricsResizing && !lyricsLayoutTransitioning && !idle;
        bool pagerAtRest = !miniPager.Animating;
        MiniLyricsToggleButton.IsEnabled = available;
        MiniControlsTransitionLayer.IsHitTestVisible = available && (!miniPager.Active || pagerAtRest && !miniPager.ShowingLyrics);
        MiniCoverPanel.IsHitTestVisible = !miniPager.Active || available && pagerAtRest && !miniPager.ShowingLyrics;
        MiniLyricsHost.IsHitTestVisible = available && (!miniPager.Active || pagerAtRest && miniPager.ShowingLyrics);
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
    private bool CanToggleCurrentLyrics(ReceiverSnapshot state) => state.HasMedia && model.HasCurrentTrack
        && (!string.IsNullOrWhiteSpace(state.TrackId) || !string.IsNullOrWhiteSpace(state.Title));
    private void UpdateLyricsToggle(bool available, bool visible)
    {
        var presentation = (Available: available, Visible: available && visible, Paged: miniPager.Active,
            LyricsPage: miniPager.Active && miniPager.ShowingLyrics, Language: L.Language);
        if (lyricsTogglePresentation == presentation) return;
        lyricsTogglePresentation = presentation;
        LyricsToggleButton.Visibility = MiniLyricsToggleButton.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
        if (!available) return;
        string label = visible ? L.Text("隐藏歌词（当前歌曲）", "Hide lyrics for this track")
            : L.Text("显示歌词（当前歌曲）", "Show lyrics for this track");
        Label(MiniLyricsToggleButton, miniPager.Active ? (miniPager.ShowingLyrics
            ? L.Text("返回播放页", "Show player page") : L.Text("显示歌词页", "Show lyrics page")) : label);
        Label(LyricsToggleButton, label);
        LyricsToggleIcon.Opacity = visible ? 1 : .65;
        MiniLyricsToggleIcon.Opacity = (miniPager.Active ? miniPager.ShowingLyrics : visible) ? 1 : .65;
    }
    private bool ToggleCurrentLyrics()
    {
        var state = model.State;
        if (closed || presenterTransitionPending || interactiveResize || !CanToggleCurrentLyrics(state)) return false;
        if (compact && miniPager.Active) return miniPager.Navigate(!miniPager.ShowingLyrics);
        var preferences = model.Preferences.Value;
        string mode = preferences.LyricsDisplayMode;
        bool defaultVisibility = LyricsDisplayModes.IsVisible(mode, model.LyricsAvailable);
        bool visible = !(requestedLyricsLayout ?? defaultVisibility);
        currentLyricsOverride = visible == defaultVisibility ? null : (state, mode, visible);
        if (preferences.CoverLyricsPane == "expanded" && preferences.NarrowPlayerLayout == "cover")
            SaveCoverPane("automatic");
        Render();
        return true;
    }
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
        bool animate = CanAnimateLayout;
        if (requestedLyricsLayout == visible)
        {
            if (lyricsLayoutTransitioning && !animate) CancelLyricsTransition(snapResize: true);
            return;
        }
        bool first = requestedLyricsLayout == null;
        if (lyricsVisible && !visible) squareSizing.RememberLyricsPaneHeight();
        requestedLyricsLayout = visible;
        if (first) { lyricsVisible = visible; return; }
        miniPager.FinishInteraction();
        if (interactiveResize || IsAlbumNarrow(RootGrid.ActualWidth, IsFullScreen))
        {
            // The native border gesture owns the window rectangle until release.
            lyricsVisible = visible;
            appliedLayout = null;
            return;
        }
        bool useLyricsSizing = StackedLyrics(visible, RootGrid.ActualWidth, IsFullScreen);
        if (!animate)
        {
            CancelLyricsTransition(snapResize: false);
            lyricsVisible = visible; appliedLayout = null;
            squareSizing.SetLayoutTransition(true); SetNativePlayerLayout(visible, IsFullScreen);
            resizeTransition.AnimateLyrics(useLyricsSizing, false, () => { });
            return;
        }

        long request = ++layoutTransitionVersion;
        lyricsLayoutTransitioning = true; contentTransitionDone = nativeTransitionDone = false;
        holdExpandedLayout = RootGrid.ActualWidth >= 600 && !compact;
        layoutTransition.Capture(); SceneBacking.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer();
        ProgressSeek.IsEnabled = MiniProgressSeek.IsEnabled = false;
        ExpandedDetails.IsHitTestVisible = MiniControlsTransitionLayer.IsHitTestVisible = MiniLyricsHost.IsHitTestVisible = ExpandedLyricsHost.IsHitTestVisible = false;
        // The mini cover stays square while the native client height changes.
        // Otherwise closing lyrics would stretch it to the old tall window.
        appliedLayout = null; ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
        UpdateInputRegions();
        resizeTransition.AnimateLyrics(useLyricsSizing, true, () =>
        {
            if (closed || request != layoutTransitionVersion) return;
            nativeTransitionDone = true; CompleteLyricsTransition(request);
        });
        layoutTransition.Run(() =>
        {
            if (closed || request != layoutTransitionVersion) return;
            lyricsVisible = visible; appliedLayout = null;
            SetNativePlayerLayout(visible, IsFullScreen); Render();
        }, () =>
        {
            if (closed || request != layoutTransitionVersion) return;
            contentTransitionDone = true; CompleteLyricsTransition(request);
        }, true, visible ? null : compact ? MiniLyricsHost : ExpandedLyricsHost);
    }
    private bool CanAnimateLayout => !interactiveResize && RootGrid.IsLoaded
        && (AppWindow.IsVisible || AnimateHiddenLayoutForCheck) && Backdrop.AnimationsEnabled;
    private long BeginSceneTransition(bool useRemembered)
    {
        miniPager.FinishInteraction();
        long request = ++layoutTransitionVersion;
        bool cached = useRemembered && !layoutTransition.IsRunning;
        lyricsLayoutTransitioning = true; holdExpandedLayout = false; contentTransitionDone = false; nativeTransitionDone = true;
        layoutTransition.Capture(cached); SceneBacking.Visibility = idle ? Visibility.Collapsed : Visibility.Visible;
        ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer(); ProgressSeek.IsEnabled = MiniProgressSeek.IsEnabled = false;
        ExpandedDetails.IsHitTestVisible = MiniControlsTransitionLayer.IsHitTestVisible = MiniLyricsHost.IsHitTestVisible = ExpandedLyricsHost.IsHitTestVisible = false;
        UpdateInputRegions(); return request;
    }
    private void CommitSceneTransition(long request)
    {
        if (closed || request != layoutTransitionVersion) return;
        layoutTransition.Run(() =>
        {
            if (closed || request != layoutTransitionVersion) return;
            appliedLayout = null; Render();
        }, () =>
        {
            if (closed || request != layoutTransitionVersion) return;
            contentTransitionDone = true; CompleteLyricsTransition(request);
        }, CanAnimateLayout);
    }
    private void WindowFrameChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (closed || interactiveResize || lyricsLayoutTransitioning || presenterTransitionPending || !args.DidPositionChange) return;
        layoutTransition.Remember();
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
        presenterTransitionPending = geometryCommitQueued = false;
        layoutTransition.Cancel(); resizeTransition.Cancel(snapResize);
        lyricsLayoutTransitioning = holdExpandedLayout = false;
        lyricsVisible = requestedLyricsLayout ?? lyricsVisible; appliedLayout = null;
        SetNativePlayerLayout(lyricsVisible, IsFullScreen);
        squareSizing.SetLayoutTransition(false);
        // Closing to the tray and requesting mini mode can both happen while
        // paused, with no later receiver notification to restore interaction.
        // An enclosing Render already performs this restoration itself.
        if (!closed && !rendering) Render();
    }
    private void WindowMoveSizeStarted()
    {
        if (closed) return;
        miniPager.FinishInteraction();
        if (lyricsLayoutTransitioning) CancelLyricsTransition(snapResize: false);
    }
    private void WindowResizeStarted()
    {
        if (closed || interactiveResize) return;
        interactiveResize = true;
        miniLyrics.BeginViewportResize();
        expandedLyrics.BeginViewportResize();
        SetResizeTextRendering(true);
    }
    private void CoverLyricsResizeStarted()
    {
        if (closed) return;
        coverResizeExpanded = CoverPaneExpanded(lyricsVisible, model.Preferences.Value);
        coverLyricsResizing = true;
        ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
    }
    private void CoverLyricsResizeExpanded()
    {
        if (closed || !coverLyricsResizing) return;
        coverResizeExpanded = true;
        miniPager.ResetToPlayer();
        Render();
    }
    private void CoverLyricsResizeCompleted(bool expanded)
    {
        if (closed || !coverLyricsResizing) return;
        coverLyricsResizing = false;
        miniPager.ResetToPlayer();
        var preferences = model.Preferences.Value;
        if (preferences.NarrowPlayerLayout == "cover" && model.HasCurrentTrack)
        {
            string mode = preferences.LyricsDisplayMode;
            bool defaultVisibility = LyricsDisplayModes.IsVisible(mode, model.LyricsAvailable);
            currentLyricsOverride = expanded == defaultVisibility ? null : (model.State, mode, expanded);
            SaveCoverPane(expanded ? "expanded" : "collapsed");
        }
        Render();
    }
    private void CoverLyricsResizeCanceled()
    {
        if (closed || !coverLyricsResizing) return;
        coverLyricsResizing = false;
        Render();
    }
    private void SaveCoverPane(string pane)
    {
        var preferences = model.Preferences.Value;
        if (preferences.CoverLyricsPane == pane) return;
        try { preferenceError = ""; model.Preferences.Update(preferences with { CoverLyricsPane = pane }); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { preferenceError = L.Text("无法保存外观设置，请检查数据目录。"); }
    }
    private void WindowMoveSizeEnded()
    {
        if (closed || !interactiveResize) return;
        interactiveResize = false;
        miniLyrics.EndViewportResize();
        expandedLyrics.EndViewportResize();
        SetResizeTextRendering(false);
        ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
        layoutTransition.Remember();
        QueueInputRegions();
    }
    private void SetResizeTextRendering(bool active)
    {
        miniLyrics.SetInteractiveResize(active);
        expandedLyrics.SetInteractiveResize(active);
        foreach (var text in new[] { TitleText, ArtistText, PositionText, DurationText, MiniTitle, MiniArtist, MiniPosition, MiniDuration })
            text.SetInteractiveResize(active);
    }
    private void Root_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (presenterTransitionPending) { QueueGeometryCommit(); return; }
        bool nextCompact = UseCompactLayout(e.NewSize.Width, e.NewSize.Height, IsFullScreen);
        // An explicit mini request has already cancelled the previous scene
        // and restored input. Its asynchronous native resize must finish that
        // snap, rather than starting a second overlap and disabling input again.
        if (compact != nextCompact && CanAnimateLayout && !revealMiniRequested)
        {
            long request = BeginSceneTransition(useRemembered: true);
            CommitSceneTransition(request); return;
        }
        bool wasCompact = compact;
        ApplyPlayerLayout(e.NewSize.Width, e.NewSize.Height);
        bool changed = wasCompact != compact;
        if (changed)
        {
            ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer();
            hideTimer?.Stop(); Render();
        }
        // LayoutUpdated can have applied the compact mode before SizeChanged.
        // Consume the explicit request even when this callback sees no change.
        if (compact && (changed || revealMiniRequested))
        {
            if (revealMiniRequested || pointerInside) { ShowControls(true); ShowCaption(pointerInside); }
            revealMiniRequested = false; ScheduleHide();
        }
        UpdateBlurCoverage(); QueueInputRegions();
    }
    private bool UseCompactLayout(double width, double height, bool fullScreen) => !holdExpandedLayout && !fullScreen
        && (model.HasCurrentTrack ? width < 600 : WindowSizing.IsCompactContent(width, height, lyricsVisible));

    private bool IsAlbumNarrow(double width, bool fullScreen) => !fullScreen && width < 600 && model.Preferences.Value.NarrowPlayerLayout == "album";

    private bool CoverPaneExpanded(bool visible, UiPreferences preferences) => coverLyricsResizing ? coverResizeExpanded
        : visible && preferences.CoverLyricsPane != "collapsed";

    private bool StackedLyrics(bool visible, double width, bool fullScreen) => width >= 600 || fullScreen ? visible
        : model.Preferences.Value is { NarrowPlayerLayout: "cover" } preferences && CoverPaneExpanded(visible, preferences);

    private void SetNativePlayerLayout(bool lyrics, bool fullScreen)
    {
        var preferences = model.Preferences.Value;
        bool hasTrack = model.HasCurrentTrack;
        bool album = hasTrack && preferences.NarrowPlayerLayout == "album";
        bool paged = album || !CoverPaneExpanded(lyrics, preferences);
        squareSizing.SetPlayerLayout(lyrics, fullScreen, paged, coverBottomResize: hasTrack && !album, independentAlbum: album);
    }

    private void ApplyPlayerLayout(double width, double height)
    {
        if (width <= 0 || height <= 0) return;
        var preferences = model.Preferences.Value;
        // A fading section still occupies its animated row until it collapses.
        // Do not enlarge the cover from the requested preference ahead of that
        // actual space being released, especially in short wide windows.
        double progressHeight = Math.Max(preferences.ShowPlayerProgress ? 45 : 0,
            ProgressPanel.Visibility == Visibility.Visible ? ProgressPanel.ActualHeight : 0);
        double transportHeight = Math.Max(preferences.ShowPlayerTransport ? 44 : 0,
            TransportPanel.Visibility == Visibility.Visible ? TransportPanel.ActualHeight : 0);
        bool fullScreen = IsFullScreen;
        bool nextCompact = UseCompactLayout(width, height, fullScreen);
        bool album = nextCompact && IsAlbumNarrow(width, fullScreen);
        bool stacked = nextCompact && !idle && !album && CoverPaneExpanded(lyricsVisible, preferences);
        bool paged = nextCompact && model.HasCurrentTrack && !idle && !stacked && !coverLyricsResizing;
        double metadataHeight = !nextCompact && lyricsVisible ? ExpandedMetadata.ActualHeight : 0;
        var layout = (width, height, lyricsVisible, preferences.ShowPlayerProgress, preferences.ShowPlayerTransport, progressHeight, transportHeight,
            metadataHeight, preferences.WrapTrackMetadata, fullScreen, idle, paged, stacked, album);
        if (appliedLayout is { } previousLayout && previousLayout == layout) return;
        if (appliedLayout?.WrapMetadata != preferences.WrapTrackMetadata)
        {
            TextWrapping metadataWrapping = preferences.WrapTrackMetadata ? TextWrapping.Wrap : TextWrapping.NoWrap;
            int metadataLines = preferences.WrapTrackMetadata ? 2 : 1;
            TitleText.TextWrapping = ArtistText.TextWrapping = MiniTitle.TextWrapping = MiniArtist.TextWrapping = metadataWrapping;
            TitleText.MaxLines = ArtistText.MaxLines = MiniTitle.MaxLines = MiniArtist.MaxLines = metadataLines;
        }
        appliedLayout = layout;
        if (compact != nextCompact) { ProgressSeek.CancelPointer(); MiniProgressSeek.CancelPointer(); }
        compact = nextCompact;
        ExpandedRoot.Visibility = !compact || ReferenceEquals(layoutTransition?.RetainedScene, ExpandedRoot) ? Visibility.Visible : Visibility.Collapsed;
        MiniRoot.Visibility = compact || ReferenceEquals(layoutTransition?.RetainedScene, MiniRoot) ? Visibility.Visible : Visibility.Collapsed;
        if (compact)
        {
        ApplyAlbumLayout(album, width, height, preferences.ShowPlayerProgress, preferences.ShowPlayerTransport);
        configuredMiniLyricsLayout = stacked || album || paged && lyricsVisible;
        bool squareCover = !album && (stacked || coverLyricsResizing || !paged && lyricsLayoutTransitioning);
        MiniCoverRow.Height = squareCover ? new GridLength(width) : new GridLength(1, GridUnitType.Star);
        MiniCoverPanel.Height = squareCover ? width : double.NaN;
        MiniCover.Stretch = MiniPreviousCover.Stretch = stacked || album ? Stretch.Uniform : Stretch.UniformToFill;
        MiniLyricsGapRow.Height = new GridLength(stacked ? Math.Clamp(height - width, 0, 8) : 0);
        MiniLyricsRow.Height = stacked ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        if (!paged) MiniLyricsHost.Visibility = stacked ? Visibility.Visible : Visibility.Collapsed;
        Grid.SetRow(MiniLyricsHost, paged ? 0 : 2);
        MiniLyricsHost.MinHeight = 0;
        double lyricInset = width < 320 ? 16 : 22;
        MiniLyricsHost.Padding = new Thickness(lyricInset, paged ? CompactLyricsPager.HeaderHeight : 0, lyricInset, 12);
        MiniTitle.FontSize = album ? 22 : width < 320 ? 17 : 20; MiniArtist.FontSize = album ? 13 : 14;
        }
        // Leave the outgoing page intact while the wide layout overlaps it.
        if (compact || !ReferenceEquals(layoutTransition?.RetainedScene, MiniRoot))
            miniPager.Configure(paged, width);

        if (!compact)
        {
        bool configure = configuredLyricsLayout != lyricsVisible;
        configuredLyricsLayout = lyricsVisible;
        ExpandedLyricsHost.Visibility = lyricsVisible && !idle ? Visibility.Visible : Visibility.Collapsed;
        double side;
        if (lyricsVisible)
        {
            double reserved = Math.Max(76, metadataHeight + 30) + progressHeight + transportHeight;
            var reading = ExpandedLyricsLayout.ForWindow(width, height, fullScreen, reserved);
            side = reading.ArtworkSide;
            ExpandedContent.Padding = new Thickness(reading.HorizontalInset, reading.VerticalInset, reading.HorizontalInset, reading.VerticalInset);
            PlayerLayout.Width = fullScreen ? reading.ContentWidth : double.NaN;
            PlayerLayout.HorizontalAlignment = fullScreen ? HorizontalAlignment.Center : HorizontalAlignment.Stretch;
            PlayerLayout.ColumnDefinitions[0].Width = new GridLength(reading.ArtworkColumn);
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
                ExpandedMetadata.Spacing = 5; TitleText.FontSize = 20; ArtistText.FontSize = 14;
                VolumeRow.Visibility = Visibility.Collapsed;
                PreviousButton.Width = PreviousButton.Height = NextButton.Width = NextButton.Height = 36;
                PlayButton.Width = PlayButton.Height = 44;
            }
            PlayerLayout.ColumnSpacing = reading.ColumnGap;
        }
        else
        {
            side = Math.Clamp(Math.Min(height - 126, width * .36), 130, 360);
            PlayerLayout.Width = double.NaN;
            PlayerLayout.HorizontalAlignment = HorizontalAlignment.Stretch;
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
                ExpandedMetadata.Spacing = 7; TitleText.FontSize = 20; ArtistText.FontSize = 14;
                VolumeRow.Visibility = Visibility.Visible;
                PreviousButton.Width = PreviousButton.Height = NextButton.Width = NextButton.Height = 40;
                PlayButton.Width = PlayButton.Height = 52;
            }
        }
        CoverFrame.Width = CoverFrame.Height = side; CoverFrame.HorizontalAlignment = HorizontalAlignment.Center; CoverFrame.VerticalAlignment = VerticalAlignment.Top;
        }
    }
    private void MiniControls_SizeChanged(object sender, SizeChangedEventArgs e) { UpdateBlurCoverage(); QueueInputRegions(); }
    private void Root_LayoutUpdated(object? sender, object e)
    {
        if (interactiveResize) return;
        // This is a cached comparison, not a forced layout pass. Natural
        // section-height ticks also release the corresponding cover budget.
        if (!closed && !presenterTransitionPending && lyricsVisible && !compact) ApplyPlayerLayout(RootGrid.ActualWidth, RootGrid.ActualHeight);
        if (!closed && !lyricsLayoutTransitioning && !presenterTransitionPending) layoutTransition?.Remember();
        QueueInputRegions();
    }
    private void QueueInputRegions()
    {
        if (closed || interactiveResize || inputRegionsQueued) return;
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
        if (closed || interactiveResize || squareSizing == null || RootGrid.XamlRoot == null) return;
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
            Add(LyricsToggleButton); Add(SettingsButton); Add(ExpandedFullScreenButton); Add(ExpandedCloseButton);
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
            if (captionShown) { Add(CloseButton); Add(PinButton); Add(MiniFullScreenButton); Add(MiniLyricsToggleButton); }
            if (miniPager.Active && !lyricsLayoutTransitioning && !idle)
            {
                // Reserve the rest of the top strip for dragging this frameless window.
                int top = (int)Math.Ceiling(CompactLyricsPager.HeaderHeight * scale);
                int bottom = (int)Math.Ceiling(MiniRoot.ActualHeight * scale);
                int width = (int)Math.Ceiling(MiniRoot.ActualWidth * scale);
                if (bottom > top && width > 0) rectangles.Add(new(0, top, width, bottom - top));
            }
            else if (!lyricsLayoutTransitioning && !idle && MiniLyricsHost.Visibility == Visibility.Visible) Add(MiniLyricsHost);
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
        visible |= albumLayoutActive || MiniProgressSeek.PointerSeekActive || model.Preferences.Value.AlwaysShowControls || WindowSizing.ScreenReaderActive
            || focusInside || model.Error.Length > 0 || preferenceError.Length > 0 || model.MigrationRequired;
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
        ShowWindowActions(pointerInside);
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
    private void ShowWindowActions(bool visible)
    {
        if (CloseButton == null || windowActionsShown == visible) return;
        bool animate = windowActionsShown != null && RootGrid.IsLoaded && AppWindow.IsVisible;
        windowActionsShown = visible;
        foreach (var button in new[] { LyricsToggleButton, SettingsButton, ExpandedFullScreenButton, ExpandedCloseButton, MiniLyricsToggleButton, MiniFullScreenButton, CloseButton })
        {
            if (animate) AnimateVisibility(button, visible, visible ? .25 : .20, 0);
            else Fade(button, 0, visible ? 1 : 0, 0);
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
    private void LyricsToggle_Click(object sender, RoutedEventArgs e) => ToggleCurrentLyrics();
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
        try { if (resizeTransition.IsRunning) CancelLyricsTransition(snapResize: true); squareSizing.RememberLyricsPaneHeight(); fullScreen.Toggle(); }
        catch (Exception) { CancelLyricsTransition(snapResize: false); preferenceError = L.Text("无法切换全屏，请重试。", "Could not change full screen. Try again."); model.Store.EventDiagnostic("fullscreen_failed"); Render(); }
    }
    private void FullScreen_Click(object sender, RoutedEventArgs e) => ToggleFullScreen();
    private void FullScreenChanging(bool nextFullScreen)
    {
        if (closed) return;
        if (!CanAnimateLayout) { CancelLyricsTransition(snapResize: true); return; }
        BeginSceneTransition(useRemembered: false);
        presenterTransitionPending = true;
    }
    private void QueueGeometryCommit()
    {
        if (closed || !presenterTransitionPending || geometryCommitQueued) return;
        long request = layoutTransitionVersion;
        geometryQueuedVersion = request;
        geometryCommitQueued = DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (geometryQueuedVersion != request) return;
            geometryCommitQueued = false;
            if (closed || !presenterTransitionPending) return;
            if (request != layoutTransitionVersion) { QueueGeometryCommit(); return; }
            geometryCommitQueued = true;
            try { RootGrid.UpdateLayout(); }
            catch (Exception error) when (error is COMException or InvalidOperationException or ObjectDisposedException or ArgumentException)
            {
                geometryCommitQueued = false; CancelLyricsTransition(snapResize: false);
                model.Store.EventDiagnostic("layout_transition_failed:" + error.GetType().Name); return;
            }
            geometryCommitQueued = false;
            if (closed || !presenterTransitionPending || request != layoutTransitionVersion) { QueueGeometryCommit(); return; }
            presenterTransitionPending = false;
            CommitSceneTransition(request);
        });
        if (!geometryCommitQueued) CancelLyricsTransition(snapResize: false);
    }
    private void FullScreenChanged()
    {
        if (closed) return;
        if (presenterTransitionPending) { QueueGeometryCommit(); return; }
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
