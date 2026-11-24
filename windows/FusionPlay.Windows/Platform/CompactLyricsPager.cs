using System.Diagnostics;
using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

/// <summary>Pages the existing compact player and its native lyrics view without replacing either.</summary>
internal sealed class CompactLyricsPager : IDisposable
{
    private const int TransitionMilliseconds = 240;
    private const int WheelPauseMilliseconds = 90;
    internal const double HeaderHeight = 44;
    private readonly FrameworkElement surface, player, lyrics;
    private readonly Button focusTarget, fallbackFocusTarget;
    private readonly Func<bool> canInteract, canAnimate;
    private readonly Action pageChanged;
    private readonly DispatcherQueueTimer timer, wheelTimer;
    private Pointer? pressedPointer;
    private LyricsRowPresenter? pressedLyric;
    private Point pressPoint;
    private bool horizontal, wheelGesture, coverExpressionAttached;
    private double width, wheelDisplacement;
    private float coverProgress, coverDragStart;
    private (float From, float To, long Started, TimeSpan Duration)? coverTransition;

    internal bool Active { get; private set; }
    internal bool ShowingLyrics { get; private set; }
    internal bool StationaryCover { get; private set; }
    internal bool Dragging { get; private set; }
    internal bool Animating => timer.IsRunning;
    internal CompositionPropertySet CoverMotion { get; }
    internal float CoverProgress
    {
        get
        {
            if (coverTransition is not { } transition) return coverProgress;
            double remaining = 1 - Math.Clamp(Stopwatch.GetElapsedTime(transition.Started) / transition.Duration, 0, 1);
            return transition.To + (transition.From - transition.To) * (float)(remaining * remaining * remaining);
        }
    }

