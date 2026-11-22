using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace FusionPlay.Windows.Platform;

/// <summary>Uses the native full-screen presenter while retaining the original overlapped presenter and frame.</summary>
internal sealed class PlayerFullScreen : IDisposable
{
    private readonly Window window;
    private readonly Func<bool> pinned;
    private readonly Action<bool> sizingPolicy;
    private OverlappedPresenter? savedPresenter;
    private RectInt32 savedFrame, savedWorkArea;
    private uint savedDpi;
    private bool wasMaximized, changing, disposed;
    public bool IsFullScreen { get; private set; }
    /// <summary>Raised before presenter, sizing policy or full-screen state changes.</summary>
    public event Action<bool>? Changing;
    public event Action? Changed;

    public PlayerFullScreen(Window window, Func<bool> pinned, Action<bool> sizingPolicy)
    {
        this.window = window; this.pinned = pinned; this.sizingPolicy = sizingPolicy;
        window.AppWindow.Changed += PresenterChanged;
    }
    public void Toggle() { if (IsFullScreen) Exit(); else Enter(); }
    public void Enter()
    {
        if (disposed || changing || IsFullScreen || window.AppWindow.Presenter is not OverlappedPresenter presenter) return;
        savedPresenter = presenter; wasMaximized = presenter.State == OverlappedPresenterState.Maximized;
        var position = window.AppWindow.Position; var size = window.AppWindow.Size;
        savedFrame = new(position.X, position.Y, size.Width, size.Height);
        savedWorkArea = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        savedDpi = Math.Max(96, GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)));
        changing = true;
        try
        {
            Changing?.Invoke(true);
            IsFullScreen = true;
            // Lift square/minimum constraints before the system changes geometry.
            sizingPolicy(true); presenter.IsAlwaysOnTop = false;
            window.AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
        }
        catch
        {
            IsFullScreen = false;
            try
            {
                window.AppWindow.SetPresenter(presenter);
                if (wasMaximized) presenter.Maximize(); else window.AppWindow.MoveAndResize(RestoredFrame());
                presenter.IsAlwaysOnTop = pinned();
            }
            finally { sizingPolicy(false); }
            throw;
        }
        finally { changing = false; }
        Changed?.Invoke();
    }
    public void Exit()
    {
        if (disposed || changing || !IsFullScreen || savedPresenter == null) return;
        changing = true;
        try
        {
            Changing?.Invoke(false);
            // Keep constraints lifted until the original frame/state is restored.
            window.AppWindow.SetPresenter(savedPresenter);
            if (wasMaximized) savedPresenter.Maximize();
            else { savedPresenter.Restore(); window.AppWindow.MoveAndResize(RestoredFrame()); }
            savedPresenter.IsAlwaysOnTop = pinned();
            IsFullScreen = false; sizingPolicy(false);
        }
        finally { changing = false; }
        Changed?.Invoke();
    }
    private RectInt32 RestoredFrame()
    {
        var work = DisplayArea.GetFromRect(savedFrame, DisplayAreaFallback.Nearest).WorkArea;
        uint dpi = savedDpi;
        var rect = new NativeRect { Left = savedFrame.X, Top = savedFrame.Y, Right = savedFrame.X + savedFrame.Width, Bottom = savedFrame.Y + savedFrame.Height };
        try { if (GetDpiForMonitor(MonitorFromRect(ref rect, 2), 0, out uint horizontal, out _) == 0) dpi = Math.Max(96, horizontal); }
        catch (DllNotFoundException) { }
        // Preserve exact user placement when the original display is unchanged.
        if (work.Equals(savedWorkArea) && dpi == savedDpi) return savedFrame;
        double scale = (double)dpi / savedDpi;
        int width = Math.Clamp((int)Math.Round(savedFrame.Width * scale), 1, Math.Max(1, work.Width));
        int height = Math.Clamp((int)Math.Round(savedFrame.Height * scale), 1, Math.Max(1, work.Height));
        int x = work.X + (int)Math.Round((savedFrame.X - savedWorkArea.X) * scale);
        int y = work.Y + (int)Math.Round((savedFrame.Y - savedWorkArea.Y) * scale);
        return new(Math.Clamp(x, work.X, work.X + work.Width - width), Math.Clamp(y, work.Y, work.Y + work.Height - height), width, height);
    }
    private void PresenterChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!changing && !disposed && IsFullScreen && args.DidPresenterChange && sender.Presenter.Kind != AppWindowPresenterKind.FullScreen) Exit();
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        window.AppWindow.Changed -= PresenterChanged; Changing = null; Changed = null;
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] private static extern nint MonitorFromRect(ref NativeRect rect, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(nint monitor, int type, out uint horizontal, out uint vertical);
}
