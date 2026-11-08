using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;

namespace FusionPlay.Windows.Platform;

internal sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private readonly nint window;
    private readonly Native.SubclassProc hook;
    private Native.NotifyIconData data;
    private readonly uint taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
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
            Icon = Native.LoadImage(0, iconPath, 1, 0, 0, 0x10 | 0x40),
            Info = "", InfoTitle = "", Version = 4
        };
        Add();
    }
    private void Add() { Native.ShellNotifyIcon(0, ref data); data.Version = 4; Native.ShellNotifyIcon(4, ref data); }
    public void Update(string status)
    {
        string tip = "FusionPlay · " + status;
        if (tip == data.Tip) return;
        data.Tip = tip.Length < 128 ? tip : tip[..127];
        Native.ShellNotifyIcon(1, ref data);
    }
    private nint WindowMessage(nint hwnd, uint message, nuint wParam, nint lParam, nuint subclass, nuint reference)
    {
        if (message == CallbackMessage)
        {
            uint notification = (uint)(long)lParam & 0xffff;
            if (notification is 0x400 or 0x401 or 0x202) TogglePanel?.Invoke();
            if (notification is 0x205 or 0x7b) ShowMenu();
            return 0;
        }
        if (message == taskbarCreated) Add();
        if (message is 0x1a or 0x31a) AppearanceChanged?.Invoke();
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
            Native.AppendMenu(menu, 0, 1, "显示播放窗口");
            Native.AppendMenu(menu, 0, 2, "设置");
            Native.AppendMenu(menu, 0, 3, Receiving ? "停止接收" : "开始接收");
            Native.AppendMenu(menu, 0x800, 0, "");
            Native.AppendMenu(menu, 0, 4, "退出");
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
        if (data.Icon != 0) Native.DestroyIcon(data.Icon);
        GC.KeepAlive(hook);
    }
    internal static class Native
    {
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
