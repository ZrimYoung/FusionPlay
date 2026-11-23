using System.Numerics;
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
    internal const double HeaderHeight = 44;
    private readonly FrameworkElement surface, player, lyrics;
    private readonly Button focusTarget;
    private readonly Func<bool> canInteract, canAnimate;
    private readonly Action pageChanged;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    private Pointer? pressedPointer;
    private LyricsRowPresenter? pressedLyric;
    private Point pressPoint;
    private bool horizontal;
    private double width;

    internal bool Active { get; private set; }
    internal bool ShowingLyrics { get; private set; }
    internal bool Animating => timer.IsRunning;

    internal CompactLyricsPager(FrameworkElement surface, FrameworkElement player, FrameworkElement lyrics, Button focusTarget,
        Func<bool> canInteract, Func<bool> canAnimate, Action pageChanged)
    {
        this.surface = surface; this.player = player; this.lyrics = lyrics; this.focusTarget = focusTarget;
        this.canInteract = canInteract; this.canAnimate = canAnimate; this.pageChanged = pageChanged;
        ElementCompositionPreview.SetIsTranslationEnabled(player, true);
        ElementCompositionPreview.SetIsTranslationEnabled(lyrics, true);
        timer = surface.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(TransitionMilliseconds);
        timer.IsRepeating = false;
        timer.Tick += TransitionCompleted;
        surface.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(Pressed), true);
        surface.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler(Moved), true);
        surface.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(Released), true);
        surface.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler(Canceled), true);
        surface.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler(CaptureLost), true);
        surface.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler(WheelChanged), true);
    }

    internal void Configure(bool active, double pageWidth)
    {
        if (Active == active && width == pageWidth) return;
        if (!Active && !active) { width = pageWidth; return; }
        Active = active; width = pageWidth;
        CancelGesture();
        Settle();
    }

    internal void ResetToPlayer()
    {
        if (!ShowingLyrics) return;
        ShowingLyrics = false;
        Settle();
    }

    internal bool Navigate(bool showLyrics)
    {
        if (!Active || !canInteract() || ShowingLyrics == showLyrics) return false;
        var outgoing = ShowingLyrics ? lyrics : player;
        if (surface.XamlRoot is { IsHostVisible: true } root && FocusManager.GetFocusedElement(root) is DependencyObject focused &&
            IsWithin(focused, outgoing))
            focusTarget.Focus(FocusState.Programmatic);
        ShowingLyrics = showLyrics;
        if (!canAnimate()) Settle();
        else
        {
            player.Visibility = lyrics.Visibility = Visibility.Visible;
            Translate(player, PlayerX, animate: true);
            Translate(lyrics, LyricsX, animate: true);
            timer.Stop(); timer.Start();
            pageChanged();
        }
        return true;
    }

    internal void Settle()
    {
        timer.Stop();
        Translate(player, Active ? PlayerX : 0, animate: false);
        Translate(lyrics, Active ? LyricsX : 0, animate: false);
        player.Visibility = !Active || !ShowingLyrics ? Visibility.Visible : Visibility.Collapsed;
        if (Active) lyrics.Visibility = ShowingLyrics ? Visibility.Visible : Visibility.Collapsed;
        pageChanged();
    }

    internal void FinishInteraction()
    {
        CancelGesture();
        if (Animating) Settle();
    }

    private float PlayerX => ShowingLyrics ? (float)-width : 0;
    private float LyricsX => ShowingLyrics ? 0 : (float)width;

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

    private void TransitionCompleted(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args) => Settle();

    private void Pressed(object sender, PointerRoutedEventArgs args)
    {
        if (!Active || !canInteract() || Animating) return;
        if (pressedPointer != null) { CancelGesture(); return; }
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
        double x = Math.Abs(point.X - pressPoint.X), y = Math.Abs(point.Y - pressPoint.Y);
        if (horizontal) { args.Handled = true; return; }
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
        args.Handled = true;
    }

    private void Released(object sender, PointerRoutedEventArgs args)
    {
        if (pressedPointer?.PointerId != args.Pointer.PointerId) return;
        var point = args.GetCurrentPoint(surface).Position;
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
        if (pressedPointer?.PointerId == args.Pointer.PointerId) CancelGesture();
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
        if (!Animating) Navigate(point.Properties.MouseWheelDelta > 0);
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
        pressedPointer = null;
        pressedLyric = null;
        if (horizontal && pointer != null) surface.ReleasePointerCapture(pointer);
        horizontal = false;
    }

    public void Dispose()
    {
        CancelGesture();
        timer.Stop();
        timer.Tick -= TransitionCompleted;
    }
}
