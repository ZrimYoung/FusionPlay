using System.Numerics;
using System.Runtime.InteropServices;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Streams;
using Microsoft.UI;
using Windows.UI.ViewManagement;

namespace FusionPlay.Windows.Platform;

internal sealed class Backdrop : IDisposable
{
    private sealed class Layer : IDisposable
    {
        public required ContainerVisual Visual;
        public LoadedImageSurface? Surface;
        public IRandomAccessStream? Stream;
        public AlbumBackdropCache.PreparedArtwork? Prepared;
        public readonly List<IDisposable> Resources = [];
        public readonly List<IDisposable> LiveResources = [];
        public readonly List<(CompositionColorGradientStop Start, CompositionColorGradientStop End)> Edges = [];
        public readonly List<(float Radius, SpriteVisual Sprite, CompositionMaskBrush? Mask)> Sprites = [];
        public Action? Unsubscribe;
        public bool IsReady;
        public bool Disposed { get; private set; }

        public void ReleaseLiveArtwork()
        {
            try { Unsubscribe?.Invoke(); } catch (ObjectDisposedException) { } catch (COMException) { }
            Unsubscribe = null;
            for (int index = LiveResources.Count - 1; index >= 0; index--) Close(LiveResources[index]);
            LiveResources.Clear();
            Close(Surface); Close(Stream);
            Surface = null; Stream = null;
        }

        public void Dispose()
        {
            if (Disposed) return;
            Disposed = true;
            // Disconnect first. A container and its brush graph can share WinRT
            // projections; closing one must not abort retirement of the rest.
            try { Visual.StopAnimation("Opacity"); Visual.Children.RemoveAll(); } catch (ObjectDisposedException) { } catch (COMException) { }
            for (int index = Resources.Count - 1; index >= 0; index--) Close(Resources[index]);
            Resources.Clear(); Edges.Clear(); Sprites.Clear();
            ReleaseLiveArtwork();
            Prepared?.Dispose(); Prepared = null;
            Close(Visual);
        }
    }
    private static void Close(IDisposable? value)
    { try { value?.Dispose(); } catch (ObjectDisposedException) { } catch (COMException) { } }
    private readonly Grid target;
    private readonly bool progressive;
    private readonly float blur;
    private readonly AlbumBackdropCache? cache;
    private readonly UISettings settings = new();
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer retirement;
    private byte[]? current, failedArtwork;
    private int currentStrength, failedStrength;
    private Layer? layer, previous;
    private ContainerVisual? root;
    private double coverage = 0.65;
    private bool disposed;
    public event Action? Changed;
    public event Action<string>? Failed;
    private void Report(string stage, Exception error) => Failed?.Invoke(stage + ":" + error.GetType().Name + ":" + error.HResult.ToString("X8"));
    public static bool AnimationsEnabled
    { get { try { return new UISettings().AnimationsEnabled && !IsHighContrast(); } catch (COMException) { return false; } } }
    public Backdrop(Grid host, bool progressive = false, float blur = 34, AlbumBackdropCache? cache = null)
    {
        target = host; this.progressive = progressive; this.blur = blur; this.cache = cache;
        retirement = host.DispatcherQueue.CreateTimer(); retirement.IsRepeating = false;
        retirement.Interval = TimeSpan.FromMilliseconds(400);
        retirement.Tick += (_, _) => RetirePrevious();
        settings.AdvancedEffectsEnabledChanged += EffectsChanged;
        target.ActualThemeChanged += ThemeChanged;
        if (cache != null) cache.Ready += UsePreparedArtwork;
    }
    internal bool UsesPreparedArtwork => layer?.Prepared != null;
    public bool SetArtwork(byte[]? bytes, int strength = 100)
    {
        if (disposed) return false;
        bool enabled;
        try { enabled = bytes != null && settings.AdvancedEffectsEnabled && !IsHighContrast(); }
        catch (COMException) { enabled = false; }
        if (!enabled) { Clear(); current = failedArtwork = null; return false; }
        if (ReferenceEquals(failedArtwork, bytes) && failedStrength == strength) return false;
        if (ReferenceEquals(current, bytes) && currentStrength == strength) return layer != null;
        Layer? incoming = null;
        try
        {
            var compositor = ElementCompositionPreview.GetElementVisual(target).Compositor;
            root ??= compositor.CreateContainerVisual(); root.RelativeSizeAdjustment = Vector2.One;
            ElementCompositionPreview.SetElementChildVisual(target, root);
            RetirePrevious(); previous = layer; layer = null;
            incoming = new Layer { Visual = compositor.CreateContainerVisual() };
            incoming.Visual.RelativeSizeAdjustment = Vector2.One;
            ReadOnlySpan<float> radii = progressive ? AlbumBackdropCache.ProgressiveRadii : [blur];
            foreach (float radius in radii)
            {
                CompositionMaskBrush? masked = null;
                if (progressive)
                {
                    var mask = compositor.CreateLinearGradientBrush(); incoming.Resources.Add(mask);
                    mask.StartPoint = Vector2.Zero; mask.EndPoint = Vector2.UnitY;
                    var top = compositor.CreateColorGradientStop(0, Colors.Transparent);
                    var start = compositor.CreateColorGradientStop(0, Colors.Transparent);
                    var end = compositor.CreateColorGradientStop(1, Colors.White);
                    var bottom = compositor.CreateColorGradientStop(1, Colors.White);
                    foreach (var stop in new[] { top, start, end, bottom }) { incoming.Resources.Add(stop); mask.ColorStops.Add(stop); }
                    incoming.Edges.Add((start, end));
                    masked = compositor.CreateMaskBrush(); incoming.Resources.Add(masked);
                    masked.Mask = mask;
                }
                var sprite = compositor.CreateSpriteVisual(); incoming.Resources.Add(sprite);
                sprite.RelativeSizeAdjustment = Vector2.One;
                sprite.Brush = masked;
                incoming.Visual.Children.InsertAtTop(sprite);
                incoming.Sprites.Add((radius, sprite, masked));
            }
            cache?.Prepare(bytes!, strength);
            if (!TryApplyPrepared(incoming, bytes!, strength, radii)) BuildLiveArtwork(incoming, bytes!, strength);
            layer = incoming; current = bytes; currentStrength = strength; UpdateCoverage(incoming);
            root.Children.InsertAtTop(incoming.Visual);
            incoming.Visual.Opacity = 1;
            if (incoming.Prepared != null)
            {
                ShowReadyLayer(incoming);
                return true;
            }
            var ready = incoming;
            var surface = ready.Surface!;
            global::Windows.Foundation.TypedEventHandler<LoadedImageSurface, LoadedImageSourceLoadCompletedEventArgs> completed = (_, args) =>
            {
                // Event arguments belong to the native callback. Do not keep a
                // projected argument alive for a later dispatcher invocation.
                var status = args.Status;
                target.DispatcherQueue.TryEnqueue(() =>
                {
                    if (disposed || ready.Disposed || ready.Prepared != null || !ReferenceEquals(layer, ready)) return;
                    try
                    {
                        if (status != LoadedImageSourceLoadStatus.Success)
                        {
                            Clear(); current = null; failedArtwork = bytes; failedStrength = strength; Changed?.Invoke(); return;
                        }
                        ShowReadyLayer(ready);
                    }
                    catch (Exception error) when (error is COMException or ObjectDisposedException)
                    {
                        Report("load_completed", error); Clear(); current = null; failedArtwork = bytes; failedStrength = strength; Changed?.Invoke();
                    }
                });
            };
            ready.Unsubscribe = () => surface.LoadCompleted -= completed;
            surface.LoadCompleted += completed;
            return true;
        }
        catch (Exception error)
        {
            // Ownership transfers only after a complete layer exists. Close every
            // partial allocation once, including failures while creating an effect.
            if (incoming != null && !ReferenceEquals(layer, incoming)) incoming.Dispose();
            Report("create", error); Clear(); current = null; failedArtwork = bytes; failedStrength = strength; return false;
        }
    }

