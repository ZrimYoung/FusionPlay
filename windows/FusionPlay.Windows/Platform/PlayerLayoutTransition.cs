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
    private readonly FrameworkElement[] scenes;
    private readonly Func<FrameworkElement>? activeScene;
    private readonly (FrameworkElement First, FrameworkElement Second)[] semanticPairs;
    private readonly Func<(Point Origin, double Scale)> clientFrame;
    private sealed record Snapshot(Dictionary<FrameworkElement, Rect?> Bounds, FrameworkElement? Scene, double Width, double Height,
        Point Origin, double Scale, HashSet<FrameworkElement> VisibleScenes);
    private sealed record SceneStyle(double Width, double Height, HorizontalAlignment Horizontal, VerticalAlignment Vertical);
    private sealed record SceneTransform(Point Origin, Vector3 Translation, float Scale);
    internal sealed record BridgeGeometry(string Element, Rect From, Rect To);
    private readonly Dictionary<FrameworkElement, SceneStyle> sceneStyles = [];
    private readonly Dictionary<FrameworkElement, SceneTransform> sceneTransforms = [];
    private readonly List<BridgeGeometry> bridges = [];
    private Snapshot? captured, remembered;
    internal FrameworkElement? RetainedScene { get; private set; }
    internal IReadOnlyList<BridgeGeometry> LastBridges => bridges;
    internal long ParentNormalizations { get; private set; }
    private Action? next, pendingCommit, completion;
    private bool disposed, committed;
    private long revision, dueAt;
    public bool IsRunning { get; private set; }
    internal long AnimationFailures { get; private set; }

    public PlayerLayoutTransition(FrameworkElement root, FrameworkElement[] fading, (FrameworkElement Element, bool Scale)[] moving,
        FrameworkElement[]? scenes = null, Func<FrameworkElement>? activeScene = null,
        (FrameworkElement First, FrameworkElement Second)[]? semanticPairs = null, Func<(Point Origin, double Scale)>? clientFrame = null)
    {
        this.root = root; this.fading = fading; this.moving = moving;
        this.scenes = scenes ?? []; this.activeScene = activeScene; this.semanticPairs = semanticPairs ?? [];
        this.clientFrame = clientFrame ?? (() => (new Point(), root.XamlRoot?.RasterizationScale ?? 1));
        timer = root.DispatcherQueue.CreateTimer(); timer.IsRepeating = false; timer.Tick += Tick;
        foreach (var item in moving) ElementCompositionPreview.SetIsTranslationEnabled(item.Element, true);
        foreach (var scene in this.scenes) ElementCompositionPreview.SetIsTranslationEnabled(scene, true);
    }

    private Snapshot TakeSnapshot()
    {
        var frame = clientFrame(); var scene = activeScene?.Invoke();
        return new(moving.Select(item => item.Element).Concat(fading).Distinct().ToDictionary(element => element, SnapshotBounds),
            scene, scene?.ActualWidth ?? 0, scene?.ActualHeight ?? 0, frame.Origin, Math.Max(.01, frame.Scale),
            scenes.Where(scene => scene.Visibility == Visibility.Visible).ToHashSet());
    }
    public void Remember()
    { if (!disposed && !IsRunning && captured == null) remembered = TakeSnapshot(); }
    public void Capture(bool useRemembered = false)
    {
        if (disposed) return;
        captured = useRemembered && remembered != null ? remembered : TakeSnapshot();
        RetainedScene = captured.Scene;
        if (captured.Scene is { } scene && captured.Width > 0 && captured.Height > 0)
        {
            if (!sceneStyles.ContainsKey(scene)) sceneStyles[scene] = new(scene.Width, scene.Height, scene.HorizontalAlignment, scene.VerticalAlignment);
            scene.Width = captured.Width; scene.Height = captured.Height;
            scene.HorizontalAlignment = HorizontalAlignment.Left; scene.VerticalAlignment = VerticalAlignment.Top;
        }
    }

    public void Run(Action commit, Action completed, bool animate, FrameworkElement? outgoing = null)
    {
        if (disposed) return;
        ArgumentNullException.ThrowIfNull(commit); ArgumentNullException.ThrowIfNull(completed);
        long request = ++revision;
        StopClock();
        IsRunning = true; committed = false; pendingCommit = commit; completion = completed;
        if (captured == null) Capture();
        bridges.Clear();
        try
        {
            if (animate && outgoing != null && Bounds(outgoing) != null)
            {
                Fade(outgoing, 0, 90);
                Schedule(() => ApplyLayout(request, true), 100, request);
            }
            else ApplyLayout(request, animate);
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
    private void ApplyLayout(long request, bool animate)
    {
        if (!Current(request)) return;
        try
        {
            var before = captured ?? TakeSnapshot(); captured = null;
            if (!Commit(request)) return;
            var currentScene = activeScene?.Invoke();
            if (currentScene != null)
            {
                RestoreScene(currentScene);
                // Its prior outgoing transform has already been absorbed into
                // the snapshot's screen geometry. Incoming content owns the
                // complete FLIP, so the root stays identity throughout instead
                // of jumping to identity only on the final cleanup frame.
                if (sceneTransforms.Remove(currentScene))
                {
                    NormalizeScene(currentScene); ParentNormalizations++;
                }
            }
            if (ReferenceEquals(before.Scene, currentScene)) RetainedScene = null;
            root.UpdateLayout();
            if (!Current(request)) return;
            if (!animate) { Finish(request); return; }
            var frame = clientFrame(); double scale = Math.Max(.01, frame.Scale);
            Rect Project(Rect value) => new((before.Origin.X + value.X * before.Scale - frame.Origin.X) / scale,
                (before.Origin.Y + value.Y * before.Scale - frame.Origin.Y) / scale, value.Width * before.Scale / scale, value.Height * before.Scale / scale);
            foreach (var item in moving)
            {
                if (currentScene != null && !Within(item.Element, currentScene)) continue;
                before.Bounds.TryGetValue(item.Element, out var old);
                if (old == null)
                    foreach (var pair in semanticPairs)
                    {
                        FrameworkElement? counterpart = ReferenceEquals(pair.First, item.Element) ? pair.Second : ReferenceEquals(pair.Second, item.Element) ? pair.First : null;
                        if (counterpart != null && before.Bounds.TryGetValue(counterpart, out old) && old != null) break;
                    }
                var current = LayoutBounds(item.Element);
                if (old is { } from && current is { } to)
                {
                    var projected = Project(from); bridges.Add(new(item.Element.Name, projected, to));
                    Move(item.Element, projected, to, item.Scale);
                }
            }
            foreach (var element in fading)
            {
                if (currentScene != null && !Within(element, currentScene) || Bounds(element) == null) continue;
                if (!before.Bounds.TryGetValue(element, out var old) || old == null) SetOpacity(element, 0);
                Fade(element, 1, 320);
            }
            if (currentScene != null)
            {
                if (!before.VisibleScenes.Contains(currentScene)) SetOpacity(currentScene, 0);
                Fade(currentScene, 1, 320);
            }
            if (RetainedScene is { } outgoing && !ReferenceEquals(outgoing, currentScene))
            {
                outgoing.Visibility = Visibility.Visible;
                var visual = ElementCompositionPreview.GetElementVisual(outgoing);
                var origin = LayoutOrigin(outgoing);
                var translation = new Vector3((float)((before.Origin.X - frame.Origin.X) / scale), (float)((before.Origin.Y - frame.Origin.Y) / scale), 0);
                float ratio = (float)(before.Scale / scale);
                visual.Properties.StopAnimation("Translation");
                visual.Properties.InsertVector3("Translation", translation);
                visual.StopAnimation("Scale"); visual.Scale = new(ratio, ratio, 1);
                sceneTransforms[outgoing] = new(origin, translation, ratio);
                Fade(outgoing, 0, 320);
            }
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
        IsRunning = false; ResetVisuals(); RestoreScenes();
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
    private Point LayoutOrigin(FrameworkElement element)
    {
        double x = 0, y = 0;
        for (DependencyObject? current = element; current != null && !ReferenceEquals(current, root); current = VisualTreeHelper.GetParent(current))
            if (current is UIElement view) { x += view.ActualOffset.X; y += view.ActualOffset.Y; }
        return new(x, y);
    }
    private Rect? LayoutBounds(FrameworkElement element)
    {
        if (Bounds(element) == null) return null;
        // TransformToVisual can retain the preceding compositor frame even
        // immediately after writing facade Translation/Scale back to 0/1.
        // Destinations are arranged layout geometry, never presented geometry;
        // ActualOffset also excludes this element's own previous FLIP.
        var origin = LayoutOrigin(element);
        return new(origin.X, origin.Y, element.ActualWidth, element.ActualHeight);
    }
    private Rect? SnapshotBounds(FrameworkElement element)
    {
        if (Bounds(element) == null) return null;
        foreach (var pair in sceneTransforms)
        {
            if (!Within(element, pair.Key)) continue;
            // Transform only as far as the scene to exclude its Composition
            // parent transform, then apply the known static transform once.
            // This avoids relying on whether TransformToVisual(root) exposes
            // facade Translation/Scale values on this WinUI version.
            var local = element.TransformToVisual(pair.Key).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            var matrix = pair.Value;
            return new(matrix.Origin.X + local.X * matrix.Scale + matrix.Translation.X,
                matrix.Origin.Y + local.Y * matrix.Scale + matrix.Translation.Y,
                local.Width * matrix.Scale, local.Height * matrix.Scale);
        }
        return Bounds(element);
    }
    private static bool Within(DependencyObject element, DependencyObject parent)
    {
        for (DependencyObject? current = element; current != null; current = VisualTreeHelper.GetParent(current))
            if (ReferenceEquals(current, parent)) return true;
        return false;
    }
    private static void SetOpacity(FrameworkElement element, float value)
    { var visual = ElementCompositionPreview.GetElementVisual(element); visual.StopAnimation("Opacity"); visual.Opacity = value; }
    private void RestoreScene(FrameworkElement scene)
    {
        if (!sceneStyles.Remove(scene, out var style)) return;
        scene.Width = style.Width; scene.Height = style.Height; scene.HorizontalAlignment = style.Horizontal; scene.VerticalAlignment = style.Vertical;
    }
    private void RestoreScenes()
    {
        var current = activeScene?.Invoke();
        foreach (var scene in scenes)
        {
            try
            {
                RestoreScene(scene);
                NormalizeScene(scene); sceneTransforms.Remove(scene); SetOpacity(scene, 1);
                if (current != null && !ReferenceEquals(scene, current)) scene.Visibility = Visibility.Collapsed;
            }
            catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
        }
        RetainedScene = null; captured = null;
    }
    private static void NormalizeScene(FrameworkElement scene)
    {
        var visual = ElementCompositionPreview.GetElementVisual(scene);
        visual.Properties.StopAnimation("Translation"); visual.Properties.InsertVector3("Translation", Vector3.Zero);
        visual.StopAnimation("Scale"); visual.Scale = Vector3.One;
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
    { ++revision; StopClock(); pendingCommit = completion = null; IsRunning = false; ResetVisuals(); RestoreScenes(); }
    public void Dispose()
    {
        if (disposed) return; Cancel(); disposed = true;
        try { timer.Tick -= Tick; }
        catch (Exception error) when (Recoverable(error)) { AnimationFailures++; }
    }
}
