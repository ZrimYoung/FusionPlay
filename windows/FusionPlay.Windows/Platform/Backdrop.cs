using System.Numerics;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Streams;
using Windows.UI.ViewManagement;
using System.Runtime.InteropServices;

namespace FusionPlay.Windows.Platform;

internal sealed class Backdrop : IDisposable
{
    private readonly Grid target;
    private byte[]? current;
    private LoadedImageSurface? surface;
    private IRandomAccessStream? stream;
    private CompositionEffectBrush? effect;
    private SpriteVisual? visual;
    private readonly UISettings settings = new();
    private bool disposed;
    public event Action? Changed;
    public Backdrop(Grid host)
    {
        target = host;
        settings.AdvancedEffectsEnabledChanged += EffectsChanged;
        target.ActualThemeChanged += ThemeChanged;
    }
    public bool SetArtwork(byte[]? bytes)
    {
        bool enabled;
        try { enabled = bytes != null && settings.AdvancedEffectsEnabled && !IsHighContrast(); }
        catch (COMException) { enabled = false; }
        if (ReferenceEquals(current, enabled ? bytes : null)) return enabled && visual != null;
        Clear(); current = enabled ? bytes : null;
        if (!enabled) return false;
        try
        {
            var compositor = ElementCompositionPreview.GetElementVisual(target).Compositor;
            stream = new MemoryStream(bytes!, writable: false).AsRandomAccessStream();
            surface = LoadedImageSurface.StartLoadFromStream(stream);
            var image = compositor.CreateSurfaceBrush(surface);
            image.Stretch = CompositionStretch.UniformToFill;
            var gaussian = new GaussianBlurEffect
            {
                BlurAmount = 34, BorderMode = EffectBorderMode.Hard,
                Source = new CompositionEffectSourceParameter("artwork")
            };
            using var factory = compositor.CreateEffectFactory(gaussian);
            effect = factory.CreateBrush(); effect.SetSourceParameter("artwork", image);
            visual = compositor.CreateSpriteVisual(); visual.RelativeSizeAdjustment = Vector2.One;
            visual.Brush = effect;
            ElementCompositionPreview.SetElementChildVisual(target, visual);
            return true;
        }
        catch { Clear(); current = null; return false; }
    }
    private void EffectsChanged(UISettings sender, object args) => Refresh();
    private void ThemeChanged(Microsoft.UI.Xaml.FrameworkElement sender, object args) => Refresh();
    [StructLayout(LayoutKind.Sequential)]
    private struct HighContrast { public uint Size, Flags; public nint Scheme; }
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HighContrast value, uint update);
    private static bool IsHighContrast()
    {
        var value = new HighContrast { Size = (uint)Marshal.SizeOf<HighContrast>() };
        return SystemParametersInfo(0x42, value.Size, ref value, 0) && (value.Flags & 1) != 0;
    }
    private void Refresh() => target.DispatcherQueue.TryEnqueue(() =>
    {
        if (disposed) return;
        Changed?.Invoke();
    });
    private void Clear()
    {
        ElementCompositionPreview.SetElementChildVisual(target, null);
        visual?.Dispose(); visual = null; effect?.Dispose(); effect = null;
        surface?.Dispose(); surface = null; stream?.Dispose(); stream = null;
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        settings.AdvancedEffectsEnabledChanged -= EffectsChanged;
        target.ActualThemeChanged -= ThemeChanged;
        Clear();
    }
}