    internal CompactLyricsPager(FrameworkElement surface, FrameworkElement player, FrameworkElement lyrics, Button focusTarget, Button fallbackFocusTarget,
        Func<bool> canInteract, Func<bool> canAnimate, Action pageChanged)
    {
        this.surface = surface; this.player = player; this.lyrics = lyrics; this.focusTarget = focusTarget; this.fallbackFocusTarget = fallbackFocusTarget;
        this.canInteract = canInteract; this.canAnimate = canAnimate; this.pageChanged = pageChanged;
        ElementCompositionPreview.SetIsTranslationEnabled(player, true);
        ElementCompositionPreview.SetIsTranslationEnabled(lyrics, true);
        CoverMotion = ElementCompositionPreview.GetElementVisual(surface).Compositor.CreatePropertySet();
        CoverMotion.InsertScalar("Width", 0);
        CoverMotion.InsertScalar("Progress", 0);
        timer = surface.DispatcherQueue.CreateTimer();
        timer.IsRepeating = false;
        timer.Tick += TransitionCompleted;
        wheelTimer = surface.DispatcherQueue.CreateTimer();
        wheelTimer.Interval = TimeSpan.FromMilliseconds(WheelPauseMilliseconds);
        wheelTimer.IsRepeating = false;
        wheelTimer.Tick += WheelCompleted;
        surface.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(Pressed), true);
        surface.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(Moved), true);
        surface.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(Released), true);
        surface.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler(Canceled), true);
        surface.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler(CaptureLost), true);
        surface.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler(WheelChanged), true);
    }

    internal void Configure(bool active, double pageWidth, bool stationaryCover = false)
    {
        stationaryCover &= active;
        if (Active == active && width == pageWidth && StationaryCover == stationaryCover) return;
        if (!Active && !active) { width = pageWidth; return; }
        Active = active; width = pageWidth; StationaryCover = stationaryCover;
        CoverMotion.InsertScalar("Width", (float)pageWidth);
        CancelGesture();
        Settle();
    }

    internal void ResetToPlayer()
    {
        if (!ShowingLyrics && !Animating && !Dragging) return;
        ShowingLyrics = false;
        CancelGesture();
        Settle();
    }

    internal bool Navigate(bool showLyrics)
    {
        if (!Active || !canInteract() || ShowingLyrics == showLyrics) return false;
        bool animate = canAnimate();
        TransferFocus();
        if (StationaryCover)
        {
            CancelGesture();
            SettleCoverDrag(showLyrics, animate);
            return true;
        }
        ShowingLyrics = showLyrics;
        if (!animate) Settle();
        else
        {
            player.Visibility = lyrics.Visibility = Visibility.Visible;
            Translate(player, PlayerX, animate: true);
            Translate(lyrics, LyricsX, animate: true);
            timer.Stop(); timer.Interval = TimeSpan.FromMilliseconds(TransitionMilliseconds); timer.Start();
            pageChanged();
        }
        return true;
    }

    private void TransferFocus()
    {
        var outgoing = ShowingLyrics ? lyrics : player;
        if (surface.XamlRoot is { IsHostVisible: true } root && FocusManager.GetFocusedElement(root) is DependencyObject focused &&
            IsWithin(focused, outgoing))
        {
            if (focusTarget.Visibility == Visibility.Visible && focusTarget.Focus(FocusState.Programmatic)) return;
            fallbackFocusTarget.Focus(FocusState.Programmatic);
        }
    }

    internal void Settle()
    {
        timer.Stop();
        ClearCoverTransition(StationaryCover && ShowingLyrics ? 1 : 0);
        Translate(player, Active && !StationaryCover ? PlayerX : 0, animate: false);
        if (StationaryCover) AttachCoverExpression();
        else
        {
            Translate(lyrics, Active ? LyricsX : 0, animate: false);
            coverExpressionAttached = false;
        }
        player.Visibility = !Active || StationaryCover || !ShowingLyrics ? Visibility.Visible : Visibility.Collapsed;
        if (Active) lyrics.Visibility = ShowingLyrics ? Visibility.Visible : Visibility.Collapsed;
        pageChanged();
    }

    internal void FinishInteraction()
    {
        bool shouldSettle = Dragging || Animating;
        CancelGesture();
        if (shouldSettle) Settle();
    }

    private float PlayerX => ShowingLyrics ? (float)-width : 0;
    private float LyricsX => ShowingLyrics ? 0 : (float)width;

    private void AttachCoverExpression()
    {
        if (coverExpressionAttached) return;
        var visual = ElementCompositionPreview.GetElementVisual(lyrics);
        using var expression = visual.Compositor.CreateExpressionAnimation("Vector3(motion.Width * (1 - motion.Progress), 0, 0)");
        expression.SetReferenceParameter("motion", CoverMotion);
        visual.Properties.StartAnimation("Translation", expression);
        coverExpressionAttached = true;
    }

    private void ClearCoverTransition(float progress)
    {
        if (coverTransition != null) CoverMotion.StopAnimation("Progress");
        coverTransition = null;
        SetCoverProgress(progress);
    }

    private void SetCoverProgress(float progress)
    {
        coverProgress = progress;
        CoverMotion.InsertScalar("Progress", progress);
    }

    private void BeginCoverDrag()
    {
        float start = CoverProgress;
        timer.Stop();
        ClearCoverTransition(start);
        coverDragStart = start;
        Dragging = true;
        lyrics.Visibility = Visibility.Visible;
        pageChanged();
    }

    private void PreviewCoverDrag(double displacement)
    {
        float progress = (float)Math.Clamp(coverDragStart - displacement / Math.Max(1, width), 0, 1);
        if (coverProgress != progress) SetCoverProgress(progress);
    }

    private bool CompleteCoverDrag(double displacement, double orthogonalDisplacement)
    {
        PreviewCoverDrag(displacement);
        int direction = SwipeDirection(displacement, orthogonalDisplacement, width);
        bool showLyrics = direction == 0 ? ShowingLyrics : direction < 0;
        if (showLyrics != ShowingLyrics) TransferFocus();
        CancelGesture();
        SettleCoverDrag(showLyrics, canAnimate());
        return direction != 0;
    }

    private void SettleCoverDrag(bool showLyrics, bool animate)
    {
        float start = CoverProgress, target = showLyrics ? 1 : 0;
        ShowingLyrics = showLyrics;
        if (!animate || Math.Abs(start - target) < .001f) { Settle(); return; }

        timer.Stop();
        ClearCoverTransition(start);
        lyrics.Visibility = Visibility.Visible;
        var duration = TimeSpan.FromMilliseconds(100 + 140 * Math.Abs(start - target));
        using var animation = CoverMotion.Compositor.CreateScalarKeyFrameAnimation();
        // The x control points make time linear. On grip takeover the same
        // cubic ease-out gives the visual's location instead of its old target.
        using var easing = CoverMotion.Compositor.CreateCubicBezierEasingFunction(new(1f / 3, 1), new(2f / 3, 1));
        animation.InsertKeyFrame(0, start);
        animation.InsertKeyFrame(1, target, easing);
        animation.Duration = duration;
        coverTransition = (start, target, Stopwatch.GetTimestamp(), duration);
        CoverMotion.StartAnimation("Progress", animation);
        timer.Interval = duration;
        timer.Start();
        pageChanged();
    }

    private static void Translate(FrameworkElement element, float x, bool animate)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        var offset = new Vector3(x, 0, 0);
        if (!animate)
        {
            visual.Properties.StopAnimation("Translation");
            visual.Properties.InsertVector3("Translation", offset);
            return;
        }
        using var animation = visual.Compositor.CreateVector3KeyFrameAnimation();
        using var easing = visual.Compositor.CreateCubicBezierEasingFunction(new(.25f, .65f), new(.32f, 1));
        animation.InsertExpressionKeyFrame(0, "this.StartingValue");
        animation.InsertKeyFrame(1, offset, easing);
        animation.Duration = TimeSpan.FromMilliseconds(TransitionMilliseconds);
        visual.Properties.StartAnimation("Translation", animation);
    }

    private void TransitionCompleted(DispatcherQueueTimer sender, object args)
    {
        if (StationaryCover && coverTransition is not { }) return;
        Settle();
    }

    private void Pressed(object sender, PointerRoutedEventArgs args)
    {
        if (!Active || !canInteract() || Animating && !StationaryCover || wheelGesture) return;
        if (pressedPointer != null) { CancelInput(); return; }
        var point = args.GetCurrentPoint(surface);
        if (point.Position.Y < HeaderHeight || args.OriginalSource is not DependencyObject source || IsPlayerControl(source)) return;
        if (args.Pointer.PointerDeviceType == PointerDeviceType.Mouse &&
            (!point.Properties.IsLeftButtonPressed || point.Properties.IsRightButtonPressed || point.Properties.IsMiddleButtonPressed)) return;
        pressedPointer = args.Pointer;
        pressPoint = point.Position;
        for (DependencyObject? item = source; item != null && item != surface; item = VisualTreeHelper.GetParent(item))
        {
            if (item is not LyricsRowPresenter row) continue;
            pressedLyric = row;
            break;
        }
    }

    private void Moved(object sender, PointerRoutedEventArgs args)
    {
        if (pressedPointer?.PointerId != args.Pointer.PointerId) return;
        var point = args.GetCurrentPoint(surface).Position;
        double displacement = point.X - pressPoint.X;
        double x = Math.Abs(displacement), y = Math.Abs(point.Y - pressPoint.Y);
        if (horizontal)
        {
            if (StationaryCover) PreviewCoverDrag(displacement);
            args.Handled = true; return;
        }
        if (y >= 12 && y >= x) { CancelGesture(); return; }
        if (x < 14 || x <= y * 1.4) return;
        if (!surface.CapturePointer(args.Pointer))
        {
            // A lyric button can hold the original tap capture. Yield it only
            // after horizontal intent, so a tap and a vertical scroll stay native.
            if (pressedLyric == null) return;
            pressedLyric.ReleasePointerCapture(args.Pointer);
            if (!surface.CapturePointer(args.Pointer)) { CancelGesture(); return; }
        }
        horizontal = true;
        if (StationaryCover)
        {
            BeginCoverDrag();
            PreviewCoverDrag(displacement);
        }
        args.Handled = true;
    }

    private void Released(object sender, PointerRoutedEventArgs args)
    {
        if (pressedPointer?.PointerId != args.Pointer.PointerId) return;
        var point = args.GetCurrentPoint(surface).Position;
        if (horizontal && StationaryCover)
        {
            CompleteCoverDrag(point.X - pressPoint.X, point.Y - pressPoint.Y);
            args.Handled = true;
            return;
        }
        bool consumed = horizontal;
        int direction = SwipeDirection(point.X - pressPoint.X, point.Y - pressPoint.Y, width);
        CancelGesture();
        if (consumed)
        {
            if (direction != 0) Navigate(direction < 0);
            args.Handled = true;
        }
    }

    internal static int SwipeDirection(double x, double y, double width)
        => Math.Abs(x) >= Math.Max(36, width * .12) && Math.Abs(x) > Math.Abs(y) * 1.4 ? Math.Sign(x) : 0;

    private void Canceled(object sender, PointerRoutedEventArgs args)
    {
        if (pressedPointer?.PointerId == args.Pointer.PointerId) CancelInput();
    }

    private void CaptureLost(object sender, PointerRoutedEventArgs args)
    {
        if (ReferenceEquals(args.OriginalSource, surface)) Canceled(sender, args);
    }

    private void WheelChanged(object sender, PointerRoutedEventArgs args)
    {
        if (!Active || !canInteract() || pressedPointer != null || args.OriginalSource is not DependencyObject source || IsPlayerControl(source)) return;
        var point = args.GetCurrentPoint(surface);
        if (!point.Properties.IsHorizontalMouseWheel || point.Properties.MouseWheelDelta == 0) return;
        args.Handled = true;
        int delta = point.Properties.MouseWheelDelta;
        if (!StationaryCover || !Dragging && Math.Abs(delta) >= 120)
        {
            if (!Animating || StationaryCover) Navigate(delta > 0);
            return;
        }
        if (!Dragging)
        {
            wheelDisplacement = 0;
            wheelGesture = true;
            BeginCoverDrag();
        }
        // Precision touchpads send smaller wheel deltas throughout a swipe.
        // Keep that stream continuous and snap only after a pause.
        wheelDisplacement -= delta;
        PreviewCoverDrag(wheelDisplacement);
        wheelTimer.Stop(); wheelTimer.Start();
    }

    private void WheelCompleted(DispatcherQueueTimer sender, object args)
    {
        if (wheelGesture) CompleteCoverDrag(wheelDisplacement, 0);
    }

    private bool IsPlayerControl(DependencyObject source)
    {
        for (DependencyObject? item = source; item != null && item != surface; item = VisualTreeHelper.GetParent(item))
            if (item is (ButtonBase and not LyricsRowPresenter) or ScrollBar or Thumb or Slider or TextBox) return true;
        return false;
    }

    private static bool IsWithin(DependencyObject item, DependencyObject ancestor)
    {
        for (DependencyObject? parent = item; parent != null; parent = VisualTreeHelper.GetParent(parent))
            if (parent == ancestor) return true;
        return false;
    }

    private void CancelGesture()
    {
        var pointer = pressedPointer;
        bool captured = horizontal;
        pressedPointer = null;
        pressedLyric = null;
        horizontal = false;
        wheelGesture = false;
        Dragging = false;
        wheelTimer.Stop();
        if (captured && pointer != null) surface.ReleasePointerCapture(pointer);
    }

    private void CancelInput()
    {
        bool settle = Dragging;
        CancelGesture();
        if (settle) SettleCoverDrag(ShowingLyrics, canAnimate());
    }

    public void Dispose()
    {
        CancelGesture();
        timer.Stop();
        timer.Tick -= TransitionCompleted;
        wheelTimer.Tick -= WheelCompleted;
        CoverMotion.StopAnimation("Progress");
        if (coverExpressionAttached) ElementCompositionPreview.GetElementVisual(lyrics).Properties.StopAnimation("Translation");
        CoverMotion.Dispose();
    }
}
