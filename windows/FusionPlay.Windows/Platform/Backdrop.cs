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
        public readonly List<CompositionLinearGradientBrush> Masks = [];
        public void Dispose()
        { Visual.Dispose(); foreach (var item in Resources) item.Dispose(); Surface.Dispose(); Stream.Dispose(); }
    }
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
                using var factory = compositor.CreateEffectFactory(gaussian);
                var effect = factory.CreateBrush(); incoming.Resources.Add(effect);
                effect.SetSourceParameter("artwork", image);
                CompositionBrush brush = effect;
                if (progressive)
                {
                    var mask = compositor.CreateLinearGradientBrush(); incoming.Resources.Add(mask); incoming.Masks.Add(mask);
                    mask.StartPoint = Vector2.Zero; mask.EndPoint = Vector2.UnitY;
                    mask.ColorStops.Add(compositor.CreateColorGradientStop(0, Colors.Transparent));
                    mask.ColorStops.Add(compositor.CreateColorGradientStop(0, Colors.Transparent));
                    mask.ColorStops.Add(compositor.CreateColorGradientStop(1, Colors.White));
                    mask.ColorStops.Add(compositor.CreateColorGradientStop(1, Colors.White));
                    var masked = compositor.CreateMaskBrush(); incoming.Resources.Add(masked);
                    masked.Source = effect; masked.Mask = mask; brush = masked;
                }
                var sprite = compositor.CreateSpriteVisual(); incoming.Resources.Add(sprite);
                sprite.RelativeSizeAdjustment = Vector2.One; sprite.Brush = brush; incoming.Visual.Children.InsertAtTop(sprite);
            }
            layer = incoming; current = bytes; UpdateCoverage(incoming);
            root.Children.InsertAtTop(incoming.Visual);
            incoming.Visual.Opacity = previous != null && AnimationsEnabled ? 0 : 1;
            var ready = incoming;
            ready.Surface.LoadCompleted += (_, args) => target.DispatcherQueue.TryEnqueue(() =>
            {
                if (disposed || !ReferenceEquals(layer, ready)) return;
                if (args.Status != LoadedImageSourceLoadStatus.Success)
                {
                    // A decoded cover may still fail in the composition device. Keep the
                    // ordinary XAML artwork and use the solid, accessible fallback.
                    Clear(); current = null; failedArtwork = bytes; Changed?.Invoke(); return;
                }
                if (AnimationsEnabled)
                {
                    var animation = compositor.CreateScalarKeyFrameAnimation(); animation.InsertKeyFrame(1, 1);
                    animation.Duration = TimeSpan.FromMilliseconds(350); ready.Visual.StartAnimation("Opacity", animation); animation.Dispose();
                    retirement.Start();
                }
                else { ready.Visual.Opacity = 1; RetirePrevious(); }
            });
            return true;
        }
        catch
        {
            // Ownership transfers only after a complete layer exists. Close every
            // partial allocation once, including failures while creating an effect.
            if (incoming != null && !ReferenceEquals(layer, incoming)) incoming.Dispose();
            pendingSurface?.Dispose(); pendingStream?.Dispose();
            Clear(); current = null; failedArtwork = bytes; return false;
        }
    }
    public void SetCoverage(double fraction)
    {
        coverage = Math.Clamp(fraction, 0.1, 1);
        if (layer != null) UpdateCoverage(layer);
        if (previous != null) UpdateCoverage(previous);
    }
    private void UpdateCoverage(Layer value)
    {
        for (int index = 0; index < value.Masks.Count; index++)
        {
            float start = (float)(1 - coverage + coverage * index / 4);
            float end = (float)Math.Min(1, start + coverage / 4);
            value.Masks[index].ColorStops[1].Offset = start;
            value.Masks[index].ColorStops[2].Offset = end;
        }
    }
    private void RetirePrevious()
    {
        retirement.Stop();
        if (previous == null) return;
        root?.Children.Remove(previous.Visual); previous.Dispose(); previous = null;
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
        RetirePrevious();
        if (layer != null) { root?.Children.Remove(layer.Visual); layer.Dispose(); layer = null; }
        ElementCompositionPreview.SetElementChildVisual(target, null); root?.Dispose(); root = null;
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        settings.AdvancedEffectsEnabledChanged -= EffectsChanged; target.ActualThemeChanged -= ThemeChanged; Clear();
    }
}
