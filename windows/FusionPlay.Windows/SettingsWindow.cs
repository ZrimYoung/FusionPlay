using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Runtime.InteropServices;
using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;
using Path = System.IO.Path;
using UISettings = Windows.UI.ViewManagement.UISettings;
using AccessibilitySettings = Windows.UI.ViewManagement.AccessibilitySettings;

namespace FusionPlay.Windows;

internal sealed class SettingsWindow : Window
{
    private readonly ReceiverController model;
    private readonly List<Action> labels = [];
    private readonly Grid titleBar = (Grid)XamlReader.Load("""<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Name="SettingsTitleBar" MinHeight="32" Background="{ThemeResource ApplicationPageBackgroundThemeBrush}"/>""");
    private readonly TextBlock titleBarText = (TextBlock)XamlReader.Load("""<TextBlock xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Name="SettingsWindowTitle" FontSize="13" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Foreground="{ThemeResource TextFillColorPrimaryBrush}"/>""");
    private readonly UISettings captionSettings = new();
    private readonly AccessibilitySettings accessibility = new();
    private readonly HashSet<FrameworkElement> pendingTypography = [];
    private bool captionUpdateQueued;
    private readonly SettingsNavigationMotion navigationMotion;
    private readonly Brush clearMaterial = new SolidColorBrush(Colors.Transparent);
    private Brush? appliedSurface;
    private readonly NavigationView navigation = new()
    {
        Name = "SettingsNavigation", PaneDisplayMode = NavigationViewPaneDisplayMode.Auto,
        OpenPaneLength = 190, CompactPaneLength = 48, ExpandedModeThresholdWidth = 800, CompactModeThresholdWidth = 640,
        IsSettingsVisible = false, IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
        IsTitleBarAutoPaddingEnabled = false
    };
    private readonly Dictionary<string, ScrollViewer> pages = [];
    private readonly TextBox name = new() { Name = "ReceiverName", MaxLength = 128, PlaceholderText = "FusionPlay-Windows" };
    private readonly ComboBox network = new() { Name = "NetworkInterface", DisplayMemberPath = "Label", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox output = new() { Name = "AudioOutput", DisplayMemberPath = "Label", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly Button save = new() { Name = "ApplyReceiver" }, applyOutput = new() { Name = "ApplyOutput" }, receiving = new() { Name = "ReceivingToggle" };
    private readonly TextBlock receiverStatus = new() { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock outputStatus = new() { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar receiverError = ErrorBar("ReceiverError"), audioError = ErrorBar("AudioError"), playerError = ErrorBar("PlayerPreferenceError"), generalError = ErrorBar("GeneralPreferenceError"), aboutError = ErrorBar("AboutError");
    private readonly TextBlock diagnostics = new() { Name = "ReceiverDiagnostics", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono"), FontSize = 12 };
    private readonly TextBlock artwork = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Slider offset = new() { Name = "CalibrationRange", Minimum = -500, Maximum = 500, StepFrequency = 1, TickFrequency = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox offsetInput = new()
    {
        Name = "CalibrationValue", Width = 96, Text = "0", TextAlignment = TextAlignment.Center,
        InputScope = new InputScope { Names = { new InputScopeName { NameValue = InputScopeNameValue.Number } } }
    };
    private readonly Button earlier = new() { Name = "CalibrationEarlier", Content = "−", Width = 34, Height = 34, Padding = new Thickness(0), FontSize = 22 },
        later = new() { Name = "CalibrationLater", Content = "+", Width = 34, Height = 34, Padding = new Thickness(0), FontSize = 22 },
        reset = new() { Name = "CalibrationReset", HorizontalAlignment = HorizontalAlignment.Right };
    private readonly TextBlock calibrationOutput = new() { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    private readonly SelectorBar language = new() { Name = "InterfaceLanguage" }, progressColorMode = new() { Name = "ProgressColorMode" }, miniVisibility = new() { Name = "MiniControlsVisibility" }, lyricsDisplayMode = new() { Name = "LyricsDisplayMode" };
    private readonly SettingsChoiceCard transport = new("\uE768") { Name = "ShowTransport" }, progress = new("\uE9E9") { Name = "ShowProgress" }, pinButton = new("\uE718") { Name = "ShowPinButton" },
        settingsButton = new("\uE713") { Name = "ShowSettingsButton" }, fullScreenButton = new("\uE740") { Name = "ShowFullScreenButton" },
        correctLyricTitles = new("\uE8D2") { Name = "CorrectLyricTitles", MaxWidth = 260, HorizontalAlignment = HorizontalAlignment.Left },
        taskbar = new("\uE737") { Name = "TaskbarEntry" }, tray = new("\uE73A") { Name = "TrayEntry" };
    private readonly ToggleButton pinned = new() { Name = "Pinned", MinWidth = 94, Padding = new Thickness(12, 7, 12, 7) };
    private FontSettingsPanel fontSettings = null!;
    private readonly TextBlock fontSummary = new() { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    private readonly ColorPicker progressColor = new()
    {
        Name = "ProgressCustomColor", IsAlphaEnabled = false, IsAlphaSliderVisible = false, IsAlphaTextInputVisible = false,
        IsHexInputVisible = true, IsColorChannelTextInputVisible = true, IsMoreButtonVisible = false,
        HorizontalAlignment = HorizontalAlignment.Left, MaxWidth = 420
    };
    private readonly StackPanel progressColorGroup = new() { Name = "ProgressColorContent", Spacing = 12 }, progressColorEditor = new() { Spacing = 12 };
    private Border progressColorSurface = null!;
    private readonly SolidColorBrush progressColorPreview = new(Colors.White);
    private readonly TextBlock progressColorValue = new() { IsTextSelectionEnabled = true, VerticalAlignment = VerticalAlignment.Center };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer progressColorSaveTimer;
    private string? pendingProgressColor;
    private OutputCalibration? calibration;
    private bool renderingCalibration, changingCalibration, loadingCalibration, renderingPreferences, renderingDevices, applyingSettings, closed;
    private bool numericEditing, sliderDragging, draftDirty, syncButtonPointerDown;
    private bool receiverRetryRequired, outputRetryRequired, receiverApplied, outputApplied;
    private int calibrationRefreshVersion, deferredCommitVersion;
    private string receiverMessage = "", audioMessage = "", preferenceMessage = "", aboutMessage = "";
    private sealed record Choice(string Key, string Label);

    public SettingsWindow(ReceiverController controller)
    {
        model = controller;
        navigationMotion = new SettingsNavigationMotion(navigation);
        progressColorSaveTimer = DispatcherQueue.CreateTimer();
        progressColorSaveTimer.IsRepeating = false; progressColorSaveTimer.Interval = TimeSpan.FromMilliseconds(300);
        progressColorSaveTimer.Tick += ProgressColorSaveTick;
        var root = (Grid)XamlReader.Load("""<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Background="{ThemeResource ApplicationPageBackgroundThemeBrush}"/>""");
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        titleBar.Children.Add(titleBarText); root.Children.Add(titleBar); Grid.SetRow(navigation, 1); root.Children.Add(navigation); Content = root;
        ExtendsContentIntoTitleBar = true; SetTitleBar(titleBar);
        try { SystemBackdrop = new MicaBackdrop(); }
        catch (Exception error) when (error is COMException or InvalidOperationException or ArgumentException or NotSupportedException) { }
        AppWindow.Changed += SettingsAppWindowChanged;
        captionSettings.ColorValuesChanged += CaptionColorChanged;
        root.ActualThemeChanged += (_, _) => QueueCaptionUpdate();
        root.SizeChanged += (_, _) => UpdateTitleBarMetrics();
        Label(() => { Title = titleBarText.Text = L.Text("FusionPlay 设置", "FusionPlay Settings"); navigation.PaneTitle = L.Text("设置", "Settings"); });
        AddPage("receiver", "接收", "Receiver", "\uE839", ReceiverPage());
        AddPage("audio", "音频", "Audio", "\uE767", AudioPage());
        AddPage("player", "播放器", "Player", "\uE714", PlayerPage());
        AddPage("general", "通用", "General", "\uE713", GeneralPage());
        AddPage("about", "关于", "About", "\uE946", AboutPage());
        navigation.SelectionChanged += (_, _) =>
        {
            if (navigation.SelectedItem is NavigationViewItem { Tag: string key })
            {
                // Reuse the same native page and editors; changing navigation
                // must not replace drafts or reset a font disclosure/scroll view.
                navigation.Content = pages[key]; QueueTypography(pages[key]);
                navigationMotion.PageChanged(pages[key], root.IsLoaded);
            }
        };
        navigation.SelectedItem = navigation.MenuItems[2];
        WindowSizing.Apply(this, 960, 740, 620, 520);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        name.Text = model.Settings.Name;
        name.TextChanged += (_, _) => { receiverApplied = false; Render(); };
        network.SelectionChanged += (_, _) => { if (!renderingDevices) { receiverApplied = false; Render(); } };
        output.SelectionChanged += (_, _) =>
        {
            if (renderingDevices) return;
            ++deferredCommitVersion; outputApplied = false; Render();
        };
        root.Loaded += (_, _) => { QueueTypography(root); QueueCaptionUpdate(); };
        model.DevicesChanged += DevicesChanged; model.Changed += Render;
        model.Preferences.Changed += PreferencesChanged; L.Changed += Localize;
        AppWindow.Closing += (_, args) =>
        {
            // Commit the native hex editor before flushing its latest valid color.
            if (progressColorEditor.Visibility == Visibility.Visible) progressColorMode.Focus(FocusState.Programmatic);
            if (!FlushProgressColor()) { args.Cancel = true; navigation.SelectedItem = navigation.MenuItems[2]; }
        };
        Closed += (_, _) =>
        {
            // Programmatic Close can bypass AppWindow.Closing during application exit.
            FlushProgressColor();
            closed = true; ++calibrationRefreshVersion; ++deferredCommitVersion;
            progressColorSaveTimer.Stop(); progressColorSaveTimer.Tick -= ProgressColorSaveTick;
            captionSettings.ColorValuesChanged -= CaptionColorChanged; AppWindow.Changed -= SettingsAppWindowChanged; pendingTypography.Clear();
            navigationMotion.Dispose(); fontSettings.Dispose();
            model.DevicesChanged -= DevicesChanged; model.Changed -= Render;
            model.Preferences.Changed -= PreferencesChanged; L.Changed -= Localize;
        };
        RenderDevices(); RenderPreferences(); Render();
        QueueCaptionUpdate();
        _ = RefreshCalibrationAsync();
    }

    private static InfoBar ErrorBar(string name) => new() { Name = name, Severity = InfoBarSeverity.Error, IsClosable = false, Visibility = Visibility.Collapsed };
    private void QueueTypography(FrameworkElement subtree)
    {
        if (closed) return;
        UiTypography.Apply(subtree, model.Preferences.Value);
        if (!pendingTypography.Add(subtree)) return;
        if (!DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            pendingTypography.Remove(subtree);
            if (closed) return;
            UiTypography.Invalidate(subtree); UiTypography.Apply(subtree, model.Preferences.Value);
        })) pendingTypography.Remove(subtree);
    }
    private void UpdateSurfaceMaterial()
    {
        Brush surface = SystemBackdrop == null || accessibility.HighContrast
            ? (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"] : clearMaterial;
        if (ReferenceEquals(appliedSurface, surface)) return;
        appliedSurface = surface;
        titleBar.Background = surface;
        if (Content is Grid root) root.Background = surface;
        navigation.Background = clearMaterial;
        // These are public NavigationView resource overrides. The one window
        // backdrop continues behind the sidebar and its client title region.
        navigation.Resources["NavigationViewDefaultPaneBackground"] = surface;
        navigation.Resources["NavigationViewExpandedPaneBackground"] = surface;
    }
    private void CaptionColorChanged(UISettings sender, object args) => QueueCaptionUpdate();
    private void SettingsAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    { if (args.DidSizeChange || args.DidPositionChange) QueueCaptionUpdate(); }
    private void QueueCaptionUpdate()
    {
        if (closed || captionUpdateQueued) return;
        captionUpdateQueued = true;
        if (!DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            captionUpdateQueued = false; if (closed) return;
            UpdateSurfaceMaterial(); UpdateTitleBarMetrics();
            if (!AppWindowTitleBar.IsCustomizationSupported()) return;
            var bar = AppWindow.TitleBar;
            var foreground = titleBarText.Foreground is SolidColorBrush text ? text.Color : titleBar.ActualTheme == ElementTheme.Dark ? Colors.White : Colors.Black;
            var background = titleBar.Background is SolidColorBrush fill ? fill.Color : titleBar.ActualTheme == ElementTheme.Dark ? Colors.Black : Colors.White;
            bool contrast = accessibility.HighContrast;
            var hoverBackground = contrast && Application.Current.Resources.TryGetValue("SystemColorHighlightColorBrush", out object highlightResource) && highlightResource is SolidColorBrush highlight ? highlight.Color
                : titleBar.ActualTheme == ElementTheme.Dark ? global::Windows.UI.Color.FromArgb(32, 255, 255, 255) : global::Windows.UI.Color.FromArgb(18, 0, 0, 0);
            var hoverForeground = contrast && Application.Current.Resources.TryGetValue("SystemColorHighlightTextColorBrush", out object highlightedResource) && highlightedResource is SolidColorBrush highlightedText ? highlightedText.Color : foreground;
            bar.BackgroundColor = bar.InactiveBackgroundColor = background;
            bar.ForegroundColor = foreground;
            bar.ButtonBackgroundColor = bar.ButtonInactiveBackgroundColor = Colors.Transparent;
            bar.ButtonForegroundColor = foreground;
            bar.ButtonInactiveForegroundColor = contrast ? foreground : global::Windows.UI.Color.FromArgb(128, foreground.R, foreground.G, foreground.B);
            bar.ButtonHoverBackgroundColor = bar.ButtonPressedBackgroundColor = hoverBackground;
            bar.ButtonHoverForegroundColor = bar.ButtonPressedForegroundColor = hoverForeground;
        })) captionUpdateQueued = false;
    }
    private void UpdateTitleBarMetrics()
    {
        if (closed) return;
        double scale = (Content as FrameworkElement)?.XamlRoot?.RasterizationScale ?? 1;
        var bar = AppWindow.TitleBar;
        titleBar.Padding = new Thickness(16 + bar.LeftInset / scale, 0, Math.Max(138, bar.RightInset / scale), 0);
        titleBar.MinHeight = Math.Max(32, bar.Height / scale);
    }
    private void Label(Action update) { labels.Add(update); update(); }
    private void Localize()
    {
        if (closed) return;
        foreach (var update in labels) update();
        RenderDevices(); RenderPreferences(); Render();
    }
    private TextBlock Text(string chinese, string english, bool subdued = false)
    {
        var result = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = subdued ? 12 : 14, Opacity = subdued ? 0.7 : 1 };
        Label(() => result.Text = L.Text(chinese, english)); return result;
    }
    private TextBlock Heading(string chinese, string english)
    {
        var result = Text(chinese, english); result.FontSize = 15; result.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; return result;
    }
    private StackPanel Page(string chinese, string english, string descriptionChinese, string descriptionEnglish)
    {
        var title = Text(chinese, english); title.FontSize = 28; title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        var heading = new StackPanel { Spacing = 5 }; heading.Children.Add(title); heading.Children.Add(Text(descriptionChinese, descriptionEnglish, true));
        var page = new StackPanel { Spacing = 20, Padding = new Thickness(28, 22, 28, 24), MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Stretch };
        page.Children.Add(heading); return page;
    }
    private StackPanel Group(string chinese, string english, params UIElement[] content)
    {
        var group = new StackPanel { Spacing = 10 }; group.Children.Add(Heading(chinese, english));
        foreach (var item in content) group.Children.Add(item); return group;
    }
    private static Border Surface(UIElement content)
    {
        var border = (Border)XamlReader.Load("""<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Padding="14" CornerRadius="8" BorderThickness="1" Background="{ThemeResource CardBackgroundFillColorDefaultBrush}" BorderBrush="{ThemeResource CardStrokeColorDefaultBrush}"/>""");
        border.Child = content; return border;
    }
    private Grid Row(FrameworkElement description, FrameworkElement control)
    {
        var row = new Grid { ColumnSpacing = 16 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        description.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(description); Grid.SetColumn(control, 1); row.Children.Add(control);
        bool? stacked = null;
        row.SizeChanged += (_, args) =>
        {
            bool narrow = args.NewSize.Width < 510; if (stacked == narrow) return; stacked = narrow;
            Grid.SetColumn(control, narrow ? 0 : 1); Grid.SetRow(control, narrow ? 1 : 0); Grid.SetColumnSpan(control, narrow ? 2 : 1);
            Grid.SetColumnSpan(description, narrow ? 2 : 1); control.HorizontalAlignment = narrow ? HorizontalAlignment.Left : HorizontalAlignment.Right;
            control.Margin = narrow ? new Thickness(0, 10, 0, 0) : new Thickness(0);
        };
        return row;
    }
    private void AddPage(string key, string chinese, string english, string glyph, StackPanel content)
    {
        content.Name = "SettingsBody_" + key;
        if (content.Children[0] is StackPanel heading)
        {
            if (heading.Children[0] is TextBlock title) title.Name = "SettingsPageTitle_" + key;
            if (heading.Children[1] is TextBlock description) description.Name = "SettingsPageDescription_" + key;
        }
        var item = new NavigationViewItem { Tag = key, Icon = new FontIcon { Glyph = glyph } };
        Label(() => item.Content = L.Text(chinese, english)); navigation.MenuItems.Add(item);
        // Keep MaxWidth on the inner page. A MaxWidth-constrained direct
        // ScrollViewer child can be centered using its smaller desired width
        // and then stretched, shifting the page outside the viewport.
        var viewport = new Grid(); viewport.Children.Add(content);
        pages[key] = new ScrollViewer
        {
            Name = "SettingsPage_" + key, Content = viewport,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        pages[key].Loaded += (_, _) => QueueTypography(pages[key]);
    }
    private void AddSegment(SelectorBar bar, string key, string chinese, string english)
    {
        var item = new SelectorBarItem { Tag = key }; Label(() => item.Text = L.Text(chinese, english)); bar.Items.Add(item);
    }
    private static string? SegmentKey(SelectorBar bar) => bar.SelectedItem?.Tag as string;
    private static void SelectSegment(SelectorBar bar, string key) => bar.SelectedItem = bar.Items.First(item => (string)item.Tag == key);
    private void ConfigureCard(SettingsChoiceCard card, string chinese, string english, Func<UiPreferences, bool, UiPreferences> update, bool activationLabels = false)
    {
        Label(() => card.SetLabels(L.Text(chinese, english), activationLabels ? L.Text("已开启", "On") : L.Text("已显示", "Shown"), activationLabels ? L.Text("已关闭", "Off") : L.Text("已隐藏", "Hidden")));
        RoutedEventHandler changed = (_, _) =>
        {
            if (renderingPreferences) return;
            // Saving a pending color can refresh the controls before the outer
            // preference is written. Keep the user's requested state stable.
            bool requested = card.IsChecked == true;
            UpdatePreferences(p => update(p, requested));
        };
        card.Checked += changed; card.Unchecked += changed;
    }
    private static Grid Cards(params SettingsChoiceCard[] cards)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        for (int index = 0; index < cards.Length; index++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); Grid.SetColumn(cards[index], index); grid.Children.Add(cards[index]);
        }
        return grid;
    }
    private Button ActionButton(string chinese, string english, Action action)
    {
        var button = new Button { HorizontalAlignment = HorizontalAlignment.Left };
        Label(() => button.Content = L.Text(chinese, english));
        button.Click += (_, _) =>
        {
            try { action(); }
            catch (Exception) { audioMessage = L.Text("操作未完成，请重试或打开日志检查。", "The action could not be completed. Retry or check the logs."); Render(); }
        };
        return button;
    }

    private StackPanel ReceiverPage()
    {
        var page = Page("接收", "Receiver", "设置手机发现这台电脑时使用的名称和网络。", "Choose the name and network used when your phone discovers this computer.");
        Label(() => { name.Header = L.Text("设备名称", "Device name"); network.Header = L.Text("网络接口", "Network interface"); });
        var fields = new StackPanel { Spacing = 14 }; fields.Children.Add(name); fields.Children.Add(network);
        fields.Children.Add(Text("全屋播放请在手机中添加此电脑。", "Add this computer to your group on your phone for multi-room playback.", true));
        page.Children.Add(Group("设备与网络", "Device & network", Surface(fields)));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 }; actions.Children.Add(save); actions.Children.Add(receiving);
        page.Children.Add(actions); page.Children.Add(receiverStatus); page.Children.Add(receiverError);
        page.Children.Add(Text("应用后会重新连接，手机可能需要重新选择此设备。未应用的更改不会被“启动接收”使用。", "Applying reconnects the receiver; you may need to select it again on your phone. Starting the receiver uses the applied settings.", true));
        save.Click += async (_, _) => await ApplyReceiverAsync();
        receiving.Click += async (_, _) => await ToggleReceivingAsync();
        return page;
    }
    private StackPanel AudioPage()
    {
        var page = Page("音频", "Audio", "声音输出与同步校准放在一起，按输出设备分别保存。", "Choose an audio output and save sync calibration separately for each device.");
        Label(() => AutomationProperties.SetName(output, L.Text("声音输出", "Audio output")));
        var outputFields = new StackPanel { Spacing = 12 }; outputFields.Children.Add(output); outputFields.Children.Add(applyOutput); outputFields.Children.Add(outputStatus);
        page.Children.Add(Group("声音输出", "Audio output", Surface(outputFields)));
        applyOutput.Click += async (_, _) => await ApplyOutputAsync();
        var calibrationPanel = new StackPanel { Spacing = 12 };
        var valueEntry = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; valueEntry.Children.Add(offsetInput); valueEntry.Children.Add(new TextBlock { Text = "ms", VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7 });
        var numericRow = new Grid { ColumnSpacing = 12 }; numericRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); numericRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        numericRow.Children.Add(Text("播放时间偏移", "Playback offset")); Grid.SetColumn(valueEntry, 1); numericRow.Children.Add(valueEntry); calibrationPanel.Children.Add(numericRow);
        var sliderGroup = new Grid { ColumnSpacing = 12 };
        sliderGroup.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); sliderGroup.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); sliderGroup.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        earlier.VerticalAlignment = later.VerticalAlignment = VerticalAlignment.Top;
        var track = new StackPanel(); track.Children.Add(offset);
        var endpoints = new Grid(); endpoints.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); endpoints.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); endpoints.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var first = Text("−500 ms · 提前", "−500 ms · Earlier", true); var middle = Text("0", "0", true); var last = Text("+500 ms · 延后", "+500 ms · Later", true); last.HorizontalAlignment = HorizontalAlignment.Right;
        endpoints.Children.Add(first); Grid.SetColumn(middle, 1); endpoints.Children.Add(middle); Grid.SetColumn(last, 2); endpoints.Children.Add(last); track.Children.Add(endpoints);
        sliderGroup.Children.Add(earlier); Grid.SetColumn(track, 1); sliderGroup.Children.Add(track); Grid.SetColumn(later, 2); sliderGroup.Children.Add(later); calibrationPanel.Children.Add(sliderGroup);
        calibrationPanel.Children.Add(reset); calibrationPanel.Children.Add(calibrationOutput);
        calibrationPanel.Children.Add(Text("负值提前，正值延后。松开滑块或输入整数后回车保存。", "Negative values play earlier; positive values play later. Release the slider or press Enter to save a whole number.", true));
        calibrationPanel.Children.Add(Text("提前需要已接收音频；调整时会短暂淡出并重新对齐。每个声音输出单独保存。", "Playing earlier requires received audio. Adjustments briefly fade and realign playback. Each output has its own calibration.", true));
        page.Children.Add(Group("同步校准", "Sync calibration", Surface(calibrationPanel))); page.Children.Add(audioError);
        Label(() =>
        {
            AutomationProperties.SetName(offset, L.Text("播放时间偏移", "Playback offset")); AutomationProperties.SetName(offsetInput, L.Text("播放时间偏移（ms）", "Playback offset in milliseconds"));
            AutomationProperties.SetName(earlier, L.Text("提前 10 ms", "10 ms earlier")); AutomationProperties.SetName(later, L.Text("延后 10 ms", "10 ms later"));
            ToolTipService.SetToolTip(earlier, L.Text("提前 10 ms", "10 ms earlier")); ToolTipService.SetToolTip(later, L.Text("延后 10 ms", "10 ms later")); reset.Content = L.Text("恢复默认", "Reset");
        });
        WireCalibration();
        var diagnosticPanel = new StackPanel { Spacing = 14, Padding = new Thickness(0, 8, 0, 8) };
        diagnosticPanel.Children.Add(diagnostics); diagnosticPanel.Children.Add(artwork);
        diagnosticPanel.Children.Add(ActionButton("重新加载封面", "Reload artwork", model.ReloadArtwork));
        diagnosticPanel.Children.Add(ActionButton("打开日志目录", "Open log folder", model.OpenLogs));
        diagnosticPanel.Children.Add(ActionButton("允许局域网连接…", "Allow LAN connections…", ConfigureFirewall));
        var disclosure = new Expander { Name = "ConnectionDiagnostics", Content = diagnosticPanel, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        Label(() => disclosure.Header = L.Text("连接与同步诊断", "Connection & sync diagnostics")); page.Children.Add(disclosure);
        disclosure.Expanding += (_, _) => QueueTypography(disclosure);
        return page;
    }
    private StackPanel PlayerPage()
    {
        var page = Page("播放器", "Player", "设置即时生效并自动保存。", "Changes apply and save automatically.");
        ConfigureCard(transport, "播放控制", "Playback controls", (p, value) => p with { ShowTransport = value });
        ConfigureCard(progress, "进度与时间", "Progress & time", (p, value) => p with { ShowProgress = value });
        ConfigureCard(pinButton, "置顶按钮", "Pin button", (p, value) => p with { ShowPinButton = value });
        AddSegment(lyricsDisplayMode, "automatic", "自动", "Automatic");
        AddSegment(lyricsDisplayMode, "always", "始终开启", "Always on");
        AddSegment(lyricsDisplayMode, "never", "始终关闭", "Always off");
        Label(() => AutomationProperties.SetName(lyricsDisplayMode, L.Text("显示歌词", "Show lyrics")));
        lyricsDisplayMode.SelectionChanged += (_, _) =>
        {
            if (!renderingPreferences && SegmentKey(lyricsDisplayMode) is string key)
                UpdatePreferences(p => p with { LyricsDisplayMode = key });
        };
        var lyricsLabel = new StackPanel { Spacing = 4 };
        lyricsLabel.Children.Add(Text("显示歌词", "Show lyrics"));
        lyricsLabel.Children.Add(Text("自动模式在收到有效歌词后显示。", "Automatic shows lyrics when they are available.", true));
        var lyricsSurface = Surface(Row(lyricsLabel, lyricsDisplayMode));
        AddSegment(progressColorMode, "system", "跟随系统", "System"); AddSegment(progressColorMode, "white", "始终白色", "Always white"); AddSegment(progressColorMode, "custom", "自定义", "Custom");
        Label(() =>
        {
            AutomationProperties.SetName(progressColorMode, L.Text("进度条颜色", "Progress color"));
            progressColor.Language = L.Language == "en" ? "en-US" : "zh-CN"; AutomationProperties.SetName(progressColor, L.Text("自定义进度条颜色", "Custom progress color"));
        });
        progressColorGroup.Children.Add(Row(Text("进度条颜色", "Progress color"), progressColorMode));
        progressColorEditor.Children.Add(progressColor);
        var preview = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var swatch = (Border)XamlReader.Load("""<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="26" Height="26" CornerRadius="4" BorderThickness="1" BorderBrush="{ThemeResource CardStrokeColorDefaultBrush}"/>""");
        swatch.Background = progressColorPreview;
        Label(() => { AutomationProperties.SetName(swatch, L.Text("颜色预览", "Color swatch")); ToolTipService.SetToolTip(swatch, L.Text("颜色预览", "Color swatch")); });
        preview.Children.Add(swatch); preview.Children.Add(progressColorValue); progressColorEditor.Children.Add(preview);
        progressColorEditor.Children.Add(Text("选择不透明 RGB 颜色，也可输入 #RRGGBB。大小播放窗口使用同一颜色。", "Choose an opaque RGB color or enter #RRGGBB. Both player layouts use the same color.", true));
        progressColorGroup.Children.Add(progressColorEditor);
        progressColor.Loaded += (_, _) => QueueTypography(progressColor);
        progressColorSurface = Surface(progressColorGroup); progressColorSurface.Name = "ProgressColorGroup";
        progressColorMode.SelectionChanged += (_, _) =>
        {
            if (renderingPreferences || SegmentKey(progressColorMode) is not string requested) return;
            if (FlushProgressColor()) UpdatePreferences(p => p with { ProgressColorMode = requested }); else RenderPreferences();
        };
        progressColor.ColorChanged += (_, args) =>
        {
            if (renderingPreferences || closed) return;
            string hex = ProgressHex(args.NewColor); progressColorPreview.Color = ParseProgressColor(hex); progressColorValue.Text = hex;
            if (SegmentKey(progressColorMode) != "custom") return;
            pendingProgressColor = hex;
            // Save the newest color at most every 300 ms during continuous dragging.
            if (!progressColorSaveTimer.IsRunning) progressColorSaveTimer.Start();
        };
        var display = Group("播放显示", "Player display", Cards(transport, progress, pinButton), lyricsSurface, progressColorSurface,
            Text("播放控制与进度设置适用于大小播放器；进度条支持点击跳转。", "Playback controls and progress settings apply to both layouts. Click the progress bar to seek.", true));
        page.Children.Add(display);
        ConfigureCard(correctLyricTitles, "修正歌词标题", "Correct lyric titles", (p, value) => p with { CorrectLyricTitles = value }, activationLabels: true);
        var titleCorrectionDescription = Text("仅在手机歌词提供可信歌名信息时修正播放器、托盘和系统媒体中的显示。不会改动原始曲目或播放控制；无法核实时保留原样。", "Corrects the player, tray, and system media display only when the phone's lyrics provide verifiable track information. Original track data and playback controls stay intact; unverified titles are kept.", true);
        titleCorrectionDescription.Name = "TitleCorrectionDescription";
        page.Children.Add(Group("曲目信息", "Track information", Cards(correctLyricTitles), titleCorrectionDescription));
        ConfigureCard(settingsButton, "设置按钮", "Settings button", (p, value) => p with { ShowSettingsButton = value });
        ConfigureCard(fullScreenButton, "全屏按钮", "Full screen button", (p, value) => p with { ShowFullScreenButton = value });
        var buttonDescription = Text("设置按钮仅在展开播放器显示；全屏按钮适用于大小播放器。隐藏后仍可用 Ctrl+, 打开设置、F11 切换全屏。", "The settings button appears only in the expanded player; the full screen button appears in both layouts. Ctrl+, still opens Settings and F11 toggles full screen when the buttons are hidden.", true);
        buttonDescription.Name = "WindowButtonsDescription";
        var windowButtons = Group("窗口按钮", "Window buttons", Cards(settingsButton, fullScreenButton), buttonDescription); windowButtons.Name = "WindowButtons";
        page.Children.Add(windowButtons);
        AddSegment(miniVisibility, "hover", "鼠标移入显示", "Show on hover"); AddSegment(miniVisibility, "always", "始终显示", "Always show");
        Label(() => AutomationProperties.SetName(miniVisibility, L.Text("迷你窗口控件显隐", "Mini player controls visibility")));
        miniVisibility.SelectionChanged += (_, _) => { if (!renderingPreferences && SegmentKey(miniVisibility) is string key) UpdatePreferences(p => p with { AlwaysShowControls = key == "always" }); };
        var miniLabel = new StackPanel { Spacing = 4 }; miniLabel.Children.Add(Text("控件显隐", "Controls visibility")); miniLabel.Children.Add(Text("歌曲信息、进度和已开启的控件", "Track info, progress, and enabled controls", true));
        page.Children.Add(Group("迷你窗口", "Mini player", Surface(Row(miniLabel, miniVisibility))));
        RoutedEventHandler pinChanged = (_, _) =>
        {
            if (renderingPreferences) return;
            bool requested = pinned.IsChecked == true;
            UpdatePreferences(p => p with { Pinned = requested });
        };
        pinned.Checked += pinChanged; pinned.Unchecked += pinChanged;
        Label(() => AutomationProperties.SetName(pinned, L.Text("窗口置顶", "Keep window on top")));
        page.Children.Add(Group("窗口行为", "Window behavior", Surface(Row(Text("窗口置顶", "Keep on top"), pinned)))); page.Children.Add(playerError);
        return page;
    }
    private StackPanel GeneralPage()
    {
        var page = Page("通用", "General", "设置即时生效并自动保存。", "Changes apply and save automatically.");
        AddSegment(language, "zh-Hans", "简体中文", "简体中文"); AddSegment(language, "en", "English", "English");
        Label(() => AutomationProperties.SetName(language, L.Text("界面语言", "Interface language")));
        language.SelectionChanged += (_, _) => { if (!renderingPreferences && SegmentKey(language) is string key) UpdatePreferences(p => p with { Language = key }); };
        page.Children.Add(Group("界面语言", "Language", Surface(Row(Text("界面语言", "Interface language"), language))));
        fontSettings = new FontSettingsPanel(model.Preferences, UpdatePreferences); Label(fontSettings.Localize);
        var fontHeading = new StackPanel { Spacing = 4 }; fontHeading.Children.Add(Text("字体设置", "Font settings")); fontHeading.Children.Add(fontSummary);
        var fontDisclosure = new Expander { Name = "FontDisclosure", Header = fontHeading, Content = fontSettings, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        fontDisclosure.Expanding += (_, _) => QueueTypography(fontDisclosure);
        page.Children.Add(Group("字体与文字效果", "Fonts & text", fontDisclosure));
        ConfigureCard(taskbar, "任务栏图标", "Taskbar icon", (p, value) => p with { ShowTaskbarIcon = value });
        ConfigureCard(tray, "托盘图标", "Tray icon", (p, value) => p with { ShowTrayIcon = value });
        page.Children.Add(Group("应用入口", "App entry points", Cards(taskbar, tray), Text("两个入口都隐藏时，再次打开程序可进入设置。", "If both entry points are hidden, reopen FusionPlay to reach Settings.", true))); page.Children.Add(generalError);
        return page;
    }
    private StackPanel AboutPage()
    {
        var page = Page("关于", "About", "FusionPlay for Windows", "FusionPlay for Windows");
        var product = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 20 };
        product.Children.Add(new Image { Name = "SettingsAppIcon", Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.png"))), Width = 64, Height = 64, Stretch = Stretch.Uniform });
        var identity = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        identity.Children.Add(new TextBlock { Text = "FusionPlay Windows", FontSize = 23, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); identity.Children.Add(Text("让音乐，连接此刻", "Music brings us together"));
        string version = typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? typeof(App).Assembly.GetName().Version?.ToString(3) ?? "0.2.0";
        identity.Children.Add(new TextBlock { Text = version, FontSize = 12, Opacity = 0.7 }); product.Children.Add(identity); page.Children.Add(Surface(product));
        page.Children.Add(Text("Windows 妙播接收器", "MiPlay receiver for Windows")); page.Children.Add(Text("便携版 · 数据保存在程序旁的 FusionPlayData", "Portable edition · Data is stored in FusionPlayData beside the application.", true));
        page.Children.Add(Text("关闭窗口后继续接收音乐。再次打开程序可返回播放窗口。", "Music keeps playing when the window is closed. Reopen FusionPlay to return to the player.", true));
        page.Children.Add(ActionButton("项目主页", "Project home", () => Open("https://github.com/ZrimYoung/FusionPlay")));
        page.Children.Add(Text("开源许可：AGPL-3.0-only", "License: AGPL-3.0-only")); page.Children.Add(ActionButton("查看许可证", "View license", () => Open(Path.Combine(AppContext.BaseDirectory, "LICENSE")))); page.Children.Add(aboutError);
        return page;
    }

    private bool ReceiverDirty => name.Text.Trim() != model.Settings.Name || (network.SelectedItem as Choice)?.Key != model.Settings.InterfaceName;
    private bool OutputDirty => (output.SelectedItem as Choice)?.Key != model.Settings.OutputDevice;
    private bool CanApply => model.Initialized && !model.Busy && !model.CalibrationBusy && !applyingSettings && !changingCalibration;
    private async Task ApplyReceiverAsync()
    {
        if (!CanApply || !ReceiverDirty && !receiverRetryRequired) return;
        string receiverName = name.Text.Trim();
        if (receiverName.Length == 0 || receiverName.EnumerateRunes().Count() > 64)
        {
            receiverMessage = L.Text("设备名称需包含 1–64 个字符。", "The device name must contain 1–64 characters."); Render(); return;
        }
        var settings = model.Settings with { Name = receiverName, InterfaceName = (network.SelectedItem as Choice)?.Key ?? model.Settings.InterfaceName };
        applyingSettings = true; receiverMessage = ""; InvalidateCalibration(); Render();
        try
        {
            await model.StartAsync(settings);
            if (closed) return;
            receiverRetryRequired = model.Error.Length > 0; receiverApplied = !receiverRetryRequired;
            receiverMessage = receiverRetryRequired ? L.Text(model.Error) : "";
            if (!receiverRetryRequired) { AcceptAppliedSettings(); await RefreshCalibrationAsync(force: true); }
        }
        catch (Exception e) { receiverRetryRequired = true; receiverMessage = Friendly(e, "接收设置应用失败，请重试。", "Receiver settings could not be applied. Retry."); }
        finally { applyingSettings = false; Render(); }
    }
    private async Task ApplyOutputAsync()
    {
        if (!CanApply || !OutputDirty && !outputRetryRequired) return;
        // Receiver fields here come only from the applied model, never the receiver form draft.
        var settings = model.Settings with { OutputDevice = (output.SelectedItem as Choice)?.Key ?? model.Settings.OutputDevice };
        applyingSettings = true; audioMessage = ""; InvalidateCalibration(); Render();
        try
        {
            await model.StartAsync(settings);
            if (closed) return;
            outputRetryRequired = model.Error.Length > 0; outputApplied = !outputRetryRequired;
            audioMessage = outputRetryRequired ? L.Text(model.Error) : "";
            if (!outputRetryRequired) { AcceptAppliedSettings(); await RefreshCalibrationAsync(force: true); }
        }
        catch (Exception e) { outputRetryRequired = true; audioMessage = Friendly(e, "声音输出应用失败，请重试。", "The audio output could not be applied. Retry."); }
        finally { applyingSettings = false; Render(); }
    }
    private async Task ToggleReceivingAsync()
    {
        if (!CanApply) return;
        bool starting = !model.WantsReceiving; applyingSettings = true; receiverMessage = ""; InvalidateCalibration(); Render();
        try
        {
            if (starting) await model.StartAsync(); else await model.StopAsync();
            if (closed) return;
            receiverMessage = L.Text(model.Error);
            if (starting && model.Error.Length == 0) AcceptAppliedSettings();
            await RefreshCalibrationAsync(force: true);
        }
        catch (Exception e) { receiverMessage = Friendly(e, "接收状态未能更改，请重试。", "The receiver state could not be changed. Retry."); }
        finally { applyingSettings = false; Render(); }
    }
    private void InvalidateCalibration()
    {
        ++calibrationRefreshVersion; ++deferredCommitVersion; calibration = null; loadingCalibration = false;
        numericEditing = sliderDragging = syncButtonPointerDown = false; SetOffsetDraft(0);
    }
    private void AcceptAppliedSettings()
    {
        // Start submits the whole applied model. A successful start also resolves
        // a prior failed attempt from the other group, without touching its form draft.
        if (receiverRetryRequired) { receiverRetryRequired = false; receiverMessage = ""; receiverApplied = true; }
        if (outputRetryRequired) { outputRetryRequired = false; audioMessage = ""; outputApplied = true; }
    }
    private void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception) { aboutMessage = L.Text("操作未完成，请重试或打开日志检查。", "The action could not be completed. Retry or check the logs."); Render(); }
    }
    private static string Friendly(Exception error, string chinese, string english) => error is ReceiverException ? L.Text(error.Message) : L.Text(chinese, english);
    private bool UpdatePreferences(Func<UiPreferences, UiPreferences> update)
    {
        bool saved = true;
        try
        {
            preferenceMessage = "";
            var requested = update(model.Preferences.Value);
            if (!requested.ShowProgress && pendingProgressColor != null)
            {
                if (!FlushProgressColor()) return false;
                requested = update(model.Preferences.Value);
            }
            model.Preferences.Update(requested);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
        {
            saved = false; preferenceMessage = L.Text("界面设置保存失败，请检查程序旁的数据目录是否可写。", "Appearance settings could not be saved. Check that the data folder beside the application is writable."); RenderPreferences();
        }
        Render(); return saved;
    }
    private void PreferencesChanged() { RenderPreferences(); Render(); }
    private void RenderPreferences()
    {
        if (closed) return;
        renderingPreferences = true;
        try
        {
            var preferences = model.Preferences.Value;
            fontSettings.Refresh(); if (Content is FrameworkElement root) UiTypography.Apply(root, preferences);
            SelectSegment(language, preferences.Language); SelectSegment(progressColorMode, preferences.ProgressColorMode); SelectSegment(miniVisibility, preferences.AlwaysShowControls ? "always" : "hover");
            SelectSegment(lyricsDisplayMode, preferences.LyricsDisplayMode);
            transport.IsChecked = preferences.ShowTransport; progress.IsChecked = preferences.ShowProgress; pinButton.IsChecked = preferences.ShowPinButton;
            settingsButton.IsChecked = preferences.ShowSettingsButton; fullScreenButton.IsChecked = preferences.ShowFullScreenButton;
            correctLyricTitles.IsChecked = preferences.CorrectLyricTitles;
            pinned.IsChecked = preferences.Pinned; pinned.Content = L.Text(preferences.Pinned ? "已置顶" : "未置顶", preferences.Pinned ? "Pinned" : "Not pinned");
            taskbar.IsChecked = preferences.ShowTaskbarIcon; tray.IsChecked = preferences.ShowTrayIcon;
            progressColorSurface.Visibility = preferences.ShowProgress ? Visibility.Visible : Visibility.Collapsed;
            progressColorMode.IsEnabled = progressColor.IsEnabled = preferences.ShowProgress;
            progressColorEditor.Visibility = preferences.ProgressColorMode == "custom" ? Visibility.Visible : Visibility.Collapsed;
            string hex = pendingProgressColor ?? preferences.ProgressCustomColor;
            progressColor.Color = ParseProgressColor(hex); progressColorPreview.Color = ParseProgressColor(hex); progressColorValue.Text = hex;
            string family = preferences.UiFontFamily.Length > 0 ? preferences.UiFontFamily : L.Text("跟随系统字体", "System font"); fontSummary.Text = family + " · " + preferences.UiFontWeight;
        }
        finally { renderingPreferences = false; }
    }
    private void ProgressColorSaveTick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args) => FlushProgressColor();
    private bool FlushProgressColor()
    {
        progressColorSaveTimer.Stop(); string? hex = pendingProgressColor; pendingProgressColor = null;
        if (hex == null) return true;
        if (UpdatePreferences(p => p with { ProgressCustomColor = hex })) return true;
        // Keep the final color retryable when a mode change or close is cancelled.
        pendingProgressColor = hex; RenderPreferences(); return false;
    }
    private static string ProgressHex(global::Windows.UI.Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";
    private static global::Windows.UI.Color ParseProgressColor(string hex) => global::Windows.UI.Color.FromArgb(255,
        byte.Parse(hex.AsSpan(1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture), byte.Parse(hex.AsSpan(3, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture), byte.Parse(hex.AsSpan(5, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
    private void RenderDevices()
    {
        if (closed) return;
        renderingDevices = true;
        try
        {
            string networkValue = (network.SelectedItem as Choice)?.Key ?? model.Settings.InterfaceName;
            string outputValue = (output.SelectedItem as Choice)?.Key ?? model.Settings.OutputDevice;
            var networks = new List<Choice> { new("", L.Text("自动选择局域网", "Automatic LAN selection")) };
            networks.AddRange(model.Networks.Select(item => new Choice(item.Name, $"{item.Name} · {item.Address}")));
            if (networkValue.Length > 0 && !networks.Any(x => x.Key == networkValue)) networks.Add(new(networkValue, networkValue + " · " + L.Text("不可用", "Unavailable")));
            network.ItemsSource = networks; network.SelectedItem = networks.First(x => x.Key == networkValue);
            var outputs = new List<Choice> { new("", L.Text("跟随系统输出", "Follow system output")) };
            outputs.AddRange(model.Outputs.Select(item => new Choice(item.Id, item.Name + (item.IsDefault ? " · " + L.Text("系统默认", "System default") : ""))));
            if (outputValue.Length > 0 && !outputs.Any(x => x.Key == outputValue)) outputs.Add(new(outputValue, L.Text("所选设备已断开", "Selected device disconnected")));
            output.ItemsSource = outputs; output.SelectedItem = outputs.First(x => x.Key == outputValue);
        }
        finally { renderingDevices = false; }
    }
    private static void ShowError(InfoBar bar, string message) { bar.Message = message; bar.IsOpen = message.Length > 0; bar.Visibility = bar.IsOpen ? Visibility.Visible : Visibility.Collapsed; }
    private void Render()
    {
        if (closed) return;
        bool receiverDirty = ReceiverDirty, outputDirty = OutputDirty;
        save.IsEnabled = CanApply && (receiverDirty || receiverRetryRequired); applyOutput.IsEnabled = CanApply && (outputDirty || outputRetryRequired); receiving.IsEnabled = CanApply;
        save.Content = L.Text(receiverRetryRequired ? "重试应用并重新连接" : "应用并重新连接", receiverRetryRequired ? "Retry apply & reconnect" : "Apply & reconnect");
        applyOutput.Content = L.Text(outputRetryRequired ? "重试应用输出" : "应用输出并重新连接", outputRetryRequired ? "Retry audio output" : "Apply output & reconnect");
        receiving.Content = L.Text(model.WantsReceiving ? "停止接收" : "启动接收", model.WantsReceiving ? "Stop receiving" : "Start receiving");
        receiverStatus.Text = L.Text(receiverDirty ? "有未应用的更改" : receiverRetryRequired ? "应用失败，可重试。" : receiverApplied ? "已应用接收设置。" : "当前没有未应用的更改", receiverDirty ? "Unapplied changes" : receiverRetryRequired ? "Apply failed. You can retry." : receiverApplied ? "Receiver settings applied." : "No unapplied changes");
        outputStatus.Text = L.Text(outputDirty ? "有未应用的输出更改；应用后会重新连接。" : outputRetryRequired ? "输出应用失败，请重试后再校准。" : outputApplied ? "已应用声音输出。" : "选择输出后应用，当前接收会重新连接。", outputDirty ? "Unapplied output change. Applying reconnects the receiver." : outputRetryRequired ? "Output apply failed. Retry before calibrating." : outputApplied ? "Audio output applied." : "Apply an output change to reconnect the receiver.");
        bool endpointMatches = calibration?.OutputDeviceId.Length > 0 && ((output.SelectedItem as Choice)?.Key is "" || (output.SelectedItem as Choice)?.Key == calibration.OutputDeviceId);
        bool adjust = CanApply && !loadingCalibration && !outputDirty && !outputRetryRequired && endpointMatches;
        offset.IsEnabled = offsetInput.IsEnabled = adjust;
        bool validDraft = TryParseOffset(out int draft); earlier.IsEnabled = adjust && validDraft && draft > -500; later.IsEnabled = adjust && validDraft && draft < 500; reset.IsEnabled = adjust && (draftDirty || validDraft && draft != 0);
        calibrationOutput.Text = outputDirty ? L.Text("请先应用声音输出设置。", "Apply the audio output first.") : outputRetryRequired ? L.Text("输出尚未成功应用，校准已暂停。", "Calibration is paused until the output is applied successfully.") : L.Text("当前输出：", "Current output: ") + (model.Outputs.FirstOrDefault(item => item.Id == calibration?.OutputDeviceId)?.Name ?? L.Text("尚无可用声音输出", "No audio output available"));
        var state = model.State;
        diagnostics.Text = $"{L.Text("状态")}    {L.Text(state.PhaseLabel)}\n{L.Text("输出设备")}    {(state.Output.Length > 0 ? state.Output : L.Text("尚未输出"))}\n{L.Text("音频缓冲")}    {state.QueueMs:F1} ms\n{L.Text("设备输出延迟")}    {state.OutputLatencyMs:F1} ms\n{L.Text("调度误差")}    {state.ScheduleErrorMs:F1} ms\n{L.Text("欠载 / 丢帧")} {state.Underruns} / {state.DroppedFrames}\n{L.Text("重新同步")}    {state.Resyncs}\n\n{L.Text("调度误差不代表实际声学同步偏差。")}";
        artwork.Text = L.Text("专辑封面", "Artwork") + ": " + L.Text(model.ArtworkStatus);
        ShowError(receiverError, receiverMessage.Length > 0 ? receiverMessage : !outputRetryRequired ? L.Text(model.Error) : ""); ShowError(audioError, audioMessage); ShowError(playerError, preferenceMessage); ShowError(generalError, preferenceMessage); ShowError(aboutError, aboutMessage);
    }
    private async Task RefreshCalibrationAsync(bool force = false)
    {
        if (!model.Initialized || closed) return;
        int request = ++calibrationRefreshVersion; loadingCalibration = true; Render();
        try
        {
            var current = await model.GetCalibrationAsync();
            if (closed || request != calibrationRefreshVersion) return;
            bool sameOutput = calibration?.OutputDeviceId == current.OutputDeviceId; calibration = current;
            if (force || !sameOutput || !draftDirty && !numericEditing && !sliderDragging) { ++deferredCommitVersion; SetOffsetDraft(current.OffsetMs); }
        }
        catch (Exception e) { if (!closed && request == calibrationRefreshVersion) audioMessage = Friendly(e, "无法读取当前输出的校准设置。", "Calibration for the current audio output could not be read."); }
        finally { if (request == calibrationRefreshVersion) loadingCalibration = false; Render(); }
    }
    private void SetOffsetDraft(int value)
    {
        renderingCalibration = true;
        try { offset.Value = value; offsetInput.Text = value.ToString(CultureInfo.InvariantCulture); draftDirty = false; }
        finally { renderingCalibration = false; }
    }
    private void DevicesChanged() { RenderDevices(); Render(); _ = RefreshCalibrationAsync(); }
    private bool TryParseOffset(out int value) => int.TryParse(offsetInput.Text, NumberStyles.Integer, CultureInfo.InvariantCulture, out value) && value is >= -500 and <= 500;
    private void WireCalibration()
    {
        offset.ValueChanged += (_, args) => { if (!renderingCalibration) { draftDirty = true; offsetInput.Text = ((int)Math.Round(args.NewValue)).ToString(CultureInfo.InvariantCulture); } };
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
            // Do not let focus loss submit the old value before the pointer button's click.
            button.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => { syncButtonPointerDown = true; ++deferredCommitVersion; }), true);
            button.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => { syncButtonPointerDown = false; QueueBlurCommit(); }), true);
            button.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler((_, _) => { syncButtonPointerDown = false; QueueBlurCommit(); }), true);
            button.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler((_, _) => { syncButtonPointerDown = false; QueueBlurCommit(); }), true);
        }
        earlier.Click += async (_, _) => await AdjustOffsetAsync(-10); later.Click += async (_, _) => await AdjustOffsetAsync(10);
        reset.Click += async (_, _) => { ++deferredCommitVersion; syncButtonPointerDown = false; await ChangeCalibrationAsync(0); };
    }
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
        if (!TryParseOffset(out int value)) { audioMessage = L.Text("请输入 −500 到 500 之间的整数。", "Enter a whole number between −500 and 500."); Render(); return; }
        await ChangeCalibrationAsync(Math.Clamp(value + delta, -500, 500));
    }
    private async Task CommitOffsetInputAsync()
    {
        ++deferredCommitVersion;
        if (closed || renderingCalibration || changingCalibration || !offsetInput.IsEnabled) return;
        if (!TryParseOffset(out int value)) { audioMessage = L.Text("请输入 −500 到 500 之间的整数。", "Enter a whole number between −500 and 500."); Render(); return; }
        await ChangeCalibrationAsync(value);
    }
    private async Task ChangeCalibrationAsync(double value)
    {
        if (closed || changingCalibration || renderingCalibration || calibration == null || !double.IsFinite(value) || model.Busy || model.CalibrationBusy || !offset.IsEnabled) return;
        int requested = (int)Math.Clamp(Math.Round(value), -500, 500); audioMessage = "";
        if (requested == calibration.OffsetMs) { SetOffsetDraft(requested); Render(); return; }
        changingCalibration = true; Render();
        try
        {
            await model.ApplyCalibrationAsync(calibration with { OffsetMs = requested });
            if (closed) return;
            if (model.Error.Length > 0) { audioMessage = L.Text(model.Error); return; }
            await RefreshCalibrationAsync(force: true);
        }
        catch (Exception e) { audioMessage = Friendly(e, "同步校准保存失败，请重试。", "Sync calibration could not be saved. Retry."); }
        finally { changingCalibration = false; Render(); }
    }
    private async void ConfigureFirewall()
    {
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = ((FrameworkElement)Content).XamlRoot, Title = L.Text("允许局域网投放", "Allow LAN casting"),
                Content = L.Text("仅为当前程序路径添加专用网络、本地子网的入站规则。Windows 将请求管理员权限；程序本身仍以普通用户运行。", "Add inbound rules for this application path on private networks and the local subnet only. Windows will ask for administrator permission; FusionPlay continues running as a normal user."),
                PrimaryButtonText = L.Text("配置规则", "Configure rules"), CloseButtonText = L.Text("取消", "Cancel"), DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || closed) return;
            string script = Path.Combine(AppContext.BaseDirectory, "Configure-Firewall.ps1");
            var start = new ProcessStartInfo("powershell.exe") { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden };
            foreach (string argument in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-ProgramPath", Environment.ProcessPath! }) start.ArgumentList.Add(argument);
            Process.Start(start);
        }
        catch (Exception) { audioMessage = L.Text("防火墙配置未完成，可稍后重试。", "Firewall configuration did not complete. You can retry later."); Render(); }
    }
}
