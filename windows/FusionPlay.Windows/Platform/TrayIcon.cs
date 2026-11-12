using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using FusionPlay.Core;
using Windows.Graphics;

namespace FusionPlay.Windows.Platform;

internal sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly nint window;
    private readonly Native.SubclassProc hook;
    private Native.NotifyIconData data;
    private readonly uint taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
    private nint idleIcon, playingIcon, pausedIcon;
    private bool visible = true, version4;
    public RectInt32? Bounds
    {
        get
        {
            var identifier = new Native.NotifyIconIdentifier { Size = (uint)Marshal.SizeOf<Native.NotifyIconIdentifier>(), Window = window, Id = data.Id };
            return Native.ShellNotifyIconGetRect(ref identifier, out var rect) == 0 ? new RectInt32(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top) : null;
        }
    }
    public bool Visible
    {
        get => visible;
        set { if (visible == value) return; visible = value; if (visible) Add(); else Native.ShellNotifyIcon(2, ref data); }
    }
    public Action? TogglePanel { get; set; }
    public Action? ShowPlayer { get; set; }
    public Action? ShowSettings { get; set; }
    public Action? ToggleReceiving { get; set; }
    public Action? Quit { get; set; }
    public Action? Suspend { get; set; }
    public Action? Resume { get; set; }
    public Action? AppearanceChanged { get; set; }
    public bool Receiving { get; set; }
    public TrayIcon(nint hwnd, string iconPath)
    {
        window = hwnd; hook = WindowMessage;
        if (!Native.SetWindowSubclass(hwnd, hook, 1, 0)) throw new InvalidOperationException("无法初始化托盘消息窗口。");
        data = new Native.NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<Native.NotifyIconData>(), Window = hwnd, Id = 1,
            Flags = 1 | 2 | 4, Callback = CallbackMessage, Tip = "FusionPlay · 等待连接",
            Icon = 0,
            Info = "", InfoTitle = "", Version = 4
        };
        CreateIcons(); data.Icon = idleIcon;
        Add();
    }
    private void Add() { Native.ShellNotifyIcon(0, ref data); data.Version = 4; version4 = Native.ShellNotifyIcon(4, ref data); }
    private void CreateIcons()
    {
        int size = Math.Clamp(Native.GetSystemMetricsForDpi(49, Native.GetDpiForWindow(window)), 16, 64);
        idleIcon = CreatePlaybackIcon(ReceiverPhase.Ready, size);
        playingIcon = CreatePlaybackIcon(ReceiverPhase.Playing, size);
        pausedIcon = CreatePlaybackIcon(ReceiverPhase.Paused, size);
    }
    public void Update(string status, ReceiverPhase phase)
    {
        string tip = "FusionPlay · " + status;
        nint icon = phase == ReceiverPhase.Playing ? playingIcon : phase == ReceiverPhase.Paused ? pausedIcon : idleIcon;
        if (icon == 0) icon = idleIcon;
        if (tip == data.Tip && icon == data.Icon) return;
        data.Icon = icon;
        data.Tip = tip.Length < 128 ? tip : tip[..127];
        if (visible) Native.ShellNotifyIcon(1, ref data);
    }
    private nint WindowMessage(nint hwnd, uint message, nuint wParam, nint lParam, nuint subclass, nuint reference)
    {
        if (message == CallbackMessage)
        {
            uint notification = (uint)(long)lParam & 0xffff;
            if (version4 ? notification is 0x400 or 0x401 : notification == 0x202) TogglePanel?.Invoke();
            if (version4 ? notification == 0x7b : notification == 0x205) ShowMenu();
            return 0;
        }
        if (message == taskbarCreated && visible) Add();
        if (message is 0x1a or 0x31a) AppearanceChanged?.Invoke();
        if (message == 0x02E0)
        {
            nint[] old = [idleIcon, playingIcon, pausedIcon];
            int state = data.Icon == playingIcon ? 1 : data.Icon == pausedIcon ? 2 : 0;
            CreateIcons(); data.Icon = state == 1 ? playingIcon : state == 2 ? pausedIcon : idleIcon;
            if (visible) Native.ShellNotifyIcon(1, ref data);
            foreach (nint icon in old) if (icon != 0) Native.DestroyIcon(icon);
        }
        if (message == 0x218)
        {
            if (wParam == 4) Suspend?.Invoke();
            if (wParam is 7 or 18) Resume?.Invoke();
        }
        return Native.DefSubclassProc(hwnd, message, wParam, lParam);
    }
    private void ShowMenu()
    {
        nint menu = Native.CreatePopupMenu();
        try
        {
            Native.AppendMenu(menu, 0, 1, L.Text("显示播放窗口"));
            Native.AppendMenu(menu, 0, 2, L.Text("设置"));
            Native.AppendMenu(menu, 0, 3, L.Text(Receiving ? "停止接收" : "启动接收"));
            Native.AppendMenu(menu, 0x800, 0, "");
            Native.AppendMenu(menu, 0, 4, L.Text("退出"));
            Native.GetCursorPos(out var point); Native.SetForegroundWindow(window);
            uint selected = Native.TrackPopupMenu(menu, 0x100 | 2, point.X, point.Y, 0, window, 0);
            Native.PostMessage(window, 0, 0, 0);
            switch (selected)
            {
                case 1: ShowPlayer?.Invoke(); break;
                case 2: ShowSettings?.Invoke(); break;
                case 3: ToggleReceiving?.Invoke(); break;
                case 4: Quit?.Invoke(); break;
            }
        }
        finally { Native.DestroyMenu(menu); }
    }
    public void Dispose()
    {
        Native.ShellNotifyIcon(2, ref data); Native.RemoveWindowSubclass(window, hook, 1);
        foreach (nint icon in new[] { idleIcon, playingIcon, pausedIcon }) if (icon != 0) Native.DestroyIcon(icon);
        GC.KeepAlive(hook);
    }
    // Small vector status marks, supersampled into a premultiplied BGRA icon.
    private static nint CreatePlaybackIcon(ReceiverPhase state, int size)
    {
        const int samples = 8;
        byte[] pixels = new byte[size * size * 4];
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
        {
            int coverage = 0;
            for (int sy = 0; sy < samples; sy++) for (int sx = 0; sx < samples; sx++)
            {
                double px = (x + (sx + .5) / samples) * 24 / size, py = (y + (sy + .5) / samples) * 24 / size;
                bool Ring(double cx, double radius) => Math.Abs(Math.Sqrt((px - cx) * (px - cx) + (py - 12) * (py - 12)) - radius) <= 1.35;
                bool mark;
                if (state is not (ReceiverPhase.Playing or ReceiverPhase.Paused)) mark = Ring(8.5, 7) || Ring(15.5, 7);
                else
                {
                    bool glyph = state == ReceiverPhase.Paused ? py >= 7 && py <= 17 && (px >= 8.5 && px <= 11 || px >= 13 && px <= 15.5)
                        : px >= 9 && px <= 17 && Math.Abs(py - 12) <= (17 - px) * .75;
                    mark = Ring(12, 9.5) || glyph;
                }
                if (mark) coverage++;
            }
            int i = (y * size + x) * 4, alpha = coverage * 255 / (samples * samples);
            pixels[i] = pixels[i + 1] = pixels[i + 2] = pixels[i + 3] = (byte)alpha;
        }
        var header = new Native.BitmapInfoHeader { Size = 40, Width = size, Height = -size, Planes = 1, BitCount = 32, SizeImage = (uint)pixels.Length };
        nint bitmap = Native.CreateDIBSection(0, ref header, 0, out nint bits, 0, 0);
        nint mask = Native.CreateBitmap(size, size, 1, 1, new byte[((size + 15) / 16 * 2) * size]);
        try
        {
            if (bitmap == 0 || mask == 0 || bits == 0) return 0;
            Marshal.Copy(pixels, 0, bits, pixels.Length);
            var info = new Native.IconInfo { IsIcon = true, Mask = mask, Color = bitmap };
            return Native.CreateIconIndirect(ref info);
        }
        finally { if (bitmap != 0) Native.DeleteObject(bitmap); if (mask != 0) Native.DeleteObject(mask); }
    }
    internal static class Native
    {
        [StructLayout(LayoutKind.Sequential)] internal struct NotifyIconIdentifier { public uint Size; public nint Window; public uint Id; public Guid GuidItem; }
        [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
        [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconGetRect")] internal static extern int ShellNotifyIconGetRect(ref NotifyIconIdentifier identifier, out Rect rect);
        [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(nint window);
        [DllImport("user32.dll")] internal static extern int GetSystemMetricsForDpi(int index, uint dpi);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct NotifyIconData
        {
            public uint Size; public nint Window; public uint Id, Flags, Callback; public nint Icon;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
            public uint State, StateMask;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
            public uint Version;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
            public uint InfoFlags; public Guid GuidItem; public nint BalloonIcon;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct BitmapInfoHeader
        {
            public uint Size; public int Width, Height; public ushort Planes, BitCount;
            public uint Compression, SizeImage; public int XPelsPerMeter, YPelsPerMeter; public uint ClrUsed, ClrImportant;
        }
        [StructLayout(LayoutKind.Sequential)] internal struct IconInfo { [MarshalAs(UnmanagedType.Bool)] public bool IsIcon; public uint XHotspot, YHotspot; public nint Mask, Color; }
        [DllImport("gdi32.dll")] internal static extern nint CreateDIBSection(nint dc, ref BitmapInfoHeader info, uint usage, out nint bits, nint section, uint offset);
        [DllImport("gdi32.dll")] internal static extern nint CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, byte[] bits);
        [DllImport("gdi32.dll")] internal static extern bool DeleteObject(nint item);
        [DllImport("user32.dll")] internal static extern nint CreateIconIndirect(ref IconInfo info);
        [StructLayout(LayoutKind.Sequential)] internal struct Point { public int X, Y; }
        internal delegate nint SubclassProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint reference);
        [DllImport("comctl32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nuint reference);
        [DllImport("comctl32.dll")] internal static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);
        [DllImport("comctl32.dll")] internal static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
        [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] internal static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);
        [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode)] internal static extern nint LoadImage(nint instance, string name, uint type, int width, int height, uint load);
        [DllImport("user32.dll")] internal static extern bool DestroyIcon(nint icon);
        [DllImport("user32.dll", EntryPoint = "RegisterWindowMessageW", CharSet = CharSet.Unicode)] internal static extern uint RegisterWindowMessage(string message);
        [DllImport("user32.dll")] internal static extern nint CreatePopupMenu();
        [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)] internal static extern bool AppendMenu(nint menu, uint flags, nuint id, string label);
        [DllImport("user32.dll")] internal static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint hwnd, nint rectangle);
        [DllImport("user32.dll")] internal static extern bool DestroyMenu(nint menu);
        [DllImport("user32.dll")] internal static extern bool GetCursorPos(out Point point);
        [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint hwnd);
        [DllImport("user32.dll", EntryPoint = "PostMessageW")] internal static extern bool PostMessage(nint hwnd, uint message, nuint wParam, nint lParam);
        [DllImport("user32.dll")] internal static extern bool ShowWindow(nint hwnd, int command);
    }
}
