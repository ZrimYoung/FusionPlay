using System.Diagnostics;
using FusionPlay.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using FusionPlay.Windows.Platform;

namespace FusionPlay.Windows;

internal sealed class SettingsWindow : Window
{
    private readonly ReceiverController model;
    private readonly TextBox name = new() { Header = "设备名称", MaxLength = 128, PlaceholderText = "FusionPlay-Windows" };
    private readonly ComboBox network = new() { Header = "网络接口", DisplayMemberPath = "DisplayName", SelectedValuePath = "Name", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox output = new() { Header = "声音输出", DisplayMemberPath = "DisplayName", SelectedValuePath = "Id", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly Button save = new() { Content = "保存并重新连接", HorizontalAlignment = HorizontalAlignment.Left };
    private readonly TextBlock diagnostics = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono"), FontSize = 12 };
    private readonly TextBlock artwork = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar error = new() { Severity = InfoBarSeverity.Error, IsClosable = false };
    private readonly NumberBox advance = new() { Header = "声音同步校准（提前毫秒）", Minimum = 0, Maximum = 500, SmallChange = 1, LargeChange = 10, Value = 0, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    private readonly Button decreaseAdvance = new() { Content = "−10" };
    private readonly Button increaseAdvance = new() { Content = "+10" };
    private readonly Button resetAdvance = new() { Content = "归零" };
    private readonly TextBlock calibrationOutput = new() { FontSize = 12, Opacity = 0.65, TextWrapping = TextWrapping.Wrap };
    private OutputCalibration? calibration;
    private bool renderingCalibration, changingCalibration, closed;
    private int calibrationRefreshVersion;
    private readonly StackPanel root = new() { Padding = new Thickness(28), Spacing = 18, MaxWidth = 700 };
    public SettingsWindow(ReceiverController controller)
    {
        model = controller; Title = "FusionPlay 设置";
        root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        root.Children.Add(new TextBlock { Text = "设置", FontSize = 26, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        root.Children.Add(name); root.Children.Add(network); root.Children.Add(output);
        root.Children.Add(new TextBlock { Text = "保存后会重新连接，手机可能需要重新选择此设备。全屋播放请在手机中添加此电脑。", TextWrapping = TextWrapping.Wrap, Opacity = 0.65, FontSize = 12 });
        save.Click += Save; root.Children.Add(save); root.Children.Add(error);
        var sync = new StackPanel { Spacing = 10 };
        sync.Children.Add(advance); sync.Children.Add(calibrationOutput);
        sync.Children.Add(new TextBlock { Text = "电脑比同组音箱慢时增加。调整会短暂淡出再恢复，立即生效并自动保存。", TextWrapping = TextWrapping.Wrap, Opacity = 0.7, FontSize = 12 });
        var syncActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        syncActions.Children.Add(decreaseAdvance); syncActions.Children.Add(increaseAdvance); syncActions.Children.Add(resetAdvance); sync.Children.Add(syncActions);
        decreaseAdvance.Click += async (_, _) => await ChangeCalibrationAsync(advance.Value - 10);
        increaseAdvance.Click += async (_, _) => await ChangeCalibrationAsync(advance.Value + 10);
        resetAdvance.Click += async (_, _) => await ChangeCalibrationAsync(0);
        advance.ValueChanged += async (_, _) => { if (!renderingCalibration) await ChangeCalibrationAsync(advance.Value); };
        root.Children.Add(new Border { Child = sync, Padding = new Thickness(16), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"] });
        var advanced = new StackPanel { Spacing = 12, Padding = new Thickness(0, 8, 0, 4) };
        advanced.Children.Add(diagnostics); advanced.Children.Add(artwork);
        var reload = new Button { Content = "重新加载封面" }; reload.Click += (_, _) => model.ReloadArtwork(); advanced.Children.Add(reload);
        var logs = new Button { Content = "打开日志目录" }; logs.Click += (_, _) => model.OpenLogs(); advanced.Children.Add(logs);
        var firewall = new Button { Content = "允许局域网连接…" }; firewall.Click += ConfigureFirewall; advanced.Children.Add(firewall);
        root.Children.Add(new Expander { Header = "连接与同步诊断", Content = advanced, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
        root.Children.Add(new TextBlock { Text = "FusionPlay Windows · 0.1.0 测试版\n关闭窗口后继续在托盘接收音乐。", TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.6 });
        Content = new ScrollViewer { Content = root, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollMode = ScrollMode.Enabled };
        WindowSizing.Apply(this, 530, 680, 440, 460); AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        name.Text = model.Settings.Name; RenderDevices(); Render();
        output.SelectionChanged += (_, _) => Render();
        model.DevicesChanged += DevicesChanged; model.Changed += Render;
        Closed += (_, _) => { closed = true; model.DevicesChanged -= DevicesChanged; model.Changed -= Render; };
        _ = RefreshCalibrationAsync();
    }
    private void RenderDevices()
    {
        string networkValue = (network.SelectedItem as NetworkInterface)?.Name ?? model.Settings.InterfaceName;
        string outputValue = (output.SelectedItem as AudioDevice)?.Id ?? model.Settings.OutputDevice;
        var networks = new List<NetworkInterface> { new("", "") }; networks.AddRange(model.Networks);
        if (networkValue.Length > 0 && !networks.Any(x => x.Name == networkValue)) networks.Add(new(networkValue, "不可用"));
        network.ItemsSource = networks; network.SelectedItem = networks.First(x => x.Name == networkValue);
        var outputs = new List<AudioDevice> { new("", "跟随系统输出", true) }; outputs.AddRange(model.Outputs);
        if (outputValue.Length > 0 && !outputs.Any(x => x.Id == outputValue)) outputs.Add(new(outputValue, "所选设备已断开", false));
        output.ItemsSource = outputs; output.SelectedItem = outputs.First(x => x.Id == outputValue);
    }
    private void Render()
    {
        if (closed) return;
        save.IsEnabled = model.Initialized && !model.Busy;
        bool savedOutput = (output.SelectedItem as AudioDevice)?.Id == model.Settings.OutputDevice;
        bool adjust = model.Initialized && !model.Busy && !model.CalibrationBusy && !changingCalibration && calibration?.OutputDeviceId.Length > 0 && savedOutput;
        advance.IsEnabled = adjust;
        decreaseAdvance.IsEnabled = resetAdvance.IsEnabled = adjust && advance.Value > 0;
        increaseAdvance.IsEnabled = adjust && advance.Value < 500;
        calibrationOutput.Text = !savedOutput ? "请先保存声音输出设置。" : "当前输出：" + (model.Outputs.FirstOrDefault(o => o.Id == calibration?.OutputDeviceId)?.Name ?? "尚无可用声音输出");
        save.Content = model.WantsReceiving ? "保存并重新连接" : "保存并启动接收";
        var state = model.State;
        diagnostics.Text = $"接收状态    {state.PhaseLabel}\n输出设备    {(state.Output.Length > 0 ? state.Output : "尚未输出")}\n音频缓冲    {state.QueueMs:F1} ms\n输出延迟    {state.OutputLatencyMs:F1} ms\n调度误差    {state.ScheduleErrorMs:F1} ms\n欠载 / 丢帧 {state.Underruns} / {state.DroppedFrames}\n重新同步    {state.Resyncs}\n\n调度误差不代表实际声学同步偏差。";
        artwork.Text = "专辑封面：" + model.ArtworkStatus;
        error.Message = model.Error; error.IsOpen = model.Error.Length > 0;
    }
    private async void Save(object sender, RoutedEventArgs args)
    {
        string receiverName = name.Text.Trim();
        if (receiverName.Length == 0 || receiverName.EnumerateRunes().Count() > 64)
        {
            error.Message = "设备名称需包含 1–64 个字符。"; error.IsOpen = true; return;
        }
        await model.StartAsync(new ReceiverSettings(receiverName, (network.SelectedItem as NetworkInterface)?.Name ?? "", (output.SelectedItem as AudioDevice)?.Id ?? "", (uint)Math.Round(model.Volume)));
        await RefreshCalibrationAsync();
    }
    private async Task RefreshCalibrationAsync()
    {
        if (!model.Initialized || closed) return;
        int request = ++calibrationRefreshVersion;
        try
        {
            var current = await model.GetCalibrationAsync();
            if (closed || request != calibrationRefreshVersion) return;
            calibration = current;
            renderingCalibration = true;
            try { advance.Value = current.AdvanceMs; } finally { renderingCalibration = false; }
            Render();
        }
        catch (Exception e) { if (!closed) { error.Message = e is ReceiverException ? e.Message : "无法读取当前输出的校准设置。"; error.IsOpen = true; } }
    }
    private void DevicesChanged() { RenderDevices(); _ = RefreshCalibrationAsync(); }
    private async Task ChangeCalibrationAsync(double value)
    {
        if (closed || changingCalibration || calibration == null || !double.IsFinite(value) || model.Busy || model.CalibrationBusy) return;
        uint requested = (uint)Math.Clamp(Math.Round(value), 0, 500);
        if (requested == calibration.AdvanceMs) return;
        changingCalibration = true; Render();
        try
        {
            await model.ApplyCalibrationAsync(calibration with { AdvanceMs = requested });
            await RefreshCalibrationAsync();
        }
        finally { changingCalibration = false; Render(); }
    }
    private async void ConfigureFirewall(object sender, RoutedEventArgs args)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root.XamlRoot, Title = "允许局域网投放",
            Content = "仅为当前程序路径添加专用网络、本地子网的入站规则。Windows 将请求管理员权限；程序本身仍以普通用户运行。",
            PrimaryButtonText = "配置规则", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            string script = Path.Combine(AppContext.BaseDirectory, "Configure-Firewall.ps1");
            var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
            foreach (string argument in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-ProgramPath", Environment.ProcessPath! }) start.ArgumentList.Add(argument);
            Process.Start(start);
        }
        catch (Exception) { error.Message = "防火墙配置未完成，可稍后重试。"; error.IsOpen = true; }
    }
}