    private static void BuildLiveArtwork(Layer value, byte[] bytes, int strength)
    {
        var compositor = value.Visual.Compositor;
        value.Stream = new MemoryStream(bytes, writable: false).AsRandomAccessStream();
        // Bound the retained immediate decode until the shared blurred artwork has loaded.
        value.Surface = LoadedImageSurface.StartLoadFromStream(value.Stream, new global::Windows.Foundation.Size(1024, 1024));
        var image = compositor.CreateSurfaceBrush(value.Surface);
        value.LiveResources.Add(image);
        image.Stretch = CompositionStretch.UniformToFill;
        foreach (var (radius, sprite, mask) in value.Sprites)
        {
            CompositionBrush brush = image;
            if (strength > 0)
            {
                using var gaussian = new GaussianBlurEffect
                {
                    BlurAmount = radius * (strength / 100f),
                    BorderMode = EffectBorderMode.Hard,
                    Source = new CompositionEffectSourceParameter("artwork")
                };
                var factory = compositor.CreateEffectFactory(gaussian); value.LiveResources.Add(factory);
                var effect = factory.CreateBrush(); value.LiveResources.Add(effect);
                effect.SetSourceParameter("artwork", image);
                brush = effect;
            }
            if (mask != null) mask.Source = brush;
            else sprite.Brush = brush;
        }
    }

    private void UsePreparedArtwork()
    {
        if (disposed || current == null || layer is not { Prepared: null } value) return;
        ReadOnlySpan<float> radii = progressive ? AlbumBackdropCache.ProgressiveRadii : [blur];
        try
        {
            if (TryApplyPrepared(value, current, currentStrength, radii)) ShowReadyLayer(value);
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException)
        {
            Report("cached_artwork", error);
        }
    }

