using System.Runtime.InteropServices;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace FusionPlay.Windows.Platform;

/// <summary>Owns one real system acrylic target; never substitutes an artwork blur.</summary>
internal sealed class PlayerAcrylic : IDisposable
{
    private readonly Window window;
    private readonly UISettings settings = new();
    private readonly SystemBackdrop? previous;
    private DesktopAcrylicBackdrop? material;
    private (bool Requested, bool HighContrast, bool Effects)? applied;
    private bool disposed;
    internal bool IsRequested { get; private set; }
    internal bool IsActive { get; private set; }
    internal bool UsesSolidFallback => IsRequested && !IsActive;

    internal PlayerAcrylic(Window window) { this.window = window; previous = window.SystemBackdrop; }
    internal void Update(bool requested, bool highContrast)
    {
        if (disposed) return;
        bool effects;
        try { effects = settings.AdvancedEffectsEnabled; }
        catch (COMException) { effects = false; }
        var state = (requested, highContrast, effects);
        if (applied == state) return;
        applied = state; IsRequested = requested;
        Detach();
        if (!requested || highContrast || !effects) return;
        try
        {
            if (!DesktopAcrylicController.IsSupported()) return;
            material = new DesktopAcrylicBackdrop(); window.SystemBackdrop = material;
            IsActive = true;
        }
        catch (Exception error) when (error is COMException or NotSupportedException or InvalidOperationException or ObjectDisposedException)
        { Detach(); }
    }
    private void Detach()
    {
        IsActive = false;
        if (material == null) return;
        try { window.SystemBackdrop = previous; }
        catch (Exception error) when (error is COMException or InvalidOperationException or ObjectDisposedException) { }
        material = null;
    }
    public void Dispose()
    { if (disposed) return; disposed = true; Detach(); IsRequested = false; }
}
