using Microsoft.UI.Xaml;
using FusionPlay.Windows.Platform;

namespace FusionPlay.Windows;

public partial class App : Application
{
    private SingleInstance? instance;
    private MainWindow? player;
    private SettingsWindow? settings;
    private TrayWindow? panel;
    private ReceiverController? controller;
    private TrayIcon? tray;
    private SystemMedia? media;
    private bool quitting;
    private static void StartupRecord(string stage, Exception? error = null)
    {
        try
        {
            string logs = Path.Combine(AppContext.BaseDirectory, "FusionPlayData", "logs");
            Directory.CreateDirectory(logs);
            string file = Path.Combine(logs, "startup.jsonl");
            if (File.Exists(file) && new FileInfo(file).Length > 100_000) File.Move(file, Path.Combine(logs, "startup.previous.jsonl"), true);
            File.AppendAllText(file, System.Text.Json.JsonSerializer.Serialize(new
            {
                time = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), stage,
                error_type = error?.GetType().Name, hresult = error?.HResult.ToString("X8"),
                xaml_error = error?.GetType().Name == "XamlParseException" ? error.Message : null
            }) + "\n");
        }
        catch { }
    }
    public App()
    {
        StartupRecord("application_constructing");
        UnhandledException += (_, args) =>
        {
            StartupRecord("unhandled_exception", args.Exception);
            if (Environment.GetCommandLineArgs().Contains("--typography-check"))
            { TypographyCheck.UnhandledErrors.Add(args.Exception.ToString()); args.Handled = true; }
        };
        try { InitializeComponent(); StartupRecord("resources_ready"); }
        catch (Exception e) { StartupRecord("resources_failed", e); throw; }
    }
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (Environment.GetCommandLineArgs().Contains("--typography-check"))
        {
            try { await TypographyCheck.Run(Path.Combine(AppContext.BaseDirectory, "typography-check")); }
            catch (Exception error) { StartupRecord("typography_check_failed", error); }
            finally { Exit(); }
            return;
        }
        if (Environment.GetCommandLineArgs().Contains("--seek-input-check"))
        {
            // Separate, hidden seek-target check; never contacts the running app,
            // creates a receiver, or enters visible startup/fallback handling.
            try { await SeekInputCheck.Run(Path.Combine(AppContext.BaseDirectory, "seek-input-check.json")); }
            catch (Exception error) { StartupRecord("seek_input_check_failed", error); }
            finally { Exit(); }
            return;
        }
        if (Environment.GetCommandLineArgs().Contains("--tray-layout-check"))
        {
            // This isolated diagnostic never enters single-instance notification,
            // receiver initialization, shell-media registration or visible launch.
            try { await TrayLayoutCheck.Run(Path.Combine(AppContext.BaseDirectory, "tray-layout-check.json")); }
            catch (Exception error) { StartupRecord("tray_layout_check_failed", error); }
            finally { Exit(); }
            return;
        }
        if (Environment.GetCommandLineArgs().Contains("--window-input-check"))
        {
            // Hidden, isolated input-registration check: no receiver, shell-media
            // registration, single-instance notification or visible activation.
            try
            {
                string thumbnailReport = Path.Combine(AppContext.BaseDirectory, "thumbnail-check.json");
                try
                {
                    var thumbnail = await SystemMedia.CheckThumbnailAsync(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.png")));
                    File.WriteAllText(thumbnailReport, System.Text.Json.JsonSerializer.Serialize(new
                    { status = "passed", width = thumbnail.Width, height = thumbnail.Height, system_media_session_created = false }));
                }
                catch (Exception error)
                {
                    File.WriteAllText(thumbnailReport, System.Text.Json.JsonSerializer.Serialize(new
                    { status = "failed", exception_type = error.GetType().Name, hresult = error.HResult.ToString("X8"), system_media_session_created = false }));
                }
                await WindowInputCheck.Run(Path.Combine(AppContext.BaseDirectory, "window-input-check.json"));
            }
            catch (Exception error) { StartupRecord("window_input_check_failed", error); }
            finally { Exit(); }
            return;
        }
        try { await LaunchAsync(); }
        catch (Exception e)
        {
            StartupRecord("launch_failed", e);
            var message = new Microsoft.UI.Xaml.Controls.StackPanel { Padding = new Thickness(28), Spacing = 18 };
            message.Children.Add(new Microsoft.UI.Xaml.Controls.TextBlock { Text = "FusionPlay 启动未完成", FontSize = 22 });
            message.Children.Add(new Microsoft.UI.Xaml.Controls.TextBlock { Text = "请确认已完整解压程序包，并将整个文件夹放在可写位置。可在程序旁的 FusionPlayData/logs 中查看启动记录。", TextWrapping = TextWrapping.Wrap });
            var close = new Microsoft.UI.Xaml.Controls.Button { Content = "退出" }; close.Click += (_, _) => _ = QuitAsync(); message.Children.Add(close);
            var fallback = new Window { Title = "FusionPlay", Content = message };
            fallback.Closed += (_, _) => _ = QuitAsync();
            fallback.AppWindow.Resize(new global::Windows.Graphics.SizeInt32(500, 280)); fallback.Activate();
        }
    }
    private async Task LaunchAsync()
    {
        StartupRecord("launching");
        instance = new SingleInstance();
        if (!instance.IsPrimary) { await instance.NotifyPrimaryAsync(); instance.Dispose(); Exit(); return; }
        try { AppIdentity.Initialize(); }
        catch (Exception error) { StartupRecord("app_identity_failed", error); }
        controller = new ReceiverController(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
        StartupRecord("creating_player");
        player = new MainWindow(controller, OpenSettings);
        StartupRecord("player_created");
        player.ClosingToTray += () =>
        {
            panel?.HidePanel();
            if (!controller.Preferences.Value.ShowTrayIcon) OpenSettings();
        };
        player.Activate();
        StartupRecord("player_activated");
        nint hwnd = WinRT.Interop.WindowNative.GetWindowHandle(player);
        tray = new TrayIcon(hwnd, Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"))
        {
            ShowPlayer = ShowPlayer, ShowSettings = OpenSettings, Quit = () => _ = QuitAsync(),
            ToggleReceiving = () => _ = controller.WantsReceiving ? controller.StopAsync() : controller.StartAsync(),
            TogglePanel = TogglePanel, Suspend = () => { panel?.HidePanel(); media?.Clear(); controller.Suspend(); },
            Resume = () => controller.Resume(), AppearanceChanged = () => player.RefreshAppearance()
        };
        try { media = new SystemMedia(hwnd, command => controller.DispatchControl(command), controller.Store.EventDiagnostic); }
        catch (Exception) { controller.Store.EventDiagnostic("system_media_initialization_failed"); }
        controller.Changed += () =>
        {
            tray.Receiving = controller.WantsReceiving;
            tray.Visible = controller.Preferences.Value.ShowTrayIcon;
            player.AppWindow.IsShownInSwitchers = controller.Preferences.Value.ShowTaskbarIcon;
            tray.Update(L.Text(controller.State.PhaseLabel), controller.State.Phase);
            try { media?.Update(controller); } catch (Exception) { controller.Store.EventDiagnostic("system_media_update_failed"); }
        };
        instance.Listen(() => player.DispatcherQueue.TryEnqueue(Reopen));
        await controller.InitializeAsync();
        if (controller.Preferences.LoadError.Length > 0) controller.Store.EventDiagnostic("ui_preferences_recovered");
        if (!controller.Preferences.Value.ShowTaskbarIcon && !controller.Preferences.Value.ShowTrayIcon) OpenSettings();
        StartupRecord("receiver_initialized");
        controller.Store.EventDiagnostic(media == null ? "system_media_initialization_failed" : "system_media_ready");
    }
    private void ShowPlayer()
    {
        if (player == null) return;
        panel?.HidePanel(); player.AppWindow.Show();
        TrayIcon.Native.ShowWindow(WinRT.Interop.WindowNative.GetWindowHandle(player), 9);
        player.Activate();
    }
    private void Reopen()
    {
        if (controller?.Preferences.Value is { ShowTaskbarIcon: false, ShowTrayIcon: false }) OpenSettings();
        else ShowPlayer();
    }
    private void ShowMiniPlayer() { player?.RequestMiniPlayer(); ShowPlayer(); }
    private void OpenSettings()
    {
        if (controller == null) return;
        panel?.HidePanel();
        if (settings == null)
        {
            settings = new SettingsWindow(controller);
            settings.Closed += (_, _) => settings = null;
        }
        settings.Activate();
    }
    private void TogglePanel()
    {
        if (controller == null) return;
        panel ??= new TrayWindow(controller, ShowMiniPlayer, OpenSettings, () => _ = QuitAsync(), () => tray?.Bounds);
        panel.Toggle();
    }
    private async Task QuitAsync()
    {
        if (quitting) return; quitting = true;
        panel?.HidePanel(); media?.Dispose(); tray?.Dispose();
        if (controller != null) await controller.DisposeAsync();
        settings?.Close(); panel?.Close();
        if (player != null) { player.AllowClose = true; player.Close(); }
        instance?.Dispose(); Exit();
    }
}
