using System.Numerics;
using System.Runtime.InteropServices;
using System.Diagnostics;
using FusionPlay.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Foundation;
using Windows.System;
using Windows.UI.ViewManagement;
using DispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using DispatcherQueuePriority = Microsoft.UI.Dispatching.DispatcherQueuePriority;

namespace FusionPlay.Windows.Platform;

/// <summary>Native, source-only lyric presentation. It never fetches, stores, or logs song text.</summary>
public sealed partial class LyricsView : UserControl, IDisposable
{
    private readonly ListView list = new()
    {
        Name = "LyricsLines", SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = false,
        IsTabStop = false, Padding = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent),
        ShowsScrollingPlaceholders = false, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch
    };
    private readonly Border topSpace = new(), bottomSpace = new();
    private readonly StackPanel empty = new() { Spacing = 8, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20) };
    private readonly FontIcon emptyIcon = new() { Glyph = "\uE8D6", FontSize = 28, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ProgressRing loadingRing = new() { Width = 18, Height = 18, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock emptyTitle = new() { TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, FontSize = 15, Opacity = .65 };
    private readonly TextBlock emptyHint = new() { TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = .45 };
    private readonly UISettings settings = new();
    private readonly AccessibilitySettings accessibility = new();
    private readonly DispatcherQueueTimer browsingTimer;
    private readonly DispatcherQueueTimer glyphTimer;
    private readonly HashSet<LyricsRowPresenter> realized = [];
    private readonly Queue<LyricsRowPresenter> glyphQueue = new();
    private readonly HashSet<LyricsRowPresenter> pendingGlyphs = [];
    private bool resizeEdgesPending;
    private LyricsGraphicsResources? graphicsResources;
    private bool graphicsUnavailable;
    private bool rowsNeedStyle, graphicsRecoveryQueued;
    private LyricsDocument document = LyricsDocument.Empty;
    private LyricsRowItem[] items = [];
    private ScrollViewer? scroller;
    private XamlRoot? subscribedRoot;
    private UiPreferences preferences = new();
    private string typographyKey = "";
    private ulong? lastPosition;
    private int activeIndex = -1, followRevision;
    private bool connected, loading, canSeek, compact, browsing, loaded, disposed, edgeQueued;
    private bool pointerDown;
    private long browsingDeadline;
    internal static readonly TimeSpan BrowsingResumeDelay = TimeSpan.FromSeconds(5);
    private bool presentationVisible;
    private double observedRasterScale, observedTextScale = 1;
    private string emptyStateKey = "";
    private Point pointerStart;

    public event Action<ulong>? SeekRequested;
    internal bool Compact => compact;
    internal bool HighContrast { get; private set; }
    internal bool EffectsEnabled { get; private set; }
    internal bool MotionEnabled { get; private set; }
    internal bool EnhancedText => preferences.PlayerTextRendering == "enhanced";
    internal FontFamily LyricFont { get; private set; } = new("Segoe UI");
    internal global::Windows.UI.Text.FontWeight BodyWeight { get; private set; } = Microsoft.UI.Text.FontWeights.Bold;
    internal global::Windows.UI.Text.FontWeight TranslationWeight { get; private set; } = Microsoft.UI.Text.FontWeights.SemiBold;
    internal double TextScale => observedTextScale;
    internal double Bleed => compact ? 16 : 24;
    private double ResponsiveBodySize => compact ? Math.Clamp(ActualWidth * .075, 20, 28) : Math.Clamp(ActualWidth * .075, 25, 34);
    internal double BodySize => heldResizeBodySize ?? ResponsiveBodySize;
    internal double LyricsFontScale => preferences.LyricsTextScalePercent / 100d;
    internal bool CanSeek => canSeek && connected && !loading;
    internal int ActiveIndex => activeIndex;
    internal bool Timed => document.IsTimed;
    internal bool PresentationLoaded => loaded && !disposed && presentationVisible && ActualWidth > 0 && ActualHeight > 0;
    internal double ViewportHeight => Math.Max(0, ActualHeight);

    public LyricsView()
    {
        InitializeComponent(); Name = "LyricsView"; IsTabStop = false;
        list.ItemsPanel = (ItemsPanelTemplate)Resources["LyricsItemsPanel"];
        list.ItemTemplate = (DataTemplate)Resources["LyricsRowTemplate"]; list.ItemContainerStyle = (Style)Resources["LyricsItemStyle"];
        list.Header = topSpace; list.Footer = bottomSpace;
        ScrollViewer.SetHorizontalScrollMode(list, ScrollMode.Disabled); ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(list, ScrollBarVisibility.Hidden);
        empty.Children.Add(emptyIcon); empty.Children.Add(loadingRing); empty.Children.Add(emptyTitle); empty.Children.Add(emptyHint);
        var root = new Grid(); root.Children.Add(list); root.Children.Add(empty); Content = root;
        browsingTimer = DispatcherQueue.CreateTimer(); browsingTimer.IsRepeating = false; browsingTimer.Interval = BrowsingResumeDelay; browsingTimer.Tick += BrowsingExpired;
        glyphTimer = DispatcherQueue.CreateTimer(); glyphTimer.IsRepeating = false; glyphTimer.Interval = TimeSpan.FromMilliseconds(16); glyphTimer.Tick += DrawQueuedGlyphs;
        resizeQuietTimer = DispatcherQueue.CreateTimer();
        resizeQuietTimer.IsRepeating = false;
        resizeQuietTimer.Interval = TimeSpan.FromMilliseconds(ResizeQuietMilliseconds);
        resizeQuietTimer.Tick += ResizeQuietElapsed;
        followMotionTimer = DispatcherQueue.CreateTimer();
        followMotionTimer.IsRepeating = true;
        // The compositor animates position. This timer only samples edge
        // effects and retires the translation after the wave has settled.
        followMotionTimer.Interval = TimeSpan.FromMilliseconds(48);
        followMotionTimer.Tick += FollowMotionTick;
        list.Loaded += ListLoaded;
        list.ContainerContentChanging += ContainerChanging;
        list.AddHandler(PointerWheelChangedEvent, new PointerEventHandler(WheelChanged), true);
        list.AddHandler(PointerPressedEvent, new PointerEventHandler(BrowsePointerPressed), true);
        list.AddHandler(PointerMovedEvent, new PointerEventHandler(BrowsePointerMoved), true);
        list.AddHandler(PointerReleasedEvent, new PointerEventHandler(PointerEnded), true);
        list.AddHandler(PointerCanceledEvent, new PointerEventHandler(PointerEnded), true);
        list.AddHandler(PointerCaptureLostEvent, new PointerEventHandler(PointerEnded), true);
        list.AddHandler(KeyDownEvent, new KeyEventHandler(BrowseKey), true);
        Loaded += ViewLoaded; Unloaded += ViewUnloaded; SizeChanged += ViewSizeChanged; ActualThemeChanged += ThemeChanged;
        settings.AdvancedEffectsEnabledChanged += EffectsChanged; settings.ColorValuesChanged += EffectsChanged; settings.TextScaleFactorChanged += TextScaleChanged;
        L.Changed += Localize;
        ReadEnvironment(); Localize(); UpdateGeometry();
    }

    /// <summary>Only a new immutable document replaces items. Playback/control changes retain all line identities.</summary>
    public void Update(LyricsDocument? next, ulong? positionMs, bool canSeek, bool loading = false, bool connected = true, bool compact = false, UiPreferences? preferences = null, bool allowStagger = true)
    {
        if (disposed) return;
        next ??= LyricsDocument.Empty;
        bool newDocument = !ReferenceEquals(document, next), geometryChanged = this.compact != compact;
        bool visibilityChanged = RefreshPresentation();
        bool stateChanged = this.canSeek != canSeek || this.connected != connected || this.loading != loading;
        this.connected = connected; this.loading = loading; this.canSeek = canSeek; this.compact = compact;
        allowFollowMotion = allowStagger;
        if (!connected || !next.HasLyrics) lastPosition = null;
        else if (positionMs.HasValue) lastPosition = positionMs;
        var oldPreferences = this.preferences;
        bool environmentChanged = ReadEnvironment();
        bool typographyChanged = SetTypography(preferences ?? this.preferences);
        bool motionSettingsChanged = oldPreferences.LyricsStaggerEnabled != this.preferences.LyricsStaggerEnabled
            || oldPreferences.LyricsStaggerMilliseconds != this.preferences.LyricsStaggerMilliseconds
            || oldPreferences.LyricsFollowDurationMilliseconds != this.preferences.LyricsFollowDurationMilliseconds;
        bool interruptedMotion = followMotion != null
            && (!allowStagger || !connected || loading || !MotionEnabled || motionSettingsChanged || geometryChanged || typographyChanged);
        if (interruptedMotion) StopFollowMotion();
        if (!connected) ClearReadingAnchor();
        if (newDocument)
        {
            StopFollowMotion();
            ClearReadingAnchor();
            ++followRevision; browsingTimer.Stop(); browsing = false; document = next;
            items = next.Lines.Select((line, index) => new LyricsRowItem(this, line, index)).ToArray();
            list.ItemsSource = items; activeIndex = document.ActiveLineIndex(lastPosition);
        }
        else
        {
            int active = document.ActiveLineIndex(lastPosition);
            if (active != activeIndex)
            {
                int previous = activeIndex;
                activeIndex = active;
                stateChanged = true;
                ScheduleFollow(animated: allowStagger, adjacentAdvance: previous >= 0 && active >= 0 && Math.Abs(active - previous) is 1 or 2);
            }
        }
        if (newDocument || geometryChanged) UpdateGeometry();
        if (newDocument || stateChanged || geometryChanged || typographyChanged || environmentChanged || visibilityChanged) RefreshRows(geometryChanged || typographyChanged || environmentChanged);
        LocalizeEmpty();
        if (newDocument || geometryChanged || typographyChanged || interruptedMotion || visibilityChanged && PresentationLoaded) ScheduleFollow(animated: false);
    }
    public void Clear() => Update(LyricsDocument.Empty, null, false, connected: false, compact: compact, preferences: preferences);
    private bool SetTypography(UiPreferences value)
    {
        if (ReferenceEquals(preferences, value) && typographyKey.Length > 0) return false;
        string key = value.UiFontFamily + ":" + value.UiFontWeight + ":" + value.PlayerTextRendering + ":" + value.LyricsTextScalePercent;
        preferences = value;
        if (key == typographyKey) return false;
        typographyKey = key; var family = UiTypography.Resolve(value.UiFontFamily); LyricFont = new FontFamily(family.Name);
        BodyWeight = new() { Weight = (ushort)FontSelection.HeadingWeight(family.Weights, value.UiFontWeight) };
        TranslationWeight = new() { Weight = (ushort)FontSelection.NearestWeight(family.Weights, Math.Max(500, value.UiFontWeight)) };
        return true;
    }
    private bool ReadEnvironment()
    {
        bool contrast = accessibility.HighContrast, effects, motion; double textScale;
        try { effects = settings.AdvancedEffectsEnabled && !contrast; motion = settings.AnimationsEnabled && !contrast; textScale = settings.TextScaleFactor; }
        catch (COMException) { effects = motion = false; textScale = observedTextScale; }
        bool motionChanged = MotionEnabled != motion;
        bool changed = HighContrast != contrast || EffectsEnabled != effects || motionChanged || textScale != observedTextScale;
        HighContrast = contrast; EffectsEnabled = effects; MotionEnabled = motion; observedTextScale = textScale;
        if (motionChanged) UpdateRowTransitions();
        return changed;
    }
    private void UpdateRowTransitions()
    {
        // Glyphs animate real wrap changes. A simultaneous XAML reposition
        // transition would also move the same rows underneath them.
        var transitions = MotionEnabled && !ViewportResizePending ? (TransitionCollection)Resources["LyricsReflowTransitions"] : null;
        if (!ReferenceEquals(list.ItemContainerTransitions, transitions)) list.ItemContainerTransitions = transitions;
    }
    private void Localize()
    {
        if (disposed) return;
        AutomationProperties.SetName(this, L.Text("歌词", "Lyrics")); AutomationProperties.SetName(list, L.Text("歌词", "Lyrics"));
        LocalizeEmpty(); RefreshRows(style: true);
    }
    private void LocalizeEmpty()
    {
        string key = $"{document.HasLyrics}:{loading}:{connected}:{compact}:{HighContrast}:{L.Language}";
        if (key == emptyStateKey) return; emptyStateKey = key;
        empty.Visibility = document.HasLyrics ? Visibility.Collapsed : Visibility.Visible; list.Visibility = document.HasLyrics ? Visibility.Visible : Visibility.Collapsed;
        loadingRing.IsActive = loading && !document.HasLyrics; loadingRing.Visibility = loading ? Visibility.Visible : Visibility.Collapsed; emptyIcon.Visibility = loading ? Visibility.Collapsed : Visibility.Visible;
        emptyIcon.FontSize = compact ? 23 : 28; emptyTitle.FontSize = compact ? 13 : 15;
        emptyTitle.Text = loading ? L.Text("正在载入歌词…", "Loading lyrics…") : connected ? L.Text("暂无歌词", "No lyrics available") : L.Text("等待你的音乐", "Waiting for your music");
        emptyHint.Text = L.Text("歌词由手机提供", "Lyrics are supplied by your phone"); emptyHint.Visibility = connected && !loading ? Visibility.Visible : Visibility.Collapsed;
        var brush = HighContrast ? (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"] : new SolidColorBrush(Colors.White);
        emptyTitle.Foreground = emptyHint.Foreground = emptyIcon.Foreground = brush;
    }
    private void ViewLoaded(object sender, RoutedEventArgs args)
    {
        if (disposed) return; loaded = true; RefreshPresentation(); subscribedRoot = XamlRoot; observedRasterScale = XamlRoot?.RasterizationScale ?? 1; if (subscribedRoot != null) subscribedRoot.Changed += RootChanged;
        LayoutUpdated += ReadingLayoutUpdated;
        UpdateRowTransitions();
        AttachScroller(); UpdateGeometry(); RefreshRows(style: true); ScheduleFollow(animated: false);
    }
    private void ViewUnloaded(object sender, RoutedEventArgs args)
    {
        loaded = false; ++followRevision; browsingTimer.Stop(); CancelGlyphQueue(); browsing = false; pointerDown = false;
        LayoutUpdated -= ReadingLayoutUpdated;
        ResetViewportMotion();
        if (subscribedRoot != null) subscribedRoot.Changed -= RootChanged; subscribedRoot = null; DetachScroller();
        foreach (var row in realized.ToArray()) { row.StopAnimations(); row.ReleaseSurface(); }
    }
    private void ListLoaded(object sender, RoutedEventArgs args) { AttachScroller(); ScheduleFollow(animated: false); }
    private void ContainerChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        // The row has its own accessible text/button peer; the list container is structural.
        AutomationProperties.SetAccessibilityView(args.ItemContainer, AccessibilityView.Raw);
    }
    private static T? FindVisual<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T found) return found;
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) if (FindVisual<T>(VisualTreeHelper.GetChild(root, i)) is { } child) return child;
        return null;
    }
    private void AttachScroller()
    {
        if (scroller != null || disposed) return;
        scroller = FindVisual<ScrollViewer>(list); if (scroller == null) return;
        scroller.ViewChanged += ScrollChanged; scroller.DirectManipulationStarted += DirectManipulation;
    }
    private void DetachScroller()
    {
        if (scroller == null) return;
        scroller.ViewChanged -= ScrollChanged; scroller.DirectManipulationStarted -= DirectManipulation; scroller = null;
        followScroll = null;
    }
    private void ViewSizeChanged(object sender, SizeChangedEventArgs args)
    {
        if (disposed) return;
        RefreshPresentation();
        bool widthChanged = args.NewSize.Width != args.PreviousSize.Width;
        if (widthChanged && args.PreviousSize.Width > 0 && PresentationLoaded)
            BeginReflow();
        UpdateGeometry();
        if (widthChanged && !InteractiveResize) RefreshRows(style: true);
        if (viewportReflow) QueueReadingAnchorRestore();
        else if (!nativeViewportResize) ScheduleFollow(animated: false);
    }
    private void UpdateGeometry()
    {
        list.Margin = new Thickness(-Bleed, 0, -Bleed, 0);
        // Keep the scroll extent independent of pointer-height samples. Apply
        // the new top/bottom room once when the native drag exits.
        if (!resizePaddingHeld)
        {
            UpdateViewportPadding();
            resizePaddingHeld = nativeViewportResize && PresentationLoaded;
        }
        QueueEdges();
    }
    private bool UpdateViewportPadding()
    {
        double height = ViewportHeight;
        double top = document.IsTimed ? Math.Max(14, height * .32) : Math.Max(12, height * .30) + 14;
        double bottom = document.IsTimed ? Math.Max(14, height * .68) : Math.Max(12, height * .45) + 14;
        if (topSpace.Height == top && bottomSpace.Height == bottom) return false;
        topSpace.Height = top; bottomSpace.Height = bottom;
        return true;
    }
    private void ScrollChanged(object? sender, ScrollViewerViewChangedEventArgs args)
    {
        QueueEdges();
        // Native inertia continues after the last wheel/pointer event. Resume
        // only after scrolling itself has been quiet for the full interval.
        if (browsing && !ViewportResizePending) RestartBrowsingDeadline();
        if (ViewportResizePending) AnchorViewChanged(args.IsIntermediate);
        else if (followMotion == null) RememberReadingAnchor();
    }
    private void DirectManipulation(object? sender, object args) => BeginBrowsing();
    private void WheelChanged(object sender, PointerRoutedEventArgs args)
    {
        var pointer = args.GetCurrentPoint(list).Properties;
        if (!pointer.IsHorizontalMouseWheel && pointer.MouseWheelDelta != 0) BeginBrowsing();
    }
    private void BrowsePointerPressed(object sender, PointerRoutedEventArgs args) { pointerDown = true; pointerStart = args.GetCurrentPoint(list).Position; }
    private void BrowsePointerMoved(object sender, PointerRoutedEventArgs args)
    {
        if (!pointerDown) return; Point point = args.GetCurrentPoint(list).Position;
        double vertical = Math.Abs(point.Y - pointerStart.Y);
        if (vertical >= 6 && vertical > Math.Abs(point.X - pointerStart.X)) BeginBrowsing();
    }
    private void PointerEnded(object sender, PointerRoutedEventArgs args)
    { pointerDown = false; if (browsing) RestartBrowsingDeadline(); }
    private void BrowseKey(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key is VirtualKey.Up or VirtualKey.Down or VirtualKey.PageUp or VirtualKey.PageDown or VirtualKey.Home or VirtualKey.End) BeginBrowsing();
    }
    private void BeginBrowsing()
    {
        if (disposed || !document.IsTimed) return;
        StopFollowMotion(keepReadingPosition: true);
        ClearReadingAnchor();
        browsing = true; ++followRevision; RestartBrowsingDeadline();
    }
    private void RestartBrowsingDeadline()
    {
        browsingDeadline = Stopwatch.GetTimestamp() + (long)(BrowsingResumeDelay.TotalSeconds * Stopwatch.Frequency);
        browsingTimer.Stop(); browsingTimer.Interval = BrowsingResumeDelay; browsingTimer.Start();
    }
    private void BrowsingExpired(DispatcherQueueTimer sender, object args)
    {
        if (disposed || !browsing) return;
        if (pointerDown) { RestartBrowsingDeadline(); return; }
        long remaining = browsingDeadline - Stopwatch.GetTimestamp();
        if (remaining > 0)
        {
            browsingTimer.Interval = TimeSpan.FromSeconds(Math.Max(.001, remaining / (double)Stopwatch.Frequency)); browsingTimer.Start(); return;
        }
        browsing = false; ScheduleFollow(animated: true);
    }
    private void ReturnToCurrent(object sender, RoutedEventArgs args)
    {
        ClearReadingAnchor();
        browsing = false; browsingTimer.Stop(); ScheduleFollow(animated: true, explicitRequest: true);
    }
    private void ScheduleFollow(bool animated, bool explicitRequest = false, bool adjacentAdvance = false)
    {
        if (!PresentationLoaded || browsing || !document.IsTimed || !lastPosition.HasValue || (!explicitRequest && WindowSizing.ScreenReaderActive)) return;
        if (ViewportResizePending)
        {
            followAfterReflow = true;
            return;
        }
        int revision = ++followRevision;
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => Follow(revision, animated && MotionEnabled, explicitRequest, realize: true, adjacentAdvance: adjacentAdvance));
    }
    private void Follow(int revision, bool animated, bool explicitRequest, bool realize, bool adjacentAdvance = false)
    {
        if (!PresentationLoaded || revision != followRevision || ViewportResizePending || browsing || !document.IsTimed || !lastPosition.HasValue || (!explicitRequest && WindowSizing.ScreenReaderActive)) return;
        AttachScroller(); if (scroller == null || items.Length == 0 || ViewportHeight <= 0) return;
        int index = Math.Max(0, activeIndex);
        if (!TryReadingBounds(items[index], out double y, out double height))
        {
            if (!realize) return;
            StopFollowMotion();
            pendingFollowRealization = (revision, items[index], explicitRequest);
            list.ScrollIntoView(items[index], ScrollIntoViewAlignment.Leading);
            ResumeRealizedFollow();
            return;
        }
        try
        {
            double target = LyricsViewport.FollowOffset(scroller.VerticalOffset, y, height, ViewportHeight, scroller.ScrollableHeight);
            if (Math.Abs(target - scroller.VerticalOffset) > .5)
            {
                if (!(animated && adjacentAdvance && CanAnimateFollow && StartFollowMotion(target)))
                {
                    StopFollowMotion();
                    scroller.ChangeView(null, target, null, disableAnimation: !animated);
                }
            }
            else if (!animated || !adjacentAdvance) StopFollowMotion();
        }
        catch (ArgumentException) { }
        QueueEdges();
    }
    internal void Register(LyricsRowPresenter row)
    {
        if (disposed) return;
        realized.Add(row);
        if (followMotion != null) followRowsNeedLayout = true;
        row.ApplyState(style: true);
        QueueEdges();
    }
    internal void Unregister(LyricsRowPresenter row)
    {
        ResetRowMotion(row);
        realized.Remove(row);
        pendingGlyphs.Remove(row);
        row.CancelQueuedDraw();
    }
    internal void RequestSeek(LyricsRowItem item)
    {
        if (disposed || !CanSeek || !ReferenceEquals(item.Owner, this) || item.Line.TimeMs is not ulong time || item.Index >= items.Length || !ReferenceEquals(items[item.Index], item)) return;
        StopFollowMotion();
        ClearReadingAnchor();
        browsing = false; ++followRevision; browsingTimer.Stop(); SeekRequested?.Invoke(time);
    }
    private void RefreshRows(bool style)
    {
        if (!PresentationLoaded) { rowsNeedStyle |= style; return; }
        bool applyStyle = style || rowsNeedStyle; rowsNeedStyle = false;
        foreach (var row in realized.ToArray()) row.ApplyState(applyStyle); QueueEdges();
    }
    private void QueueEdges()
    {
        if (!PresentationLoaded) return;
        if (InteractiveResize)
        {
            resizeEdgesPending = true;
            if (!glyphTimer.IsRunning) glyphTimer.Start();
            return;
        }
        if (edgeQueued) return;
        edgeQueued = DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            edgeQueued = false; if (!PresentationLoaded || InteractiveResize) return;
            foreach (var row in realized.ToArray()) row.UpdateEdge();
        });
    }
    private void RootChanged(XamlRoot sender, XamlRootChangedEventArgs args)
    {
        if (disposed) return;
        bool shown = RefreshPresentation(); double scale = sender.RasterizationScale;
        if (scale != observedRasterScale)
        {
            observedRasterScale = scale;
            foreach (var row in realized.ToArray()) row.InvalidateGlyphs();
        }
        else if (shown && PresentationLoaded) RefreshRows(style: false);
        // XamlRoot size, host visibility and unrelated XAML changes do not change glyphs.
    }
    private void ThemeChanged(FrameworkElement sender, object args) => RefreshEnvironment();
    private void EffectsChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(RefreshEnvironment);
    private void TextScaleChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(RefreshEnvironment);
    private void RefreshEnvironment()
    {
        if (disposed) return; bool changed = ReadEnvironment(); RefreshPresentation(); LocalizeEmpty(); RefreshRows(style: true);
        if (!MotionEnabled) StopFollowMotion();
        if (changed && !browsing) ScheduleFollow(animated: false);
    }
    private bool RefreshPresentation()
    {
        bool visible = true;
        for (DependencyObject? current = this; current != null; current = VisualTreeHelper.GetParent(current))
            if (current is FrameworkElement element && element.Visibility != Visibility.Visible) { visible = false; break; }
        bool changed = visible != presentationVisible; presentationVisible = visible;
        if (InteractiveResize && PresentationLoaded)
            heldResizeBodySize ??= ResponsiveBodySize;
        if (!visible && (changed || pendingGlyphs.Count > 0))
        {
            CancelGlyphQueue();
            ResetViewportMotion();
        }
        return changed;
    }
    internal LyricsGraphicsResources? GetGraphicsResources()
    {
        if (!PresentationLoaded || graphicsUnavailable) return null;
        if (graphicsResources != null) return graphicsResources;
        try { return graphicsResources = new LyricsGraphicsResources(ElementCompositionPreview.GetElementVisual(this).Compositor, QueueGraphicsRecovery); }
        catch (Exception error) when (error is COMException or ArgumentException or NotSupportedException) { graphicsUnavailable = true; return null; }
    }
    private void QueueGraphicsRecovery()
    {
        if (disposed || graphicsRecoveryQueued) return; graphicsRecoveryQueued = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            graphicsRecoveryQueued = false; if (disposed) return;
            CancelGlyphQueue(); foreach (var row in realized.ToArray()) row.ReleaseSurface();
            graphicsResources?.Dispose(); graphicsResources = null; graphicsUnavailable = false;
            foreach (var row in realized.ToArray()) row.InvalidateGlyphs(); QueueEdges();
        });
    }
    internal void QueueGlyphDraw(LyricsRowPresenter row)
    {
        if (!PresentationLoaded || !pendingGlyphs.Add(row)) return;
        glyphQueue.Enqueue(row); if (!glyphTimer.IsRunning) glyphTimer.Start();
    }
    private void DrawQueuedGlyphs(DispatcherQueueTimer sender, object args)
    {
        if (!PresentationLoaded) { CancelGlyphQueue(); return; }
        if (resizeEdgesPending)
        {
            resizeEdgesPending = false;
            foreach (var row in realized.ToArray()) row.UpdateEdge();
        }
        // Resize can invalidate several rows together. Bound their CPU uploads,
        // while scroll blur and fading continue immediately on the compositor.
        long started = Stopwatch.GetTimestamp(); int drawn = 0, remaining = glyphQueue.Count;
        while (remaining-- > 0 && glyphQueue.TryDequeue(out var row))
        {
            if (!pendingGlyphs.Contains(row)) continue;
            if (!row.GlyphUploadReady) { glyphQueue.Enqueue(row); continue; }
            pendingGlyphs.Remove(row);
            row.RenderPendingGlyphs(); drawn++;
            if (drawn >= (InteractiveResize ? 1 : 3) || Stopwatch.GetElapsedTime(started).TotalMilliseconds >= 4) break;
        }
        if (glyphQueue.Count > 0 || resizeEdgesPending) glyphTimer.Start();
    }
    private void CancelGlyphQueue()
    {
        glyphTimer.Stop(); resizeEdgesPending = false;
        foreach (var row in pendingGlyphs) row.CancelQueuedDraw(); pendingGlyphs.Clear(); glyphQueue.Clear();
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true; ++followRevision; browsingTimer.Stop(); browsingTimer.Tick -= BrowsingExpired; CancelGlyphQueue(); glyphTimer.Tick -= DrawQueuedGlyphs;
        LayoutUpdated -= ReadingLayoutUpdated;
        ResetViewportMotion();
        resizeQuietTimer.Tick -= ResizeQuietElapsed;
        followMotionTimer.Tick -= FollowMotionTick;
        followClock?.Dispose(); followClock = null;
        settings.AdvancedEffectsEnabledChanged -= EffectsChanged; settings.ColorValuesChanged -= EffectsChanged; settings.TextScaleFactorChanged -= TextScaleChanged; L.Changed -= Localize;
        if (subscribedRoot != null) subscribedRoot.Changed -= RootChanged; subscribedRoot = null; DetachScroller();
        foreach (var row in realized.ToArray()) { row.StopAnimations(); row.ReleaseSurface(); } realized.Clear(); list.ItemsSource = null; items = []; document = LyricsDocument.Empty; SeekRequested = null;
        graphicsResources?.Dispose(); graphicsResources = null;
    }
}

internal sealed record LyricsRowItem(LyricsView Owner, LyricsLine Line, int Index);
