using System.Runtime.InteropServices;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.UI.Composition;
using Microsoft.UI.Composition;

namespace FusionPlay.Windows.Platform;

/// <summary>One device and effect factory per lyric viewport, shared by its visible glyph planes.</summary>
internal sealed class LyricsGraphicsResources : IDisposable
{
    internal CanvasDevice Device { get; }
    internal CompositionGraphicsDevice GraphicsDevice { get; }
    internal CompositionEffectFactory BlurFactory { get; }
    internal Compositor Compositor { get; }
    private readonly Action deviceLost;
    private int activeClusterMotions;

    internal LyricsGraphicsResources(Compositor compositor, Action deviceLost)
    {
        this.deviceLost = deviceLost; Compositor = compositor; Device = CanvasDevice.GetSharedDevice();
        GraphicsDevice = CanvasComposition.CreateCompositionGraphicsDevice(compositor, Device);
        try
        {
            using var effect = new GaussianBlurEffect
            {
                Name = "edge", BlurAmount = 0, BorderMode = EffectBorderMode.Soft,
                Source = new CompositionEffectSourceParameter("glyphs")
            };
            BlurFactory = compositor.CreateEffectFactory(effect, ["edge.BlurAmount"]);
            Device.DeviceLost += DeviceLost;
        }
        catch { Close(BlurFactory); Close(GraphicsDevice); throw; }
    }
    internal bool TryReserveClusterMotion()
    {
        if (activeClusterMotions >= 3) return false;
        activeClusterMotions++;
        return true;
    }
    internal void ReleaseClusterMotion() => activeClusterMotions--;
    private void DeviceLost(CanvasDevice sender, object args) => deviceLost();
    internal static void Close(IDisposable? value)
    {
        try { value?.Dispose(); } catch (Exception error) when (error is COMException or ObjectDisposedException) { }
    }
    public void Dispose()
    {
        try { Device.DeviceLost -= DeviceLost; } catch (Exception error) when (error is COMException or ObjectDisposedException) { }
        Close(BlurFactory); Close(GraphicsDevice);
    }
}
