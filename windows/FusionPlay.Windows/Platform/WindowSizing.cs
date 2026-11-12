using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace FusionPlay.Windows.Platform;

internal interface ISquareWindow : IDisposable
{
    void UpdateInputRegions(RectInt32[] passthrough);
}

internal static class WindowSizing
{
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public uint Size; public Rect Monitor, Work; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct CursorPoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] private static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint window, out Rect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out Rect rect);
    [DllImport("user32.dll")] private static extern nint MonitorFromRect(ref Rect rect, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(nint window, nint insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out CursorPoint point);
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(CursorPoint point);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, uint size);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SystemParametersInfo(uint action, uint parameter, out int value, uint flags);
    private delegate nint SubclassProc(nint hwnd, uint message, nuint wparam, nint lparam, nuint id, nuint data);
    [DllImport("comctl32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowSubclass(nint hwnd, SubclassProc procedure, nuint id, nuint data);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc procedure, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wparam, nint lparam);
    public static bool ScreenReaderActive => SystemParametersInfo(0x46, 0, out int active, 0) && active != 0;
    public static bool IsCompactContent(double widthDips, double heightDips) => widthDips < 600 || heightDips < 360;
    private static double Scale(nint hwnd) => Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
    private static bool IsCompact(nint hwnd, int width, int height)
        => IsCompactContent(width / Scale(hwnd), height / Scale(hwnd));
    private static int Width(Rect rect) => rect.Right - rect.Left;
    private static int Height(Rect rect) => rect.Bottom - rect.Top;
    private static (int Width, int Height) Frame(nint hwnd)
    {
        GetWindowRect(hwnd, out var outer); GetClientRect(hwnd, out var client);
        return (Math.Max(0, Width(outer) - Width(client)), Math.Max(0, Height(outer) - Height(client)));
    }
    private static Rect WorkArea(Rect proposed)
    {
        var info = new MonitorInfo { Size = (uint)Marshal.SizeOf<MonitorInfo>() };
        if (GetMonitorInfo(MonitorFromRect(ref proposed, 2), ref info)) return info.Work;
        var fallback = DisplayArea.Primary.WorkArea;
        return new Rect { Left = fallback.X, Top = fallback.Y, Right = fallback.X + fallback.Width, Bottom = fallback.Y + fallback.Height };
    }
    private static int SquareSide(nint hwnd, Rect proposed, int requested, (int Width, int Height) frame)
    {
        var work = WorkArea(proposed);
        int maximum = Math.Max(1, Math.Min(Width(work) - frame.Width, Height(work) - frame.Height));
        int minimum = Math.Min(maximum, (int)Math.Ceiling(260 * Scale(hwnd)));
        return Math.Clamp(requested, minimum, maximum);
    }
    private static Rect FitPosition(Rect proposed)
    {
        var work = WorkArea(proposed);
        int width = Width(proposed), height = Height(proposed);
        int left = Math.Clamp(proposed.Left, work.Left, Math.Max(work.Left, work.Right - width));
        int top = Math.Clamp(proposed.Top, work.Top, Math.Max(work.Top, work.Bottom - height));
        return new Rect { Left = left, Top = top, Right = left + width, Bottom = top + height };
    }
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
        GetWindowRect(hwnd, out var outer); var frame = Frame(hwnd);
        if (width == height)
        {
            int side = SquareSide(hwnd, outer, (int)Math.Ceiling(width * scale), frame);
            var next = FitPosition(new Rect { Left = outer.Left, Top = outer.Top, Right = outer.Left + side + frame.Width, Bottom = outer.Top + side + frame.Height });
            window.AppWindow.MoveAndResize(new RectInt32(next.Left, next.Top, Width(next), Height(next)));
        }
        else
        {
            var area = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            window.AppWindow.Resize(new SizeInt32(Math.Min(area.Width, (int)Math.Ceiling(width * scale) + frame.Width), Math.Min(area.Height, (int)Math.Ceiling(height * scale) + frame.Height)));
        }
    }
    // Existing callers retain this API. Only compact content is constrained to
    // a square; the expanded player remains freely resizable in both axes.
    public static ISquareWindow FixedSquare(Window window, Action<bool> hoverChanged)
        => new SquareConstraint(window, hoverChanged);
    private sealed class SquareConstraint : ISquareWindow
    {
        private readonly Window window;
        private readonly nint hwnd;
        private readonly SubclassProc callback;
        private readonly InputNonClientPointerSource input;
        private readonly Action<bool> hoverChanged;
        private bool disposed, settling, settlementQueued, regionRefreshQueued, inMoveSize, hover;
        private RectInt32[] passthrough = [];
        private int regionWidth, regionHeight;
        private int resizeStartWidth, resizeStartHeight;
        private uint dpi;
        public SquareConstraint(Window target, Action<bool> changed)
        {
            window = target; hwnd = WinRT.Interop.WindowNative.GetWindowHandle(target); callback = Process;
            hoverChanged = changed; dpi = GetDpiForWindow(hwnd);
            input = InputNonClientPointerSource.GetForWindowId(target.AppWindow.Id);
            if (!SetWindowSubclass(hwnd, callback, 0x4650, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
            // Recalculate once after installing the zero-inset client area. Keep the
            // native thick frame for resizing, while DWM supplies Windows 11 corners.
            int rounded = 2; DwmSetWindowAttribute(hwnd, 33, ref rounded, sizeof(int));
            SetWindowPos(hwnd, 0, 0, 0, 0, 0, 0x0037);
            input.PointerEntered += PointerEntered;
            input.PointerMoved += PointerEntered;
            input.PointerExited += PointerExited;
            input.WindowRectChanged += WindowRectChanged;
            input.EnteredMoveSize += EnteredMoveSize;
            input.ExitedMoveSize += ExitedMoveSize;
            RefreshRegions(force: true);
            QueueSettlement(force: true);
        }
        private nint Process(nint handle, uint message, nuint argument, nint pointer, nuint id, nuint data)
        {
            if (message == 0x0083) return 0; // WM_NCCALCSIZE: the whole window is client content.
            if (message == 0x0006) SetHover((argument & 0xFFFF) != 0 && CursorIsOverWindow());
            if (message == 0x0018 && argument == 0) SetHover(false);
            if (message == 0x0112 && (argument & 0xFFF0) == 0xF030) return 0;
            if (message == 0x0231)
            {
                inMoveSize = true;
                if (GetClientRect(handle, out var start)) { resizeStartWidth = Width(start); resizeStartHeight = Height(start); }
            }
            if (message == 0x0214 && GetClientRect(handle, out var client))
            {
                // The OS applies this one rectangle during manual resize. No second
                // WINDOWPOS correction, position clamping, or queued resize runs here.
                var next = Marshal.PtrToStructure<Rect>(pointer); var frame = Frame(handle);
                int width = Width(next) - frame.Width, height = Height(next) - frame.Height;
                if (!IsCompact(handle, width, height)) return DefSubclassProc(handle, message, argument, pointer);
                int startWidth = resizeStartWidth > 0 ? resizeStartWidth : Width(client);
                int startHeight = resizeStartHeight > 0 ? resizeStartHeight : Height(client);
                // Compare against the gesture's original size. Comparing with the
                // last constrained square alternates the dominant corner axis and
                // makes a steadily moving pointer repeatedly grow/shrink the window.
                int requested = argument is 1 or 2 ? width : argument is 3 or 6 ? height : Math.Abs(width - startWidth) >= Math.Abs(height - startHeight) ? width : height;
                // A corner shrink from the expanded layout can cross the height
                // threshold while the dominant width is still >=600. Select the
                // smaller extent then, so entering compact mode cannot bounce
                // immediately back to an expanded square.
                if (!IsCompact(handle, startWidth, startHeight) && !IsCompact(handle, requested, requested)) requested = Math.Min(width, height);
                int side = SquareSide(handle, next, requested, frame);
                if (argument is 1 or 4 or 7) next.Left = next.Right - side - frame.Width; else next.Right = next.Left + side + frame.Width;
                if (argument is 3 or 4 or 5) next.Top = next.Bottom - side - frame.Height; else next.Bottom = next.Top + side + frame.Height;
                Marshal.StructureToPtr(next, pointer, false); return 1;
            }
            if (message == 0x0232) { inMoveSize = false; resizeStartWidth = resizeStartHeight = 0; QueueSettlement(); SetHover(CursorIsOverWindow()); }
            if (message == 0x0047 && !inMoveSize) QueueSettlement();
            if (message == 0x02E0) QueueSettlement(force: true);
            if (message == 0x0082) Dispose();
            nint result = DefSubclassProc(handle, message, argument, pointer);
            // InputNonClientPointerSource can publish WindowRectChanged before the
            // WinUI window procedure has updated its client bounds. Refresh input
            // rectangles after that procedure returns, once per dispatcher turn.
            // This updates routing only and never resizes or moves the window.
            if (message is 0x0005 or 0x0047 or 0x02E0) QueueRegionRefresh();
            return result;
        }
        private void PointerEntered(InputNonClientPointerSource sender, NonClientPointerEventArgs args) => SetHover(true);
        private void PointerExited(InputNonClientPointerSource sender, NonClientPointerEventArgs args) => SetHover(CursorIsOverWindow());
        private void WindowRectChanged(InputNonClientPointerSource sender, WindowRectChangedEventArgs args)
        {
            if (args.NewWindowRect.Width != args.OldWindowRect.Width || args.NewWindowRect.Height != args.OldWindowRect.Height) QueueRegionRefresh(force: true);
        }
        private void EnteredMoveSize(InputNonClientPointerSource sender, EnteredMoveSizeEventArgs args)
        {
            inMoveSize = true;
            if (GetClientRect(hwnd, out var start)) { resizeStartWidth = Width(start); resizeStartHeight = Height(start); }
        }
        private void ExitedMoveSize(InputNonClientPointerSource sender, ExitedMoveSizeEventArgs args)
        { inMoveSize = false; resizeStartWidth = resizeStartHeight = 0; QueueSettlement(); SetHover(CursorIsOverWindow()); }
        public void UpdateInputRegions(RectInt32[] rectangles)
        {
            if (disposed) return;
            bool changed = !passthrough.SequenceEqual(rectangles);
            if (changed) passthrough = rectangles.ToArray();
            // Stable controls still need new caption and border bounds on resize.
            RefreshRegions(force: changed);
        }
        private void QueueRegionRefresh(bool force = false)
        {
            if (disposed || regionRefreshQueued) return;
            if (!force && GetClientRect(hwnd, out var client) && Width(client) == regionWidth && Height(client) == regionHeight) return;
            regionRefreshQueued = true;
            if (!window.DispatcherQueue.TryEnqueue(() =>
            {
                regionRefreshQueued = false;
                if (!disposed) RefreshRegions();
            })) regionRefreshQueued = false;
        }
        private void RefreshRegions(bool force = false)
        {
            if (disposed || IsIconic(hwnd) || !GetClientRect(hwnd, out var client)) return;
            int width = Width(client), height = Height(client);
            if (width < 1 || height < 1 || !force && width == regionWidth && height == regionHeight) return;
            regionWidth = width; regionHeight = height;
            uint currentDpi = Math.Max(96, GetDpiForWindow(hwnd));
            int border = Math.Min(Math.Min(width, height) / 2, Math.Max((int)Math.Ceiling(4 * currentDpi / 96.0), GetSystemMetricsForDpi(32, currentDpi) + GetSystemMetricsForDpi(92, currentDpi)));
            var interior = new RectInt32(border, border, width - border * 2, height - border * 2);
            var holes = passthrough.Select(r => Intersect(r, interior)).Where(r => r.Width > 0 && r.Height > 0).ToArray();
            var caption = new List<RectInt32> { interior };
            foreach (var hole in holes) caption = caption.SelectMany(r => Subtract(r, hole)).ToList();
            // Explicitly partition the regions. Neither controls nor caption overlap
            // a resize border, so correctness does not depend on undocumented priority.
            input.SetRegionRects(NonClientRegionKind.TopBorder, [new(0, 0, width, border)]);
            input.SetRegionRects(NonClientRegionKind.BottomBorder, [new(0, height - border, width, border)]);
            input.SetRegionRects(NonClientRegionKind.LeftBorder, [new(0, border, border, height - border * 2)]);
            input.SetRegionRects(NonClientRegionKind.RightBorder, [new(width - border, border, border, height - border * 2)]);
            input.SetRegionRects(NonClientRegionKind.Caption, caption.Where(r => r.Width > 0 && r.Height > 0).ToArray());
            input.SetRegionRects(NonClientRegionKind.Passthrough, holes);
        }
        private static RectInt32 Intersect(RectInt32 a, RectInt32 b)
        {
            int x = Math.Max(a.X, b.X), y = Math.Max(a.Y, b.Y);
            return new(x, y, Math.Max(0, Math.Min(a.X + a.Width, b.X + b.Width) - x), Math.Max(0, Math.Min(a.Y + a.Height, b.Y + b.Height) - y));
        }
        private static IEnumerable<RectInt32> Subtract(RectInt32 rectangle, RectInt32 hole)
        {
            var overlap = Intersect(rectangle, hole);
            if (overlap.Width <= 0 || overlap.Height <= 0) { yield return rectangle; yield break; }
            if (overlap.Y > rectangle.Y) yield return new(rectangle.X, rectangle.Y, rectangle.Width, overlap.Y - rectangle.Y);
            int bottom = overlap.Y + overlap.Height, right = overlap.X + overlap.Width;
            if (bottom < rectangle.Y + rectangle.Height) yield return new(rectangle.X, bottom, rectangle.Width, rectangle.Y + rectangle.Height - bottom);
            if (overlap.X > rectangle.X) yield return new(rectangle.X, overlap.Y, overlap.X - rectangle.X, overlap.Height);
            if (right < rectangle.X + rectangle.Width) yield return new(right, overlap.Y, rectangle.X + rectangle.Width - right, overlap.Height);
        }
        private bool CursorIsOverWindow()
        {
            if (!GetCursorPos(out var point) || !GetWindowRect(hwnd, out var rect)) return false;
            return point.X >= rect.Left && point.X < rect.Right && point.Y >= rect.Top && point.Y < rect.Bottom && GetAncestor(WindowFromPoint(point), 2) == hwnd;
        }
        private void SetHover(bool value)
        {
            if (disposed || hover == value) return;
            hover = value;
            try { hoverChanged(value); }
            catch (Exception error) when (error is COMException or InvalidOperationException or ArgumentException) { }
        }
        private void QueueSettlement(bool force = false)
        {
            if (disposed || settling || settlementQueued || inMoveSize || IsIconic(hwnd)) return;
            if (!force && GetDpiForWindow(hwnd) == dpi && GetClientRect(hwnd, out var client)
                && (!IsCompact(hwnd, Width(client), Height(client)) || Width(client) == Height(client))) return;
            settlementQueued = true;
            if (!window.DispatcherQueue.TryEnqueue(() =>
            {
                settlementQueued = false;
                if (disposed || inMoveSize || IsIconic(hwnd) || !GetWindowRect(hwnd, out var outer) || !GetClientRect(hwnd, out var client)) return;
                var frame = Frame(hwnd); var work = WorkArea(outer);
                if (window.AppWindow.Presenter is OverlappedPresenter presenter)
                {
                    dpi = GetDpiForWindow(hwnd);
                    int minimum = Math.Min((int)Math.Ceiling(260 * Scale(hwnd)), Math.Max(1, Math.Min(Width(work) - frame.Width, Height(work) - frame.Height)));
                    presenter.PreferredMinimumWidth = minimum + frame.Width; presenter.PreferredMinimumHeight = minimum + frame.Height;
                }
                if (!IsCompact(hwnd, Width(client), Height(client))) return;
                int side = SquareSide(hwnd, outer, Math.Min(Width(client), Height(client)), frame);
                int width = side + frame.Width, height = side + frame.Height;
                if (width == Width(outer) && height == Height(outer)) return;
                settling = true;
                // Resize only once for an external shell/DPI rectangle, keeping the
                // location chosen by the user. Never pull a moving window on-screen.
                try { SetWindowPos(hwnd, 0, 0, 0, width, height, 0x0016); }
                finally { settling = false; }
            })) settlementQueued = false;
        }
        public void Dispose()
        {
            if (disposed) return; disposed = true;
            try
            {
                input.PointerEntered -= PointerEntered; input.PointerMoved -= PointerEntered; input.PointerExited -= PointerExited;
                input.WindowRectChanged -= WindowRectChanged; input.EnteredMoveSize -= EnteredMoveSize; input.ExitedMoveSize -= ExitedMoveSize;
                input.ClearAllRegionRects();
            }
            catch (Exception error) when (error is COMException or InvalidOperationException) { }
            finally { RemoveWindowSubclass(hwnd, callback, 0x4650); }
        }
    }
}
