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
        public required LoadedImageSurface Surface;
        public required IRandomAccessStream Stream;
        public readonly List<IDisposable> Resources = [];
        public readonly List<(CompositionColorGradientStop Start, CompositionColorGradientStop End)> Edges = [];
        public Action? Unsubscribe;
        public bool Disposed { get; private set; }
        public void Dispose()
        {
            if (Disposed) return;
            Disposed = true;
            try { Unsubscribe?.Invoke(); } catch (ObjectDisposedException) { } catch (COMException) { }
            Unsubscribe = null;
            // Disconnect first. A container and its brush graph can share WinRT
            // projections; closing one must not abort retirement of the rest.
            try { Visual.StopAnimation("Opacity"); Visual.Children.RemoveAll(); } catch (ObjectDisposedException) { } catch (COMException) { }
            for (int index = Resources.Count - 1; index >= 0; index--) Close(Resources[index]);
            Resources.Clear(); Edges.Clear();
            Close(Visual); Close(Surface); Close(Stream);
        }
    }
    private static void Close(IDisposable value)
    { try { value.Dispose(); } catch (ObjectDisposedException) { } catch (COMException) { } }
    private readonly Grid target;
    private readonly bool progressive;
    private readonly float blur;
    private readonly UISettings settings = new();
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer retirement;
    private byte[]? current, failedArtwork;
    private Layer? layer, previous;
    private ContainerVisual? root;
    private double coverage = 0.65;
    private bool disposed;
    public event Action? Changed;
    public event Action<string>? Failed;
    private void Report(string stage, Exception error) => Failed?.Invoke(stage + ":" + error.GetType().Name + ":" + error.HResult.ToString("X8"));
    public static bool AnimationsEnabled
    { get { try { return new UISettings().AnimationsEnabled && !IsHighContrast(); } catch (COMException) { return false; } } }
    public Backdrop(Grid host, bool progressive = false, float blur = 34)
    {
        target = host; this.progressive = progressive; this.blur = blur;
        retirement = host.DispatcherQueue.CreateTimer(); retirement.IsRepeating = false;
        retirement.Interval = TimeSpan.FromMilliseconds(400);
        retirement.Tick += (_, _) => RetirePrevious();
        settings.AdvancedEffectsEnabledChanged += EffectsChanged;
        target.ActualThemeChanged += ThemeChanged;
    }
    public bool SetArtwork(byte[]? bytes)
    {
        if (disposed) return false;
        bool enabled;
        try { enabled = bytes != null && settings.AdvancedEffectsEnabled && !IsHighContrast(); }
        catch (COMException) { enabled = false; }
        if (!enabled) { Clear(); current = failedArtwork = null; return false; }
        if (ReferenceEquals(failedArtwork, bytes)) return false;
        if (ReferenceEquals(current, bytes)) return layer != null;
        Layer? incoming = null;
        IRandomAccessStream? pendingStream = null;
        LoadedImageSurface? pendingSurface = null;
        try
        {
            var compositor = ElementCompositionPreview.GetElementVisual(target).Compositor;
            root ??= compositor.CreateContainerVisual(); root.RelativeSizeAdjustment = Vector2.One;
            ElementCompositionPreview.SetElementChildVisual(target, root);
            RetirePrevious(); previous = layer; layer = null;
            pendingStream = new MemoryStream(bytes!, writable: false).AsRandomAccessStream();
            pendingSurface = LoadedImageSurface.StartLoadFromStream(pendingStream);
            incoming = new Layer { Visual = compositor.CreateContainerVisual(), Surface = pendingSurface, Stream = pendingStream };
            pendingStream = null; pendingSurface = null;
            incoming.Visual.RelativeSizeAdjustment = Vector2.One;
            var image = compositor.CreateSurfaceBrush(incoming.Surface); incoming.Resources.Add(image);
            image.Stretch = CompositionStretch.UniformToFill;
            float[] radii = progressive ? [6, 14, 26, 40] : [blur];
            foreach (float radius in radii)
            {
                var gaussian = new GaussianBlurEffect { BlurAmount = radius, BorderMode = EffectBorderMode.Hard, Source = new CompositionEffectSourceParameter("artwork") };
                var factory = compositor.CreateEffectFactory(gaussian); incoming.Resources.Add(factory);
                var effect = factory.CreateBrush(); incoming.Resources.Add(effect);
                effect.SetSourceParameter("artwork", image);
                CompositionBrush brush = effect;
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
                    var masked = compositor.CreateMaskBrush(); incoming.Resources.Add(masked);
                    masked.Source = effect; masked.Mask = mask; brush = masked;
                }
                var sprite = compositor.CreateSpriteVisual(); incoming.Resources.Add(sprite);
                sprite.RelativeSizeAdjustment = Vector2.One; sprite.Brush = brush; incoming.Visual.Children.InsertAtTop(sprite);
            }
            layer = incoming; current = bytes; UpdateCoverage(incoming);
            root.Children.InsertAtTop(incoming.Visual);
            incoming.Visual.Opacity = 1;
            var ready = incoming;
            global::Windows.Foundation.TypedEventHandler<LoadedImageSurface, LoadedImageSourceLoadCompletedEventArgs> completed = (_, args) =>
            {
                // Event arguments belong to the native callback. Do not keep a
                // projected argument alive for a later dispatcher invocation.
                var status = args.Status;
                target.DispatcherQueue.TryEnqueue(() =>
                {
                    if (disposed || ready.Disposed || !ReferenceEquals(layer, ready)) return;
                    try
                    {
                        if (status != LoadedImageSourceLoadStatus.Success)
                        {
                            Clear(); current = null; failedArtwork = bytes; Changed?.Invoke(); return;
                        }
                        if (previous != null && AnimationsEnabled)
                        {
                            var animation = compositor.CreateScalarKeyFrameAnimation();
                            animation.InsertKeyFrame(0, 0); animation.InsertKeyFrame(1, 1);
                            animation.Duration = TimeSpan.FromMilliseconds(350); ready.Visual.StartAnimation("Opacity", animation); Close(animation);
                            retirement.Start();
                        }
                        else { ready.Visual.Opacity = 1; RetirePrevious(); }
                    }
                    catch (Exception error) when (error is COMException or ObjectDisposedException)
                    {
                        Report("load_completed", error); Clear(); current = null; failedArtwork = bytes; Changed?.Invoke();
                    }
                });
            };
            ready.Unsubscribe = () => ready.Surface.LoadCompleted -= completed;
            ready.Surface.LoadCompleted += completed;
            return true;
        }
        catch (Exception error)
        {
            // Ownership transfers only after a complete layer exists. Close every
            // partial allocation once, including failures while creating an effect.
            if (incoming != null && !ReferenceEquals(layer, incoming)) incoming.Dispose();
            if (pendingSurface != null) Close(pendingSurface); if (pendingStream != null) Close(pendingStream);
            Report("create", error); Clear(); current = null; failedArtwork = bytes; return false;
        }
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
            var failed = current; Report("coverage", error); Clear(); current = null; failedArtwork = failed;
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
        settings.AdvancedEffectsEnabledChanged -= EffectsChanged; target.ActualThemeChanged -= ThemeChanged; Clear();
    }
}
