using System.Diagnostics;
using System.Globalization;
using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Path = System.IO.Path;

namespace FusionPlay.Windows;

internal sealed class SettingsWindow : Window
{
    private readonly ReceiverController model;
    private readonly List<Action> labels = [];
    private readonly NavigationView navigation = new() { PaneDisplayMode = NavigationViewPaneDisplayMode.Top, IsSettingsVisible = false, IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed };
    private readonly Dictionary<string, ScrollViewer> pages = [];
    private readonly TextBox name = new() { MaxLength = 128, PlaceholderText = "FusionPlay-Windows" };
    private readonly ComboBox network = new() { DisplayMemberPath = "Label", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox output = new() { DisplayMemberPath = "Label", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly Button save = new(), receiving = new();
    private readonly TextBlock diagnostics = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono"), FontSize = 12 };
    private readonly TextBlock artwork = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar error = new() { Severity = InfoBarSeverity.Error, IsClosable = false, Margin = new Thickness(24, 0, 24, 8) };
    private readonly Slider offset = new() { Minimum = -500, Maximum = 500, StepFrequency = 1, TickFrequency = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox offsetInput = new() { Width = 96, Text = "0", TextAlignment = TextAlignment.Center, InputScope = new InputScope { Names = { new InputScopeName { NameValue = InputScopeNameValue.Number } } } };
    private readonly Button earlier = new() { Content = "−10" }, later = new() { Content = "+10" }, reset = new();
    private readonly TextBlock calibrationOutput = new() { FontSize = 12, Opacity = 0.65, TextWrapping = TextWrapping.Wrap };
    private readonly ComboBox language = new() { DisplayMemberPath = "Label", ItemsSource = new[] { new Choice("zh-Hans", "简体中文"), new Choice("en", "English") } };
    private ToggleSwitch transport = null!, always = null!, pinned = null!, pinButton = null!, taskbar = null!, tray = null!;
    private OutputCalibration? calibration;
    private bool renderingCalibration, changingCalibration, renderingPreferences, renderingDevices, closed;
    private bool numericEditing, sliderDragging, draftDirty, syncButtonPointerDown;
    private int calibrationRefreshVersion, deferredCommitVersion;
    private string localError = "";
    private sealed record Choice(string Key, string Label);

    public SettingsWindow(ReceiverController controller)
    {
        model = controller;
        var root = new Grid { Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"] };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var heading = new TextBlock { FontSize = 26, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(28, 22, 28, 12) };
        Label(() => { Title = L.Text("FusionPlay 设置"); heading.Text = L.Text("设置"); });
        root.Children.Add(heading); Grid.SetRow(error, 1); root.Children.Add(error);
        Grid.SetRow(navigation, 2); root.Children.Add(navigation); Content = root;
        AddPage("receiver", "接收", ReceiverPage());
        AddPage("appearance", "外观", AppearancePage());
        AddPage("advanced", "高级", AdvancedPage());
        AddPage("about", "关于", AboutPage());
        navigation.SelectionChanged += (_, _) =>
        {
            if (navigation.SelectedItem is NavigationViewItem { Tag: string key }) navigation.Content = pages[key];
        };
        navigation.SelectedItem = navigation.MenuItems[0];
        WindowSizing.Apply(this, 650, 730, 500, 500);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        name.Text = model.Settings.Name;
        output.SelectionChanged += (_, _) => { if (!renderingDevices) Render(); };
        model.DevicesChanged += DevicesChanged; model.Changed += Render;
        model.Preferences.Changed += PreferencesChanged; L.Changed += Localize;
        Closed += (_, _) =>
        {
            closed = true; model.DevicesChanged -= DevicesChanged; model.Changed -= Render;
            model.Preferences.Changed -= PreferencesChanged; L.Changed -= Localize;
        };
        RenderDevices(); RenderPreferences(); Render();
        _ = RefreshCalibrationAsync();
    }

    private void Label(Action update) { labels.Add(update); update(); }
    private void Localize()
    {
        if (closed) return;
        foreach (var update in labels) update();
        RenderDevices(); Render();
    }
    private TextBlock Text(string text, bool subdued = false)
    {
        var result = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = subdued ? 12 : 14, Opacity = subdued ? 0.68 : 1 };
        Label(() => result.Text = L.Text(text)); return result;
    }
    private Button Button(string text, Action action)
    {
        var button = new Button { HorizontalAlignment = HorizontalAlignment.Left };
        Label(() => button.Content = L.Text(text)); button.Click += (_, _) => action(); return button;
    }
    private ToggleSwitch Toggle(string text, Func<UiPreferences, bool, UiPreferences> change)
    {
        var toggle = new ToggleSwitch(); Label(() => { toggle.Header = L.Text(text); toggle.OnContent = L.Text("已开启"); toggle.OffContent = L.Text("已关闭"); });
        toggle.Toggled += (_, _) => { if (!renderingPreferences) UpdatePreferences(p => change(p, toggle.IsOn)); };
        return toggle;
    }
    private static StackPanel Panel() => new() { Spacing = 18, Padding = new Thickness(28, 20, 28, 28), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Stretch };
    private void AddPage(string key, string label, StackPanel content)
    {
        var item = new NavigationViewItem { Tag = key };
        Label(() => item.Content = L.Text(label)); navigation.MenuItems.Add(item);
        pages[key] = new ScrollViewer { Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private StackPanel ReceiverPage()
    {
        var page = Panel();
        Label(() => { name.Header = L.Text("设备名称"); network.Header = L.Text("网络接口"); output.Header = L.Text("声音输出"); });
        page.Children.Add(name); page.Children.Add(network); page.Children.Add(output);
        page.Children.Add(Text("保存后会重新连接，手机可能需要重新选择此设备。全屋播放请在手机中添加此电脑。", true));
        save.Click += Save;
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        receiving.Click += async (_, _) => { localError = ""; if (model.WantsReceiving) await model.StopAsync(); else await model.StartAsync(); };
        actions.Children.Add(save); actions.Children.Add(receiving); page.Children.Add(actions);
        return page;
    }

    private StackPanel AppearancePage()
    {
        var page = Panel(); Label(() => language.Header = L.Text("界面语言")); page.Children.Add(language);
        language.SelectionChanged += (_, _) =>
        {
            if (!renderingPreferences && language.SelectedItem is Choice choice) UpdatePreferences(p => p with { Language = choice.Key });
        };
        page.Children.Add(Text("迷你播放器"));
        always = Toggle("控件常驻", (p, value) => p with { AlwaysShowControls = value }); page.Children.Add(always);
        page.Children.Add(Text("鼠标移出后仍显示歌曲信息、进度和已开启的控件。", true));
        transport = Toggle("显示播放控制", (p, value) => p with { ShowTransport = value }); page.Children.Add(transport);
        page.Children.Add(Text("显示上一首、播放/暂停和下一首按钮。", true));
        pinned = Toggle("窗口置顶", (p, value) => p with { Pinned = value }); page.Children.Add(pinned);
        pinButton = Toggle("显示置顶按钮", (p, value) => p with { ShowPinButton = value }); page.Children.Add(pinButton);
        page.Children.Add(Text("应用入口"));
        taskbar = Toggle("显示任务栏图标", (p, value) => p with { ShowTaskbarIcon = value }); page.Children.Add(taskbar);
        tray = Toggle("显示托盘图标", (p, value) => p with { ShowTrayIcon = value }); page.Children.Add(tray);
        page.Children.Add(Text("两个入口都隐藏时，再次打开程序可进入设置。", true));
        return page;
    }

    private StackPanel AdvancedPage()
    {
        var page = Panel(); page.Children.Add(Text("声音同步校准"));
        Label(() => { AutomationProperties.SetName(offset, L.Text("播放时间偏移")); AutomationProperties.SetName(offsetInput, L.Text("播放时间偏移（ms）")); ToolTipService.SetToolTip(earlier, L.Text("提前 10 ms")); ToolTipService.SetToolTip(later, L.Text("延后 10 ms")); reset.Content = L.Text("恢复默认"); });
        var syncRow = new Grid { ColumnSpacing = 10 };
        syncRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        syncRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        syncRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        syncRow.Children.Add(earlier); Grid.SetColumn(offset, 1); syncRow.Children.Add(offset); Grid.SetColumn(later, 2); syncRow.Children.Add(later);
        page.Children.Add(syncRow);
        var entry = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        entry.Children.Add(offsetInput); entry.Children.Add(new TextBlock { Text = "ms", VerticalAlignment = VerticalAlignment.Center }); entry.Children.Add(reset); page.Children.Add(entry);
        page.Children.Add(calibrationOutput);
        page.Children.Add(Text("负值提前，正值延后。松开滑块或输入整数后回车保存。", true));
        page.Children.Add(Text("提前需要已接收音频；调整时会短暂淡出并重新对齐。每个声音输出单独保存。", true));
        offset.ValueChanged += (_, args) =>
        {
            if (!renderingCalibration) { draftDirty = true; offsetInput.Text = ((int)Math.Round(args.NewValue)).ToString(CultureInfo.InvariantCulture); }
        };
        offset.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => { sliderDragging = true; ++deferredCommitVersion; }), true);
        offset.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => { sliderDragging = false; _ = ChangeCalibrationAsync(offset.Value); }), true);
        offset.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler((_, _) => { sliderDragging = false; _ = ChangeCalibrationAsync(offset.Value); }), true);
        offset.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler((_, args) =>
        {
            if (args.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End or VirtualKey.PageDown or VirtualKey.PageUp) _ = ChangeCalibrationAsync(offset.Value);
        }), true);
        offset.LostFocus += (_, _) => QueueBlurCommit();
        offsetInput.GotFocus += (_, _) => { numericEditing = true; ++deferredCommitVersion; };
        offsetInput.TextChanged += (_, _) => { if (!renderingCalibration) { draftDirty = true; Render(); } };
        offsetInput.KeyDown += (_, args) => { if (args.Key == VirtualKey.Enter) { args.Handled = true; _ = CommitOffsetInputAsync(); } };
        offsetInput.LostFocus += (_, _) => { numericEditing = false; QueueBlurCommit(); };
        foreach (var button in new[] { earlier, later, reset })
        {
            // Focus changes on mouse-down; suppress that blur save until this button's click.
            button.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => { syncButtonPointerDown = true; ++deferredCommitVersion; }), true);
            button.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => { syncButtonPointerDown = false; QueueBlurCommit(); }), true);
            button.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler((_, _) => { syncButtonPointerDown = false; QueueBlurCommit(); }), true);
            button.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler((_, _) => { syncButtonPointerDown = false; QueueBlurCommit(); }), true);
        }
        earlier.Click += async (_, _) => await AdjustOffsetAsync(-10);
        later.Click += async (_, _) => await AdjustOffsetAsync(10);
        reset.Click += async (_, _) => { ++deferredCommitVersion; syncButtonPointerDown = false; await ChangeCalibrationAsync(0); };
        var diagnosticPanel = new StackPanel { Spacing = 14, Padding = new Thickness(0, 10, 0, 8) };
        diagnosticPanel.Children.Add(diagnostics); diagnosticPanel.Children.Add(artwork);
        diagnosticPanel.Children.Add(Button("重新加载封面", model.ReloadArtwork));
        diagnosticPanel.Children.Add(Button("打开日志目录", model.OpenLogs));
        diagnosticPanel.Children.Add(Button("允许局域网连接…", () => ConfigureFirewall()));
        var disclosure = new Expander { Content = diagnosticPanel, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        Label(() => disclosure.Header = L.Text("连接与同步诊断")); page.Children.Add(disclosure);
        return page;
    }

    private StackPanel AboutPage()
    {
        var page = Panel();
        var icon = new Canvas { Width = 100, Height = 100 };
        icon.Children.Add(new Rectangle { Width = 100, Height = 100, RadiusX = 23, RadiusY = 23, Fill = new SolidColorBrush(Colors.WhiteSmoke) });
        foreach (var x in new double[] { 15, 35 })
        {
            var ring = new Ellipse { Width = 49, Height = 49, StrokeThickness = 5, Stroke = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 30, 111, 255)) };
            Canvas.SetLeft(ring, x); Canvas.SetTop(ring, 25); icon.Children.Add(ring);
        }
        page.Children.Add(icon);
        page.Children.Add(new TextBlock { Text = "FusionPlay Windows", FontSize = 26, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        page.Children.Add(Text("Windows 妙播接收器"));
        page.Children.Add(new TextBlock { Text = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "0.1.0", Opacity = 0.65 });
        page.Children.Add(Text("便携版 · 数据保存在程序旁的 FusionPlayData", true));
        page.Children.Add(Text("关闭窗口后继续接收音乐。再次打开程序可返回播放窗口。", true));
        page.Children.Add(Button("项目主页", () => Open("https://github.com/ZrimYoung/FusionPlay")));
        page.Children.Add(Text("开源许可：AGPL-3.0-only"));
        page.Children.Add(Button("查看许可证", () => Open(Path.Combine(AppContext.BaseDirectory, "LICENSE"))));
        return page;
    }
    private void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception) { localError = L.Text("操作未完成，请重试或打开日志检查。"); Render(); }
    }
    private void UpdatePreferences(Func<UiPreferences, UiPreferences> update)
    {
        try { localError = ""; model.Preferences.Update(update(model.Preferences.Value)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            localError = L.Text("界面设置保存失败，请检查程序旁的数据目录是否可写。"); RenderPreferences();
        }
        Render();
    }
    private void PreferencesChanged() { RenderPreferences(); Render(); }
    private void RenderPreferences()
    {
        if (closed) return;
        renderingPreferences = true;
        try
        {
            var preferences = model.Preferences.Value;
            language.SelectedItem = ((Choice[])language.ItemsSource).First(x => x.Key == preferences.Language);
            transport.IsOn = preferences.ShowTransport; always.IsOn = preferences.AlwaysShowControls;
            pinned.IsOn = preferences.Pinned; pinButton.IsOn = preferences.ShowPinButton;
            taskbar.IsOn = preferences.ShowTaskbarIcon; tray.IsOn = preferences.ShowTrayIcon;
        }
        finally { renderingPreferences = false; }
    }

    private void RenderDevices()
    {
        renderingDevices = true;
        try
        {
            string networkValue = (network.SelectedItem as Choice)?.Key ?? model.Settings.InterfaceName;
            string outputValue = (output.SelectedItem as Choice)?.Key ?? model.Settings.OutputDevice;
            var networks = new List<Choice> { new("", L.Text("自动选择局域网")) };
            networks.AddRange(model.Networks.Select(item => new Choice(item.Name, $"{item.Name} · {item.Address}")));
            if (networkValue.Length > 0 && !networks.Any(x => x.Key == networkValue)) networks.Add(new(networkValue, networkValue + " · " + L.Text("不可用")));
            network.ItemsSource = networks; network.SelectedItem = networks.First(x => x.Key == networkValue);
            var outputs = new List<Choice> { new("", L.Text("跟随系统输出")) };
            outputs.AddRange(model.Outputs.Select(item => new Choice(item.Id, item.Name + (item.IsDefault ? " · " + L.Text("系统默认") : ""))));
            if (outputValue.Length > 0 && !outputs.Any(x => x.Key == outputValue)) outputs.Add(new(outputValue, L.Text("所选设备已断开")));
            output.ItemsSource = outputs; output.SelectedItem = outputs.First(x => x.Key == outputValue);
        }
        finally { renderingDevices = false; }
    }
    private void Render()
    {
        if (closed) return;
        save.IsEnabled = receiving.IsEnabled = model.Initialized && !model.Busy;
        bool savedOutput = (output.SelectedItem as Choice)?.Key == model.Settings.OutputDevice;
        bool adjust = model.Initialized && !model.Busy && !model.CalibrationBusy && !changingCalibration && calibration?.OutputDeviceId.Length > 0 && savedOutput;
        offset.IsEnabled = offsetInput.IsEnabled = adjust;
        bool validDraft = TryParseOffset(out int draft);
        earlier.IsEnabled = adjust && validDraft && draft > -500; later.IsEnabled = adjust && validDraft && draft < 500;
        reset.IsEnabled = adjust && (draftDirty || validDraft && draft != 0);
        calibrationOutput.Text = !savedOutput ? L.Text("请先保存声音输出设置。") : L.Text("当前输出：") + (model.Outputs.FirstOrDefault(item => item.Id == calibration?.OutputDeviceId)?.Name ?? L.Text("尚无可用声音输出"));
        save.Content = L.Text(model.WantsReceiving ? "保存并重新连接" : "保存并启动接收");
        receiving.Content = L.Text(model.WantsReceiving ? "停止接收" : "启动接收");
        var state = model.State;
        diagnostics.Text = $"{L.Text("状态")}    {L.Text(state.PhaseLabel)}\n{L.Text("输出设备")}    {(state.Output.Length > 0 ? state.Output : L.Text("尚未输出"))}\n{L.Text("音频缓冲")}    {state.QueueMs:F1} ms\n{L.Text("设备输出延迟")}    {state.OutputLatencyMs:F1} ms\n{L.Text("调度误差")}    {state.ScheduleErrorMs:F1} ms\n{L.Text("欠载 / 丢帧")} {state.Underruns} / {state.DroppedFrames}\n{L.Text("重新同步")}    {state.Resyncs}\n\n{L.Text("调度误差不代表实际声学同步偏差。")}";
        artwork.Text = L.Text("专辑封面") + ": " + L.Text(model.ArtworkStatus);
        error.Message = localError.Length > 0 ? localError : L.Text(model.Error); error.IsOpen = error.Message.Length > 0;
    }
    private async void Save(object sender, RoutedEventArgs args)
    {
        localError = "";
        string receiverName = name.Text.Trim();
        if (receiverName.Length == 0 || receiverName.EnumerateRunes().Count() > 64) { localError = L.Text("设备名称需包含 1–64 个字符。"); Render(); return; }
        await model.StartAsync(new ReceiverSettings(receiverName, (network.SelectedItem as Choice)?.Key ?? "", (output.SelectedItem as Choice)?.Key ?? "", (uint)Math.Round(model.Volume)));
        await RefreshCalibrationAsync(force: true);
    }
    private async Task RefreshCalibrationAsync(bool force = false)
    {
        if (!model.Initialized || closed) return;
        int request = ++calibrationRefreshVersion;
        try
        {
            var current = await model.GetCalibrationAsync();
            if (closed || request != calibrationRefreshVersion) return;
            bool sameOutput = calibration?.OutputDeviceId == current.OutputDeviceId;
            calibration = current;
            if (force || !sameOutput || !draftDirty && !numericEditing && !sliderDragging)
            {
                ++deferredCommitVersion;
                SetOffsetDraft(current.OffsetMs);
            }
            Render();
        }
        catch (Exception e) { if (!closed) { localError = e is ReceiverException ? e.Message : L.Text("无法读取当前输出的校准设置。"); Render(); } }
    }
    private void SetOffsetDraft(int value)
    {
        renderingCalibration = true;
        try { offset.Value = value; offsetInput.Text = value.ToString(CultureInfo.InvariantCulture); draftDirty = false; }
        finally { renderingCalibration = false; }
    }
    private void DevicesChanged() { RenderDevices(); _ = RefreshCalibrationAsync(); }
    private bool TryParseOffset(out int value) => int.TryParse(offsetInput.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out value) && value is >= -500 and <= 500;
    private void QueueBlurCommit()
    {
        if (closed || renderingCalibration || changingCalibration || !draftDirty) return;
        int request = ++deferredCommitVersion;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (request == deferredCommitVersion && !closed && !numericEditing && !sliderDragging && !syncButtonPointerDown) _ = CommitOffsetInputAsync();
        });
    }
    private async Task AdjustOffsetAsync(int delta)
    {
        ++deferredCommitVersion; syncButtonPointerDown = false;
        if (!TryParseOffset(out int value)) { localError = L.Text("请输入 −500 到 500 之间的整数。"); Render(); return; }
        await ChangeCalibrationAsync(Math.Clamp(value + delta, -500, 500));
    }
    private async Task CommitOffsetInputAsync()
    {
        ++deferredCommitVersion;
        if (closed || renderingCalibration || changingCalibration || !offsetInput.IsEnabled) return;
        if (!TryParseOffset(out int value))
        {
            localError = L.Text("请输入 −500 到 500 之间的整数。"); Render(); return;
        }
        await ChangeCalibrationAsync(value);
    }
    private async Task ChangeCalibrationAsync(double value)
    {
        if (closed || changingCalibration || renderingCalibration || calibration == null || !double.IsFinite(value) || model.Busy || model.CalibrationBusy || !offset.IsEnabled) return;
        int requested = (int)Math.Clamp(Math.Round(value), -500, 500);
        localError = "";
        if (requested == calibration.OffsetMs) { SetOffsetDraft(requested); Render(); return; }
        changingCalibration = true; Render();
        try { await model.ApplyCalibrationAsync(calibration with { OffsetMs = requested }); await RefreshCalibrationAsync(force: true); }
        finally { changingCalibration = false; Render(); }
    }
    private async void ConfigureFirewall()
    {
        var dialog = new ContentDialog
        {
            XamlRoot = ((FrameworkElement)Content).XamlRoot, Title = L.Text("允许局域网投放"),
            Content = L.Text("仅为当前程序路径添加专用网络、本地子网的入站规则。Windows 将请求管理员权限；程序本身仍以普通用户运行。"),
            PrimaryButtonText = L.Text("配置规则"), CloseButtonText = L.Text("取消"), DefaultButton = ContentDialogButton.Close
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        try
        {
            string script = Path.Combine(AppContext.BaseDirectory, "Configure-Firewall.ps1");
            var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
            foreach (string argument in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-ProgramPath", Environment.ProcessPath! }) start.ArgumentList.Add(argument);
            Process.Start(start);
        }
        catch (Exception) { localError = L.Text("防火墙配置未完成，可稍后重试。"); Render(); }
    }
}
