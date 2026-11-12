using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace FusionPlay.Windows.Platform;

internal static class WindowSizing
{
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint window, out Rect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out Rect rect);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SystemParametersInfo(uint action, uint parameter, out int value, uint flags);
    private delegate nint SubclassProc(nint hwnd, uint message, nuint wparam, nint lparam, nuint id, nuint data);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowSubclass(nint hwnd, SubclassProc procedure, nuint id, nuint data);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc procedure, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wparam, nint lparam);
    public static bool ScreenReaderActive => SystemParametersInfo(0x46, 0, out int active, 0) && active != 0;
    private static double Scale(nint hwnd) => Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
    public static void Apply(Window window, double width, double height, double minimumWidth = 0, double minimumHeight = 0)
    {
        nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        double scale = Scale(hwnd);
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        window.AppWindow.Resize(new SizeInt32(Math.Min((int)Math.Ceiling(width * scale), area.Width), Math.Min((int)Math.Ceiling(height * scale), area.Height)));
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
        {
            GetWindowRect(hwnd, out var outer); GetClientRect(hwnd, out var client);
            int frameWidth = outer.Right - outer.Left - client.Right, frameHeight = outer.Bottom - outer.Top - client.Bottom;
            if (minimumWidth > 0) presenter.PreferredMinimumWidth = Math.Min((int)Math.Ceiling(minimumWidth * scale) + frameWidth, area.Width);
            if (minimumHeight > 0) presenter.PreferredMinimumHeight = Math.Min((int)Math.Ceiling(minimumHeight * scale) + frameHeight, area.Height);
        }
    }
    public static void ResizeContent(Window window, double width, double height)
    {
        nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window); double scale = Scale(hwnd);
        if (window.AppWindow.Presenter is OverlappedPresenter presenter && presenter.State != OverlappedPresenterState.Restored) presenter.Restore();
        GetWindowRect(hwnd, out var outer); GetClientRect(hwnd, out var client);
        int frameWidth = outer.Right - outer.Left - client.Right, frameHeight = outer.Bottom - outer.Top - client.Bottom;
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        window.AppWindow.Resize(new SizeInt32(Math.Min(area.Width, (int)Math.Ceiling(width * scale) + frameWidth), Math.Min(area.Height, (int)Math.Ceiling(height * scale) + frameHeight)));
    }
    public static IDisposable CompactSquare(Window window) => new SquareConstraint(WinRT.Interop.WindowNative.GetWindowHandle(window));
    private sealed class SquareConstraint : IDisposable
    {
        private readonly nint hwnd;
        private readonly SubclassProc callback;
        private bool disposed;
        public SquareConstraint(nint handle)
        { hwnd = handle; callback = Process; SetWindowSubclass(hwnd, callback, 0x4650, 0); }
        private nint Process(nint handle, uint message, nuint edge, nint pointer, nuint id, nuint data)
        {
            // Constrain the native resize rectangle before Windows applies it, avoiding resize loops.
            if (message == 0x0214 && GetClientRect(handle, out var client) && GetWindowRect(handle, out var outer))
            {
                var next = Marshal.PtrToStructure<Rect>(pointer);
                int frameWidth = outer.Right - outer.Left - client.Right, frameHeight = outer.Bottom - outer.Top - client.Bottom;
                int width = next.Right - next.Left - frameWidth, height = next.Bottom - next.Top - frameHeight;
                double scale = Scale(handle);
                if (width / scale < 600 || height / scale < 360)
                {
                    int side = edge is 1 or 2 ? width : edge is 3 or 6 ? height : Math.Abs(width - client.Right) >= Math.Abs(height - client.Bottom) ? width : height;
                    side = Math.Max((int)Math.Ceiling(260 * scale), side);
                    int newWidth = side + frameWidth, newHeight = side + frameHeight;
                    if (edge is 1 or 4 or 7) next.Left = next.Right - newWidth; else next.Right = next.Left + newWidth;
                    if (edge is 3 or 4 or 5) next.Top = next.Bottom - newHeight; else next.Bottom = next.Top + newHeight;
                    Marshal.StructureToPtr(next, pointer, false); return 1;
                }
            }
            if (message == 0x0082) Dispose();
            return DefSubclassProc(handle, message, edge, pointer);
        }
        public void Dispose() { if (disposed) return; disposed = true; RemoveWindowSubclass(hwnd, callback, 0x4650); }
    }
}
