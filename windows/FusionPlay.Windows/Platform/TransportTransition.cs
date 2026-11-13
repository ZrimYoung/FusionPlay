using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

/// <summary>Collapses a player section without leaving a blank row or restarting on state polling.</summary>
internal sealed class TransportTransition : IDisposable
{
    private readonly FrameworkElement element;
    private readonly double fallbackHeight, visibleOpacity;
    private readonly bool visibleHitTesting;
    private readonly RectangleGeometry? originalClip;
    private readonly RectangleGeometry? boundsClip;
    private Storyboard? animation;
    private EventHandler<object>? completed;
    private bool? target;
    private long version;
    private bool disposed;

    public TransportTransition(FrameworkElement element, double visibleHeight = 44, bool clipToBounds = false)
    {
        ArgumentNullException.ThrowIfNull(element);
        if (!double.IsFinite(visibleHeight) || visibleHeight < 0)
            throw new ArgumentOutOfRangeException(nameof(visibleHeight));
        this.element = element; fallbackHeight = visibleHeight;
        visibleOpacity = element.Opacity;
        visibleHitTesting = element.IsHitTestVisible;
        if (clipToBounds)
        {
            originalClip = element.Clip;
            boundsClip = new RectangleGeometry(); element.Clip = boundsClip;
            element.SizeChanged += SizeChanged; UpdateClip();
        }
    }

    public void SetVisible(bool visible, bool animate)
    {
        if (disposed) return;
        if (target == visible)
        {
            if (!animate && animation != null) { Stop(); Snap(visible); }
            return;
        }
        bool first = target == null;
        target = visible;
        // Read effective animated values before Stop restores their base values.
        double fromHeight = element.Visibility == Visibility.Collapsed ? 0
            : double.IsFinite(element.Height) ? Math.Max(0, element.Height) : Math.Max(0, element.ActualHeight);
        double fromOpacity = element.Visibility == Visibility.Collapsed ? 0 : element.Opacity;
        Stop();
        if (first || !animate) { Snap(visible); return; }

        double toHeight = visible ? MeasureVisibleHeight() : 0;
        element.Visibility = Visibility.Visible;
        element.IsHitTestVisible = visible && visibleHitTesting;
        element.Height = fromHeight;
        element.Opacity = fromOpacity;
        if (Math.Abs(toHeight - fromHeight) < 0.1 && Math.Abs((visible ? visibleOpacity : 0) - fromOpacity) < 0.01)
        {
            Snap(visible); return;
        }

        var storyboard = new Storyboard();
        var duration = new Duration(TimeSpan.FromMilliseconds(220));
        var height = new DoubleAnimation
        {
            From = fromHeight, To = toHeight, Duration = duration, EnableDependentAnimation = true,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut }
        };
        var opacity = new DoubleAnimation
        {
            From = fromOpacity, To = visible ? visibleOpacity : 0, Duration = duration,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut }
        };
        Storyboard.SetTarget(height, element); Storyboard.SetTargetProperty(height, "Height");
        Storyboard.SetTarget(opacity, element); Storyboard.SetTargetProperty(opacity, "Opacity");
        storyboard.Children.Add(height); storyboard.Children.Add(opacity);
        long request = version;
        completed = (_, _) =>
        {
            if (disposed || request != version || !ReferenceEquals(animation, storyboard)) return;
            Stop(); Snap(visible);
        };
        animation = storyboard; storyboard.Completed += completed;
        storyboard.Begin();
    }

    private double MeasureVisibleHeight()
    {
        element.Visibility = Visibility.Visible;
        element.Height = double.NaN;
        double width = element.ActualWidth;
        if (width <= 0 && element.Parent is FrameworkElement parent) width = parent.ActualWidth;
        element.Measure(new Size(width > 0 ? width : double.PositiveInfinity, double.PositiveInfinity));
        double desired = element.DesiredSize.Height - element.Margin.Top - element.Margin.Bottom;
        return double.IsFinite(desired) && desired > 0 ? desired : fallbackHeight;
    }

    private void Snap(bool visible)
    {
        element.Height = double.NaN;
        element.Opacity = visible ? visibleOpacity : 0;
        element.IsHitTestVisible = visible && visibleHitTesting;
        element.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Stop()
    {
        ++version;
        if (animation == null) return;
        if (completed != null) animation.Completed -= completed;
        animation.Stop(); animation.Children.Clear();
        animation = null; completed = null;
    }
    private void SizeChanged(object sender, SizeChangedEventArgs args) => UpdateClip();
    private void UpdateClip()
    {
        if (boundsClip != null) boundsClip.Rect = new Rect(0, 0, Math.Max(0, element.ActualWidth), Math.Max(0, element.ActualHeight));
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        Stop();
        Snap(target ?? element.Visibility == Visibility.Visible);
        if (boundsClip != null) { element.SizeChanged -= SizeChanged; element.Clip = originalClip; }
    }
}
