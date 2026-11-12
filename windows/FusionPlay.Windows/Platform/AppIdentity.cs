using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace FusionPlay.Windows.Platform;

/// <summary>Current-user Shell identity for the unpackaged, portable desktop app.</summary>
internal static class AppIdentity
{
    public const string Id = "ZrimTech.FusionPlay.Windows";
    public const string DisplayName = "FusionPlay";

    // Call before creating any window or requesting SMTC. Keep this identity
    // stable across portable-folder moves and application updates.
    public static void Initialize()
    {
        Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(Id));
        // The Windows App SDK uses the same per-user display-asset registration
        // for unpackaged apps. No shortcut, installer, COM server or startup task.
        // https://github.com/microsoft/WindowsAppSDK/blob/main/dev/AppNotifications/AppNotificationUtility.cpp
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Classes\AppUserModelId\" + Id, writable: true);
        if (key == null) throw new IOException("Unable to register the application display assets.");
        key.SetValue("DisplayName", DisplayName, RegistryValueKind.ExpandString);
        string icon = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.png"));
        if (File.Exists(icon)) key.SetValue("IconUri", icon, RegistryValueKind.ExpandString);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
}