    private bool TryApplyPrepared(Layer value, byte[] bytes, int strength, ReadOnlySpan<float> radii)
    {
        var prepared = cache?.Acquire(bytes, strength, radii);
        if (prepared == null) return false;
        var compositor = value.Visual.Compositor;
        var brushes = new List<CompositionSurfaceBrush>(radii.Length);
        var attached = new List<(SpriteVisual Sprite, CompositionMaskBrush? Mask, CompositionBrush? Previous)>(radii.Length);
        try
        {
            foreach (var (radius, _, _) in value.Sprites)
            {
                var brush = compositor.CreateSurfaceBrush(prepared.Surface(radius));
                brushes.Add(brush);
                brush.Stretch = CompositionStretch.UniformToFill;
            }
            for (int index = 0; index < brushes.Count; index++)
            {
                var (_, sprite, mask) = value.Sprites[index];
                attached.Add((sprite, mask, mask != null ? mask.Source : sprite.Brush));
                if (mask != null) mask.Source = brushes[index];
                else sprite.Brush = brushes[index];
            }
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException or ArgumentException)
        {
            foreach (var (sprite, mask, oldBrush) in attached)
            {
                try { if (mask != null) mask.Source = oldBrush; else sprite.Brush = oldBrush; }
                catch (Exception restoreError) when (restoreError is COMException or ObjectDisposedException) { }
            }
            foreach (var brush in brushes) Close(brush);
            prepared.Dispose();
            Report("cached_brush", error);
            return false;
        }
        value.Resources.AddRange(brushes);
        value.Prepared = prepared;
        value.ReleaseLiveArtwork();
        return true;
    }

    private void ShowReadyLayer(Layer value)
    {
        if (value.IsReady) return;
        value.IsReady = true;
        if (previous != null && AnimationsEnabled)
        {
            using var animation = value.Visual.Compositor.CreateScalarKeyFrameAnimation();
            animation.InsertKeyFrame(0, 0); animation.InsertKeyFrame(1, 1);
            animation.Duration = TimeSpan.FromMilliseconds(350);
            value.Visual.StartAnimation("Opacity", animation);
            retirement.Start();
        }
        else { value.Visual.Opacity = 1; RetirePrevious(); }
    }
    public void SetCoverage(double fraction)
    {
        double next = Math.Clamp(fraction, 0.1, 1);
        if (Math.Abs(next - coverage) < 0.002) return;
        coverage = next;
        if (disposed) return;
        try
        {
            if (layer != null) UpdateCoverage(layer);
            if (previous != null) UpdateCoverage(previous);
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException)
        {
            var failed = current; Report("coverage", error); Clear(); current = null; failedArtwork = failed; failedStrength = currentStrength;
            Changed?.Invoke();
        }
    }
    private void UpdateCoverage(Layer value)
    {
        if (value.Disposed) return;
        for (int index = 0; index < value.Edges.Count; index++)
        {
            float start = (float)(1 - coverage + coverage * index / 4);
            float end = (float)Math.Min(1, start + coverage / 4);
            value.Edges[index].Start.Offset = start;
            value.Edges[index].End.Offset = end;
        }
    }
    private void RetirePrevious()
    {
        retirement.Stop();
        var retired = previous; previous = null;
        if (retired == null) return;
        try { root?.Children.Remove(retired.Visual); } catch (ObjectDisposedException) { } catch (COMException) { }
        retired.Dispose();
    }
    private void EffectsChanged(UISettings sender, object args) => Refresh();
    private void ThemeChanged(Microsoft.UI.Xaml.FrameworkElement sender, object args) => Refresh();
    [StructLayout(LayoutKind.Sequential)] private struct HighContrast { public uint Size, Flags; public nint Scheme; }
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SystemParametersInfo(uint action, uint parameter, ref HighContrast value, uint update);
    private static bool IsHighContrast()
    { var value = new HighContrast { Size = (uint)Marshal.SizeOf<HighContrast>() }; return SystemParametersInfo(0x42, value.Size, ref value, 0) && (value.Flags & 1) != 0; }
    private void Refresh() => target.DispatcherQueue.TryEnqueue(() => { if (!disposed) { failedArtwork = null; Changed?.Invoke(); } });
    private void Clear()
    {
        if (layer == null && previous == null && root == null) return;
        retirement.Stop();
        var outgoing = layer; var retired = previous; var oldRoot = root;
        // Publish the empty state before releasing any WinRT resource. Native
        // close callbacks can reenter layout/coverage while a layer is retiring.
        layer = previous = null; root = null;
        try { ElementCompositionPreview.SetElementChildVisual(target, null); } catch (ObjectDisposedException) { } catch (COMException) { }
        try { oldRoot?.Children.RemoveAll(); } catch (ObjectDisposedException) { } catch (COMException) { }
        retired?.Dispose(); outgoing?.Dispose(); if (oldRoot != null) Close(oldRoot);
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        settings.AdvancedEffectsEnabledChanged -= EffectsChanged; target.ActualThemeChanged -= ThemeChanged;
        if (cache != null) cache.Ready -= UsePreparedArtwork;
        Clear();
    }
}
