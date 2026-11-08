using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace FusionPlay.Windows.Platform;

internal static class WindowSizing
{
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    public static void Apply(Window window, double width, double height, double minimumWidth = 0, double minimumHeight = 0)
    {
        // AppWindow dimensions are physical pixels; XAML layout uses DIPs.
        double scale = Math.Max(96, GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window))) / 96.0;
        var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        window.AppWindow.Resize(new SizeInt32(
            Math.Min((int)Math.Ceiling(width * scale), area.Width),
            Math.Min((int)Math.Ceiling(height * scale), area.Height)));
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
        {
            if (minimumWidth > 0) presenter.PreferredMinimumWidth = Math.Min((int)Math.Ceiling(minimumWidth * scale), area.Width);
            if (minimumHeight > 0) presenter.PreferredMinimumHeight = Math.Min((int)Math.Ceiling(minimumHeight * scale), area.Height);
        }
    }
}
