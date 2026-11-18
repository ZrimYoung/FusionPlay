using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;

namespace FusionPlay.Windows.Platform;

/// <summary>Adds gentle content fades while NavigationView owns native pane geometry.</summary>
internal sealed class SettingsNavigationMotion : IDisposable
{
    private readonly NavigationView navigation;
    private readonly Func<bool> animationsEnabled;
    private readonly DispatcherQueueTimer timer;
    private readonly HashSet<FrameworkElement> animated = [];
    private FrameworkElement? content;
    private Action? pending;
    private long revision, dueAt;
    private bool disposed;
    internal bool IsTransitioning { get; private set; }
    internal long TransitionCount { get; private set; }
    internal long AnimationFailures { get; private set; }

    internal SettingsNavigationMotion(NavigationView navigation, Func<bool>? animationsEnabled = null)
    {
        this.navigation = navigation; this.animationsEnabled = animationsEnabled ?? (() => Backdrop.AnimationsEnabled);
        timer = navigation.DispatcherQueue.CreateTimer(); timer.IsRepeating = false; timer.Tick += Tick;
        navigation.PaneOpening += PaneOpening; navigation.PaneClosing += PaneClosing;
        navigation.PaneOpened += PaneSettled; navigation.PaneClosed += PaneSettled;
    }

    internal void PageChanged(FrameworkElement next, bool animate)
    {
        Cancel(); content = next;
        if (!animate || !Ready) return;
        long request = ++revision;
        IsTransitioning = true; TransitionCount++;
        try { Fade(next, .58f, 1, 190); Schedule(() => Finish(request), 210, request); }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; Finish(request); }
    }

    private bool Ready => !disposed && navigation.IsLoaded && navigation.XamlRoot != null && animationsEnabled();
    private static bool Recoverable(Exception error) => error is COMException or ObjectDisposedException or InvalidOperationException or ArgumentException;
    private void PaneOpening(NavigationView sender, object args) => BeginPane();
    private void PaneClosing(NavigationView sender, NavigationViewPaneClosingEventArgs args) => BeginPane();
    private void PaneSettled(NavigationView sender, object args)
    {
        // Native events are allowed to arrive after a reversal. They never
        // choose the target page or finish a newer content animation early.
        if (!Ready) Cancel();
    }
    private void BeginPane()
    {
        // A native reversal may arrive while a previous fade is playing. Keep
        // its presentation value so this request can continue from that value.
        ++revision; StopClock(); IsTransitioning = false; content = navigation.Content as FrameworkElement;
        if (!Ready) { Restore(); return; }
        long request = ++revision;
        IsTransitioning = true; TransitionCount++;
        try
        {
            if (content != null) Fade(content, null, .62f, 80);
            foreach (var item in navigation.MenuItems.OfType<NavigationViewItem>()) Fade(item, null, .65f, 80);
            Schedule(() => RevealPane(request), 90, request);
        }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; Finish(request); }
    }
    private void RevealPane(long request)
    {
        if (!Current(request)) return;
        try
        {
            if (content != null) Fade(content, null, 1, 190);
            foreach (var item in navigation.MenuItems.OfType<NavigationViewItem>()) Fade(item, null, 1, 190);
            Schedule(() => Finish(request), 210, request);
        }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; Finish(request); }
    }
    private void Fade(FrameworkElement element, float? from, float to, int milliseconds)
    {
        if (element.XamlRoot == null) return;
        var visual = ElementCompositionPreview.GetElementVisual(element);
        animated.Add(element);
        using var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
        using var easing = visual.Compositor.CreateCubicBezierEasingFunction(new(.22f, .61f), new(.36f, 1));
        if (from is float initial) animation.InsertKeyFrame(0, initial);
        else animation.InsertExpressionKeyFrame(0, "this.StartingValue");
        animation.InsertKeyFrame(1, to, easing); animation.Duration = TimeSpan.FromMilliseconds(milliseconds);
        visual.StartAnimation("Opacity", animation);
    }
    private bool Current(long request) => !disposed && IsTransitioning && request == revision;
    private void Schedule(Action action, int milliseconds, long request)
    {
        if (!Current(request)) return;
        pending = action; dueAt = Stopwatch.GetTimestamp() + (long)Math.Ceiling(milliseconds * (double)Stopwatch.Frequency / 1000);
        timer.Interval = TimeSpan.FromMilliseconds(milliseconds); timer.Start();
    }
    private void Tick(DispatcherQueueTimer sender, object args)
    {
        if (disposed || pending == null) { StopClock(); return; }
        if (!animationsEnabled()) { Cancel(); return; }
        long remaining = dueAt - Stopwatch.GetTimestamp();
        if (remaining > 0)
        {
            timer.Stop(); timer.Interval = TimeSpan.FromMilliseconds(Math.Max(1, remaining * 1000.0 / Stopwatch.Frequency)); timer.Start(); return;
        }
        var action = pending; StopClock(); action?.Invoke();
    }
    private void StopClock() { timer.Stop(); pending = null; dueAt = 0; }
    private void Finish(long request)
    {
        if (!Current(request)) return;
        StopClock(); IsTransitioning = false; Restore();
    }
    private void Restore()
    {
        void Reset(FrameworkElement element)
        {
            try { var visual = ElementCompositionPreview.GetElementVisual(element); visual.StopAnimation("Opacity"); visual.Opacity = 1; }
            catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
        }
        foreach (var element in animated) Reset(element);
        animated.Clear();
    }
    internal void Cancel() { ++revision; StopClock(); IsTransitioning = false; Restore(); }
    public void Dispose()
    {
        if (disposed) return;
        Cancel(); disposed = true;
        timer.Tick -= Tick; navigation.PaneOpening -= PaneOpening; navigation.PaneClosing -= PaneClosing;
        navigation.PaneOpened -= PaneSettled; navigation.PaneClosed -= PaneSettled; content = null;
    }
}
