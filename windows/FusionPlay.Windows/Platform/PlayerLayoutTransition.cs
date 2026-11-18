using System.Numerics;
using System.Runtime.InteropServices;
using System.Diagnostics;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

/// <summary>Fades only reflowing content and bridges one layout commit with compositor transforms.</summary>
internal sealed class PlayerLayoutTransition : IDisposable
{
    private readonly FrameworkElement root;
    private readonly FrameworkElement[] fading;
    private readonly (FrameworkElement Element, bool Scale)[] moving;
    private readonly DispatcherQueueTimer timer;
    private Action? next, pendingCommit, completion;
    private bool disposed, committed;
    private long revision, dueAt;
    public bool IsRunning { get; private set; }
    internal long AnimationFailures { get; private set; }

    public PlayerLayoutTransition(FrameworkElement root, FrameworkElement[] fading, (FrameworkElement Element, bool Scale)[] moving)
    {
        this.root = root; this.fading = fading; this.moving = moving;
        timer = root.DispatcherQueue.CreateTimer(); timer.IsRepeating = false; timer.Tick += Tick;
        foreach (var item in moving) ElementCompositionPreview.SetIsTranslationEnabled(item.Element, true);
    }

    public void Run(Action commit, Action completed, bool animate)
    {
        if (disposed) return;
        ArgumentNullException.ThrowIfNull(commit); ArgumentNullException.ThrowIfNull(completed);
        long request = ++revision;
        StopClock();
        IsRunning = true; committed = false; pendingCommit = commit; completion = completed;
        if (!animate)
        {
            Fallback(request); return;
        }
        // Replacing an opacity animation samples its presentation value. A
        // rapid reversal therefore never jumps to a hard-coded zero or one.
        try
        {
            foreach (var element in fading) Fade(element, 0, 110);
            Schedule(() => ApplyLayout(request), 120, request);
        }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; Fallback(request); }
    }

    private bool Current(long request) => !disposed && IsRunning && request == revision;
    private static bool Recoverable(Exception error) => error is COMException or ObjectDisposedException or InvalidOperationException or ArgumentException;
    private bool Commit(long request)
    {
        if (!Current(request)) return false;
        if (!committed)
        {
            committed = true; var action = pendingCommit; pendingCommit = null;
            try { action?.Invoke(); }
            catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
        }
        // A layout callback can synchronously request another layout, cancel,
        // or close its window. Never let the old stage replace its new timer.
        return Current(request);
    }
    private void ApplyLayout(long request)
    {
        if (!Current(request)) return;
        try
        {
            var before = moving.ToDictionary(item => item.Element, item => Bounds(item.Element));
            if (!Commit(request)) return;
            root.UpdateLayout();
            if (!Current(request)) return;
            foreach (var item in moving)
            {
                var old = before[item.Element]; var current = Bounds(item.Element);
                if (old is { } from && current is { } to) Move(item.Element, from, to, item.Scale);
            }
            foreach (var element in fading) Fade(element, 1, 320);
            Schedule(() => Finish(request), 330, request);
        }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; Fallback(request); }
    }
    private void Fallback(long request)
    { if (Commit(request)) Finish(request); }
    private void Finish(long request)
    {
        if (!Current(request)) return;
        StopClock(); pendingCommit = null; var action = completion; completion = null;
        IsRunning = false; ResetVisuals();
        // State is terminal before calling the owner. Reentrant Run is allowed
        // and no old cleanup occurs after that new request has started.
        try { action?.Invoke(); }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
    }

    private Rect? Bounds(FrameworkElement element)
    {
        if (element.ActualWidth <= 0 || element.ActualHeight <= 0) return null;
        for (DependencyObject? parent = element; parent != null; parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is UIElement { Visibility: Visibility.Collapsed }) return null;
            if (ReferenceEquals(parent, root)) break;
        }
        return element.TransformToVisual(root).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
    }

    private static void Fade(FrameworkElement element, float opacity, int milliseconds)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        using var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
        using var ease = visual.Compositor.CreateCubicBezierEasingFunction(new(.22f, .61f), new(.36f, 1));
        animation.InsertExpressionKeyFrame(0, "this.StartingValue"); animation.InsertKeyFrame(1, opacity, ease);
        animation.Duration = TimeSpan.FromMilliseconds(milliseconds); visual.StartAnimation("Opacity", animation);
    }

    private static void Move(FrameworkElement element, Rect from, Rect to, bool scale)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element);
        using var animation = visual.Compositor.CreateVector3KeyFrameAnimation();
        using var ease = visual.Compositor.CreateCubicBezierEasingFunction(new(.22f, .61f), new(.36f, 1));
        animation.SetVector3Parameter("delta", new((float)(from.X - to.X), (float)(from.Y - to.Y), 0));
        animation.InsertExpressionKeyFrame(0, "this.StartingValue + delta"); animation.InsertKeyFrame(1, Vector3.Zero, ease);
        animation.Duration = TimeSpan.FromMilliseconds(320); visual.Properties.StartAnimation("Translation", animation);
        if (!scale || to.Width <= 0 || to.Height <= 0) return;
        using var zoom = visual.Compositor.CreateVector3KeyFrameAnimation();
        zoom.SetVector3Parameter("ratio", new((float)(from.Width / to.Width), (float)(from.Height / to.Height), 1));
        zoom.InsertExpressionKeyFrame(0, "this.StartingValue * ratio"); zoom.InsertKeyFrame(1, Vector3.One, ease);
        zoom.Duration = animation.Duration; visual.CenterPoint = Vector3.Zero; visual.StartAnimation("Scale", zoom);
    }

    private void Schedule(Action action, int milliseconds, long request)
    {
        if (!Current(request)) return;
        next = action;
        dueAt = Stopwatch.GetTimestamp() + (long)Math.Ceiling(milliseconds * (double)Stopwatch.Frequency / 1000);
        timer.Interval = TimeSpan.FromMilliseconds(milliseconds); timer.Start();
    }
    private void StopClock()
    {
        next = null; dueAt = 0;
        try { timer.Stop(); }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
    }
    private void Tick(DispatcherQueueTimer sender, object args)
    {
        if (disposed || next == null) { StopClock(); return; }
        // Stop need not retract a Tick already queued on the dispatcher. Such
        // a stale Tick must not consume the newly scheduled request's action.
        long remaining = dueAt - Stopwatch.GetTimestamp();
        if (remaining > 0)
        {
            try
            {
                timer.Stop();
                timer.Interval = TimeSpan.FromMilliseconds(Math.Max(1, remaining * 1000.0 / Stopwatch.Frequency));
                timer.Start();
            }
            catch (Exception error) when (Recoverable(error)) { AnimationFailures++; Fallback(revision); }
            return;
        }
        var action = next; StopClock(); if (!disposed) action?.Invoke();
    }
    private void ResetVisuals()
    {
        foreach (var element in fading)
        {
            try
            {
                var visual = ElementCompositionPreview.GetElementVisual(element);
                visual.StopAnimation("Opacity"); visual.Opacity = 1;
            }
            catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
        }
        foreach (var item in moving)
        {
            try
            {
                var visual = ElementCompositionPreview.GetElementVisual(item.Element);
                visual.Properties.StopAnimation("Translation"); visual.Properties.InsertVector3("Translation", Vector3.Zero);
                visual.StopAnimation("Scale"); visual.Scale = Vector3.One;
            }
            catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
        }
    }
    public void Cancel()
    { ++revision; StopClock(); pendingCommit = completion = null; IsRunning = false; ResetVisuals(); }
    public void Dispose()
    {
        if (disposed) return; Cancel(); disposed = true;
        try { timer.Tick -= Tick; }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
    }
}
