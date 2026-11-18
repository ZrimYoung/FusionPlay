using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace FusionPlay.Windows.Platform;

/// <summary>Only window height changes on each tick; the content owns its compositor transition.</summary>
internal sealed class WindowResizeTransition : IDisposable
{
    private readonly Window window;
    private readonly ISquareWindow constraint;
    private readonly DispatcherQueueTimer timer;
    private readonly nint hwnd;
    private Action? completion;
    private double width, startHeight, targetHeight, scale;
    private int lastHeightPixels;
    private long started, revision;
    private bool disposed;
    internal bool IsRunning { get; private set; }
    internal long HeightUpdates { get; private set; }
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint hwnd, out Rect rect);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint hwnd);

    internal WindowResizeTransition(Window window, ISquareWindow constraint)
    {
        this.window = window; this.constraint = constraint; hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        timer = window.DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromMilliseconds(16); timer.IsRepeating = true; timer.Tick += Tick;
    }
    internal void AnimateLyrics(bool visible, bool animate, Action completed)
    {
        if (disposed) return;
        Cancel(); ++revision; completion = completed; constraint.SetLayoutTransition(true);
        if (window.AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Restored }
            || !GetClientRect(hwnd, out var client) || !GetWindowRect(hwnd, out var outer)) { Finish(); return; }
        scale = Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
        width = (client.Right - client.Left) / scale; startHeight = (client.Bottom - client.Top) / scale;
        if (width <= 0 || startHeight <= 0) { Finish(); return; }
        int frameHeight = outer.Bottom - outer.Top - client.Bottom + client.Top;
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        double maximumHeight = Math.Max(1, area.Height - frameHeight) / scale;
        // A short wide lyric window remains wide when lyrics disappear. Grow the
        // missing few DIPs rather than abruptly becoming a small square.
        targetHeight = Math.Min(maximumHeight, width < 600 ? visible ? Math.Max(startHeight, width * 1.65) : width
            : !visible && startHeight < 360 ? 360 : startHeight);
        lastHeightPixels = client.Bottom - client.Top;
        if (Math.Abs(targetHeight - startHeight) * scale < 1) { Finish(); return; }
        IsRunning = true;
        if (!animate || !Backdrop.AnimationsEnabled) { Resize(targetHeight); Finish(); return; }
        started = Stopwatch.GetTimestamp(); timer.Start();
    }
    private void Tick(DispatcherQueueTimer sender, object args)
    {
        if (disposed || !IsRunning) return;
        try
        {
            if (window.AppWindow.Presenter is not OverlappedPresenter { State: OverlappedPresenterState.Restored }
                || Math.Abs(Math.Max(96, GetDpiForWindow(hwnd)) / 96.0 - scale) > .001
                || !GetClientRect(hwnd, out var client) || Math.Abs((client.Right - client.Left) / scale - width) > 1)
            { Finish(); return; }
            double t = Math.Clamp(Stopwatch.GetElapsedTime(started).TotalMilliseconds / 320, 0, 1);
            double eased = t * t * (3 - 2 * t);
            Resize(startHeight + (targetHeight - startHeight) * eased);
            if (t >= 1) Finish();
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException or InvalidOperationException or ArgumentException)
        { Finish(); }
    }
    private void Resize(double height)
    {
        int pixels = (int)Math.Round(height * scale, MidpointRounding.AwayFromZero);
        if (pixels == lastHeightPixels) return;
        lastHeightPixels = pixels;
        WindowSizing.ResizeContent(window, width, pixels / scale); HeightUpdates++;
    }
    private void Finish()
    {
        timer.Stop(); IsRunning = false;
        long token = revision; var action = completion; completion = null;
        try { if (!disposed) action?.Invoke(); }
        finally { if (token == revision) constraint.SetLayoutTransition(false); }
    }
    internal void Cancel(bool snap = false)
    {
        ++revision; timer.Stop(); completion = null;
        bool active = IsRunning; IsRunning = false;
        try { if (snap && active && !disposed) Resize(targetHeight); }
        catch (Exception error) when (error is COMException or ObjectDisposedException or InvalidOperationException or ArgumentException) { }
        finally { constraint.SetLayoutTransition(false); }
    }
    public void Dispose()
    {
        if (disposed) return;
        Cancel(); disposed = true; timer.Tick -= Tick;
    }
}
