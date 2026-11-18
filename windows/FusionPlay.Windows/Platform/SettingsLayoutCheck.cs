using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using FusionPlay.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace FusionPlay.Windows.Platform;

/// <summary>Hidden checks of the real settings controls. Never initializes a receiver.</summary>
internal static class SettingsLayoutCheck
{
    internal static List<string> UnhandledErrors { get; } = [];
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint hwnd, out ClientRect rect);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint hwnd);
    [StructLayout(LayoutKind.Sequential)] private struct ClientRect { public int Left, Top, Right, Bottom; }
    private sealed class CheckFailure(string code) : Exception(code);
    private sealed record Box(double X, double Y, double Width, double Height);

    public static async Task Run(string directory)
    {
        Directory.CreateDirectory(directory);
        var queue = DispatcherQueue.GetForCurrentThread();
        var handles = new List<nint>();
        var cases = new List<string>();
        var layouts = new List<object>();
        var typography = new List<object>();
        var symbolFonts = new List<object>();
        var captures = new List<object>();
        var cleanupErrors = new List<string>();
        nint foreground = GetForegroundWindow();
        Window? anchor = null;
        SettingsWindow? settings = null;
        ReceiverController? controller = null;
        bool hidden = true, focus = true, foregroundNotTaken = true, capturedPreferences = false, preferencesRestored = false;
        bool initializedFixture = false, controllerCreated = false;
        string status = "failed", step = "create_hidden_anchor", failure = "", exception = "", hresult = "";
        string originalLanguage = L.Language;
        var store = new PortableStore(AppContext.BaseDirectory);
        string preferencesPath = Path.Combine(store.Data, "ui-preferences.json");
        byte[]? originalBytes = null;
        HashSet<string> originalInvalid = [];
        var fixtureNetworks = new[]
        {
            new NetworkInterface("Fixture Wi-Fi", "192.0.2.10"),
            new NetworkInterface("Fixture Wi-Fi 2", "198.51.100.11"),
            new NetworkInterface("Fixture Ethernet", "203.0.113.12"),
            new NetworkInterface("Fixture USB Ethernet", "192.0.2.13")
        };
        var fixtureOutputs = new[]
        {
            new AudioDevice("fixture-speakers", "Fixture Speakers", true),
            new AudioDevice("fixture-headphones", "Fixture Headphones", false),
            new AudioDevice("fixture-hdmi", "Fixture HDMI", false)
        };
        var fixtureSettings = new ReceiverSettings("Fixture Receiver", "Missing Fixture Network", "fixture-missing-output", 50);
        string[] pages = ["receiver", "audio", "player", "general", "about"];

        void Require(bool ok, string code) { if (!ok) throw new CheckFailure(code); }
        void Background()
        {
            hidden &= handles.All(hwnd => !IsWindowVisible(hwnd));
            nint current = GetForegroundWindow(); focus &= current == foreground;
            foregroundNotTaken &= !handles.Contains(current);
            Require(hidden, "settings_window_became_visible");
            Require(foregroundNotTaken, "settings_check_took_foreground");
            if (controller != null)
            {
                Require(typeof(ReceiverController).GetField("native", PrivateInstance)!.GetValue(controller) == null, "native_receiver_was_created");
                Require(typeof(ReceiverController).GetField("polling", PrivateInstance)!.GetValue(controller) == null, "receiver_polling_was_started");
            }
        }
        void Pass(string name, Action action) { Background(); action(); Background(); cases.Add(name); }
        void Track(Window window)
        {
            window.AppWindow.IsShownInSwitchers = false;
            handles.Add(WinRT.Interop.WindowNative.GetWindowHandle(window));
            Background();
        }
        void FixtureProperty(string property, object value)
        {
            var member = typeof(ReceiverController).GetProperty(property);
            Require(member?.GetSetMethod(nonPublic: true) != null, "fixture_setter_missing_" + property);
            member!.SetValue(controller, value);
        }
        void CreateController()
        {
            controller = new ReceiverController(queue!); controllerCreated = true;
            FixtureProperty(nameof(ReceiverController.Settings), fixtureSettings);
            FixtureProperty(nameof(ReceiverController.Networks), fixtureNetworks);
            FixtureProperty(nameof(ReceiverController.Outputs), fixtureOutputs);
            Require(!controller.Initialized, "controller_initialized_before_fixture");
            Background();
        }
        void CreateSettings()
        {
            Require(controller != null && !controller.Initialized, "settings_constructor_fixture_not_uninitialized");
            settings = new SettingsWindow(controller!); Track(settings);
            Arrange(960, 740);
        }
        FrameworkElement Root() => (FrameworkElement)settings!.Content;
        T Find<T>(string name) where T : FrameworkElement => Descendants(Root()).OfType<T>().FirstOrDefault(element => element.Name == name)
            ?? throw new CheckFailure("settings_named_element_missing_" + name);
        void Arrange(double width, double height)
        {
            WindowSizing.ResizeContent(settings!, width, height);
            var root = Root();
            for (int pass = 0; pass < 3; pass++)
            {
                // Hidden NavigationView pages do not receive a visible Loaded
                // pass. Materialize native control templates before measuring.
                foreach (var control in Descendants(root).OfType<Control>().ToArray()) control.ApplyTemplate();
                root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
            }
            Background();
        }
        void Navigate(string page)
        {
            var navigation = Find<NavigationView>("SettingsNavigation");
            navigation.SelectedItem = navigation.MenuItems.OfType<NavigationViewItem>().Single(item => item.Tag as string == page);
            Root().UpdateLayout();
        }
        string Key(object? item) => item?.GetType().GetProperty("Key")?.GetValue(item) as string ?? "";
        string Label(object item) => item.GetType().GetProperty("Label")?.GetValue(item) as string ?? "";
        void Select(ComboBox combo, string key)
        {
            combo.SelectedItem = combo.Items.Cast<object>().Single(item => Key(item) == key);
            Root().UpdateLayout();
        }
        void SelectSegment(string name, string key)
        {
            var bar = Find<SelectorBar>(name);
            bar.SelectedItem = bar.Items.Single(item => item.Tag as string == key);
            Root().UpdateLayout();
        }
        void Toggle(string name)
        {
            var button = Find<ToggleButton>(name);
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button) ?? new ToggleButtonAutomationPeer(button);
            Require(peer.GetPattern(PatternInterface.Toggle) is IToggleProvider, "native_toggle_pattern_missing_" + name);
            ((IToggleProvider)peer.GetPattern(PatternInterface.Toggle)).Toggle();
            Root().UpdateLayout();
        }
        void Invoke(string name)
        {
            var button = Find<Button>(name);
            Require(button.IsEnabled, "apply_button_disabled_" + name);
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button) ?? new ButtonAutomationPeer(button);
            Require(peer.GetPattern(PatternInterface.Invoke) is IInvokeProvider, "native_invoke_pattern_missing_" + name);
            ((IInvokeProvider)peer.GetPattern(PatternInterface.Invoke)).Invoke();
        }
        Box Bounds(FrameworkElement element)
        {
            var box = element.TransformToVisual(Root()).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            return new(box.X, box.Y, box.Width, box.Height);
        }
        bool Visible(DependencyObject element)
        {
            for (DependencyObject? current = element; current != null; current = VisualTreeHelper.GetParent(current))
                if (current is UIElement { Visibility: Visibility.Collapsed }) return false;
            return true;
        }
        void Inspect(string page, double width, double height, string language)
        {
            Arrange(width, height);
            var navigation = Find<NavigationView>("SettingsNavigation");
            object Geometry(DependencyObject? element)
            {
                if (element is not FrameworkElement view) return new { type = element?.GetType().Name ?? "none" };
                return new
                {
                    type = view.GetType().Name, name = view.Name, bounds = Bounds(view),
                    actual_width = view.ActualWidth, actual_height = view.ActualHeight,
                    desired_width = view.DesiredSize.Width, desired_height = view.DesiredSize.Height,
                    explicit_width = double.IsFinite(view.Width) ? (double?)view.Width : null,
                    maximum_width = double.IsFinite(view.MaxWidth) ? (double?)view.MaxWidth : null,
                    margin = new[] { view.Margin.Left, view.Margin.Top, view.Margin.Right, view.Margin.Bottom },
                    horizontal_alignment = view.HorizontalAlignment.ToString()
                };
            }
            object[] Ancestors(DependencyObject? element)
            {
                var result = new List<object>();
                for (var current = element; current != null && result.Count < 20; current = VisualTreeHelper.GetParent(current))
                {
                    result.Add(Geometry(current));
                    if (ReferenceEquals(current, Root())) break;
                }
                return result.ToArray();
            }
            var scroll = navigation.Content as ScrollViewer;
            var pageContent = scroll?.Content as FrameworkElement;
            layouts.Add(new
            {
                kind = "page_geometry_before_assertions", page, language, width, height,
                root = Geometry(Root()), navigation = Geometry(navigation), scroll = Geometry(scroll), page_content = Geometry(pageContent),
                navigation_ancestors = Ancestors(navigation), scroll_ancestors = Ancestors(scroll), page_ancestors = Ancestors(pageContent)
            });
            Require(navigation.PaneDisplayMode is NavigationViewPaneDisplayMode.Auto or NavigationViewPaneDisplayMode.Left, "settings_navigation_is_not_side_navigation");
            var expectedDisplay = navigation.PaneDisplayMode == NavigationViewPaneDisplayMode.Left
                ? NavigationViewDisplayMode.Expanded
                : navigation.ActualWidth >= navigation.ExpandedModeThresholdWidth ? NavigationViewDisplayMode.Expanded
                : navigation.ActualWidth >= navigation.CompactModeThresholdWidth ? NavigationViewDisplayMode.Compact : NavigationViewDisplayMode.Minimal;
            Require(navigation.DisplayMode == expectedDisplay, "settings_navigation_display_mode_mismatch");
            Require(navigation.MenuItems.OfType<NavigationViewItem>().Select(item => item.Tag as string).SequenceEqual(pages), "settings_five_pages_changed");
            Require(GetClientRect(WinRT.Interop.WindowNative.GetWindowHandle(settings!), out var client), "settings_client_unavailable");
            double scale = Root().XamlRoot?.RasterizationScale ?? Math.Max(96, GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(settings!))) / 96.0;
            double clientWidth = (client.Right - client.Left) / scale, clientHeight = (client.Bottom - client.Top) / scale;
            Require(Math.Abs(clientWidth - width) <= 2 && Math.Abs(clientHeight - height) <= 2, "settings_client_size_changed");
            var titleBar = Find<Grid>("SettingsTitleBar"); var caption = Find<TextBlock>("SettingsWindowTitle");
            var titleBounds = Bounds(titleBar); var captionBounds = Bounds(caption); var navigationBounds = Bounds(navigation);
            Require(settings!.ExtendsContentIntoTitleBar && titleBounds.Height >= 32 && Math.Abs(titleBounds.Y) <= 1,
                "settings_titlebar_not_in_client");
            Require(Math.Abs(titleBounds.Width - width) <= 1 && navigationBounds.Y >= titleBounds.Y + titleBounds.Height - 1,
                "settings_titlebar_overlaps_navigation");
            Require(captionBounds.Width > 0 && captionBounds.X >= 15 && captionBounds.X + captionBounds.Width <= width - titleBar.Padding.Right + 1,
                "settings_titlebar_caption_clipped");
            Require(titleBar.Padding.Right >= settings.AppWindow.TitleBar.RightInset / scale && titleBar.Padding.Left >= settings.AppWindow.TitleBar.LeftInset / scale,
                "settings_titlebar_native_buttons_not_reserved");
            string[] controlNames = ["ReceiverName", "NetworkInterface", "ApplyReceiver", "ReceivingToggle", "AudioOutput", "ApplyOutput", "ShowTransport", "ShowProgress", "ShowPinButton", "ShowSettingsButton", "ShowFullScreenButton", "ProgressColorMode", "ProgressCustomColor", "LyricsDisplayMode", "MiniControlsVisibility", "Pinned", "InterfaceLanguage", "FontDisclosure", "TaskbarEntry", "TrayEntry", "CalibrationEarlier", "CalibrationRange", "CalibrationLater", "CalibrationValue", "CalibrationReset"];
            if (page == "player")
            {
                var choices = Find<StackPanel>("WindowButtons").Children.OfType<Grid>().Single();
                Require(choices.ColumnDefinitions.Count == 2 && choices.Children.Count == 2, "window_button_choices_not_separate_two_column_group");
                Require(new ToggleButtonAutomationPeer(Find<ToggleButton>("ShowSettingsButton")).GetName() == L.Text("设置按钮", "Settings button")
                    && new ToggleButtonAutomationPeer(Find<ToggleButton>("ShowFullScreenButton")).GetName() == L.Text("全屏按钮", "Full screen button"), "window_button_choice_names_not_localized");
                string description = Find<TextBlock>("WindowButtonsDescription").Text;
                Require(description.Contains("Ctrl+,") && description.Contains("F11") && description.Contains(language == "en" ? "expanded" : "展开"), "window_button_scope_or_shortcut_description_missing");
            }
            var controls = Descendants(Root()).OfType<FrameworkElement>().Where(element => controlNames.Contains(element.Name) && Visible(element)
                && (element is ButtonBase or ComboBox or SelectorBar or TextBox or Slider or Expander)).ToArray();
            var boxes = new List<object>();
            foreach (var element in controls)
            {
                if (element.ActualWidth <= 0 || element.ActualHeight <= 0) continue;
                var box = Bounds(element);
                // Vertical scrolling is expected; only horizontal containment is asserted.
                if (box.X < -2 || box.X + box.Width > width + 2)
                    layouts.Add(new { kind = "horizontal_clip_before_assertion", page, language, width, height,
                        element = Geometry(element), ancestors = Ancestors(element) });
                Require(box.X >= -2 && box.X + box.Width <= width + 2, "settings_horizontal_clip_" + element.Name);
                boxes.Add(new { name = element.Name, bounds = box });
            }
            layouts.Add(new { page, language, width, height, client_width = clientWidth, client_height = clientHeight,
                titlebar = titleBounds, caption = captionBounds, navigation = navigationBounds,
                titlebar_padding = new[] { titleBar.Padding.Left, titleBar.Padding.Top, titleBar.Padding.Right, titleBar.Padding.Bottom },
                titlebar_native_buttons = true, navigation_mode = navigation.PaneDisplayMode.ToString(), navigation_display_mode = navigation.DisplayMode.ToString(), controls = boxes });
            Background();
        }
        async Task Capture(string page, int width, int height)
        {
            string file = Path.Combine(directory, $"settings-{page}-{width}x{height}.png");
            try
            {
                Background();
                var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(Root());
                Require(bitmap.PixelWidth > 0 && bitmap.PixelHeight > 0, "settings_capture_empty");
                var buffer = await bitmap.GetPixelsAsync(); byte[] pixels = new byte[checked((int)buffer.Length)];
                using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
                int visiblePixels = 0;
                for (int offset = 3; offset < pixels.Length; offset += 4) if (pixels[offset] > 0) visiblePixels++;
                Require(visiblePixels > 0, "settings_capture_transparent");
                // CreateFileAsync also works when no previous capture exists.
                var folder = await StorageFolder.GetFolderFromPathAsync(directory);
                var target = await folder.CreateFileAsync(Path.GetFileName(file), CreationCollisionOption.ReplaceExisting);
                using var stream = await target.OpenAsync(FileAccessMode.ReadWrite);
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
                await encoder.FlushAsync();
                captures.Add(new { page, width, height, path = file, status = "captured", pixel_width = bitmap.PixelWidth, pixel_height = bitmap.PixelHeight, visible_pixels = visiblePixels });
                Background();
            }
            catch (Exception error) { captures.Add(new { page, width, height, path = file, status = "unavailable", exception_type = error.GetType().Name, hresult = error.HResult.ToString("X8") }); }
        }
        async Task Settled()
        {
            for (int attempt = 0; attempt < 60; attempt++)
            {
                bool idle = false;
                await OnUi(queue!, () =>
                {
                    Background();
                    idle = !controller!.Busy
                        && typeof(SettingsWindow).GetField("applyingSettings", PrivateInstance)!.GetValue(settings) is false
                        && typeof(SettingsWindow).GetField("loadingCalibration", PrivateInstance)!.GetValue(settings) is false;
                });
                if (idle) { await Task.Delay(50); await OnUi(queue!, () => { Background(); }); return; }
                await Task.Delay(40);
            }
            throw new CheckFailure("settings_apply_did_not_settle");
        }

        try
        {
            Require(queue != null, "dispatcher_unavailable");
            await OnUi(queue!, () =>
            {
                anchor = new Window { Title = "FusionPlay Background Settings Check", Content = new Grid() }; Track(anchor);
                originalBytes = File.Exists(preferencesPath) ? File.ReadAllBytes(preferencesPath) : null;
                originalInvalid = Directory.Exists(store.Data) ? Directory.GetFiles(store.Data, "ui-preferences.json.invalid-*").ToHashSet(StringComparer.OrdinalIgnoreCase) : [];
                capturedPreferences = true;
                CreateController();
                controller!.Preferences.Update(new UiPreferences { ProgressCustomColor = "#6CA9E6" });
                CreateSettings();
            });
            step = "real_lists_and_missing_selections";
            await OnUi(queue!, () => Navigate("receiver"));
            await Task.Delay(700);
            await OnUi(queue!, () => Pass("receiver_list_and_missing_selection", () =>
            {
                Arrange(960, 740);
                var networks = Find<ComboBox>("NetworkInterface");
                Require(fixtureNetworks.All(item => networks.Items.Cast<object>().Any(choice => Key(choice) == item.Name && Label(choice).Contains(item.Name) && Label(choice).Contains(item.Address))), "network_names_or_addresses_missing");
                Require(Key(networks.SelectedItem) == fixtureSettings.InterfaceName && networks.Items.Count >= fixtureNetworks.Length + 2, "missing_network_selection_lost");
            }));
            await OnUi(queue!, () => Navigate("audio"));
            await Task.Delay(700);
            await OnUi(queue!, () => Arrange(960, 740));
            await Capture("audio-before-geometry", 960, 740);
            await OnUi(queue!, () => Pass("output_list_and_calibration_geometry", () =>
            {
                Arrange(960, 740);
                var outputs = Find<ComboBox>("AudioOutput");
                Require(fixtureOutputs.All(item => outputs.Items.Cast<object>().Any(choice => Key(choice) == item.Id && Label(choice).Contains(item.Name))), "output_fixture_missing");
                Require(Key(outputs.SelectedItem) == fixtureSettings.OutputDevice && outputs.Items.Count >= fixtureOutputs.Length + 2, "missing_output_selection_lost");
                var earlier = Find<Button>("CalibrationEarlier"); var range = Find<Slider>("CalibrationRange"); var later = Find<Button>("CalibrationLater");
                var a = Bounds(earlier); var r = Bounds(range); var b = Bounds(later);
                bool AncestorOf(DependencyObject ancestor, DependencyObject child)
                {
                    for (DependencyObject? current = child; current != null; current = VisualTreeHelper.GetParent(current))
                        if (ReferenceEquals(current, ancestor)) return true;
                    return false;
                }
                DependencyObject? common = VisualTreeHelper.GetParent(earlier);
                while (common != null && (!AncestorOf(common, range) || !AncestorOf(common, later))) common = VisualTreeHelper.GetParent(common);
                object Describe(DependencyObject? element)
                {
                    if (element is FrameworkElement view) return new
                    {
                        type = view.GetType().Name, name = view.Name, bounds = Bounds(view),
                        actual_width = view.ActualWidth, actual_height = view.ActualHeight,
                        desired_width = view.DesiredSize.Width, desired_height = view.DesiredSize.Height,
                        margin = new[] { view.Margin.Left, view.Margin.Top, view.Margin.Right, view.Margin.Bottom },
                        vertical_alignment = view.VerticalAlignment.ToString()
                    };
                    return new { type = element?.GetType().Name ?? "none" };
                }
                layouts.Add(new
                {
                    kind = "calibration_geometry_before_assertion", earlier = a, range = r, later = b,
                    earlier_element = Describe(earlier), range_element = Describe(range), later_element = Describe(later),
                    common_parent = Describe(common), earlier_parent = Describe(VisualTreeHelper.GetParent(earlier)),
                    range_parent = Describe(VisualTreeHelper.GetParent(range)), later_parent = Describe(VisualTreeHelper.GetParent(later)),
                    root_width = Root().ActualWidth, root_height = Root().ActualHeight
                });
                Require(a.Width > 0 && r.Width > 0 && b.Width > 0 && a.X + a.Width <= r.X + 2 && r.X + r.Width <= b.X + 2, "calibration_controls_not_in_order");
                Require(Math.Max(a.Y, Math.Max(r.Y, b.Y)) < Math.Min(a.Y + a.Height, Math.Min(r.Y + r.Height, b.Y + b.Height)), "calibration_controls_not_in_one_row");
                Require(range.Minimum == -500 && range.Maximum == 500 && range.StepFrequency == 1 && !range.IsEnabled, "calibration_range_or_fixture_disabled_state_changed");
                Require(!string.IsNullOrWhiteSpace(new ButtonAutomationPeer(earlier).GetName()) && !string.IsNullOrWhiteSpace(new ButtonAutomationPeer(later).GetName()), "calibration_button_accessible_name_missing");
            }));
            await OnUi(queue!, () => Navigate("player"));
            await Task.Delay(700);
            step = "native_toggle_and_segment_bindings";
            await OnUi(queue!, () => Pass(step, () =>
            {
                Require(controller!.Preferences.Value.ShowSettingsButton && controller.Preferences.Value.ShowFullScreenButton
                    && Find<ToggleButton>("ShowSettingsButton").IsChecked == true && Find<ToggleButton>("ShowFullScreenButton").IsChecked == true, "window_button_choices_default_hidden");
                Toggle("ShowSettingsButton"); Toggle("ShowFullScreenButton");
                Require(!controller.Preferences.Value.ShowSettingsButton && !controller.Preferences.Value.ShowFullScreenButton, "window_button_choices_not_saved");
                Require(new UiPreferencesStore(store.Data).Value == controller.Preferences.Value, "window_button_choices_not_persisted");
                Toggle("ShowFullScreenButton");
                Require(!controller.Preferences.Value.ShowSettingsButton && controller.Preferences.Value.ShowFullScreenButton, "window_button_choices_not_independent");
                Toggle("ShowTransport"); Toggle("ShowProgress"); Toggle("ShowPinButton");
                var value = controller!.Preferences.Value;
                Require(!value.ShowTransport && !value.ShowProgress && value.ShowPinButton, "choice_tiles_not_saved");
                Require(new UiPreferencesStore(store.Data).Value == value, "choice_tiles_not_persisted");
                Toggle("ShowProgress");
                SelectSegment("ProgressColorMode", "white"); Require(controller.Preferences.Value.ProgressColorMode == "white", "white_segment_not_saved");
                SelectSegment("ProgressColorMode", "custom");
                Find<ColorPicker>("ProgressCustomColor").Color = global::Windows.UI.Color.FromArgb(255, 241, 126, 145);
                // Deliberately no delay: hiding must not discard a color still awaiting its throttle.
                Toggle("ShowProgress");
                Require(!Visible(Find<FrameworkElement>("ProgressColorGroup")) && controller.Preferences.Value.ProgressCustomColor == "#F17E91", "hidden_progress_lost_color_or_editor_remained");
                Require(new UiPreferencesStore(store.Data).Value.ProgressCustomColor == "#F17E91", "pending_color_not_persisted_when_hiding_progress");
                Toggle("ShowProgress");
                foreach (string mode in new[] { "always", "never", "automatic" })
                {
                    SelectSegment("LyricsDisplayMode", mode);
                    Require(controller.Preferences.Value.LyricsDisplayMode == mode && new UiPreferencesStore(store.Data).Value.LyricsDisplayMode == mode, "lyrics_mode_not_saved");
                }
                SelectSegment("MiniControlsVisibility", "always"); Require(controller.Preferences.Value.AlwaysShowControls, "mini_segment_not_saved");
            }));
            await OnUi(queue!, () => Navigate("general"));
            await Task.Delay(700);
            await OnUi(queue!, () => Pass("language_and_font_disclosure", () =>
            {
                SelectSegment("InterfaceLanguage", "en");
                Require(controller!.Preferences.Value.Language == "en", "language_segment_not_saved");
                Find<Expander>("FontDisclosure").IsExpanded = true; Arrange(960, 740);
            }));
            var fontPanel = Descendants(Root()).OfType<FontSettingsPanel>().FirstOrDefault() ?? throw new CheckFailure("font_panel_missing");
            await fontPanel.FontLoading;
            await OnUi(queue!, () => Pass("native_font_combos_and_rendering_segment", () =>
            {
                Require(fontPanel.FamilySelector.Items.Count > 1 && fontPanel.WeightSelector.Items.Count > 0, "font_lists_unavailable");
                fontPanel.WeightSelector.SelectedIndex = fontPanel.WeightSelector.Items.Count - 1;
                int weight = controller!.Preferences.Value.UiFontWeight;
                Require(weight >= 1 && weight <= 999, "font_weight_not_saved");
                fontPanel.RenderingSelector.SelectedItem = fontPanel.RenderingSelector.Items.Single(item => item.Tag as string == "system");
                Require(controller.Preferences.Value.PlayerTextRendering == "system", "font_rendering_segment_not_saved");
                Require(new UiPreferencesStore(store.Data).Value == controller.Preferences.Value, "font_preferences_not_persisted");
                Find<Expander>("FontDisclosure").IsExpanded = false;
            }));
            step = "global_custom_font_across_all_settings_pages";
            UiPreferences beforeFontFixture = controller!.Preferences.Value;
            var fixtureFamily = NativeTypography.FindFamily("Arial") ?? NativeTypography.FindFamily("Tahoma") ?? NativeTypography.SystemFamily;
            int bodyWeight = FontSelection.NearestWeight(fixtureFamily.Weights, 400);
            int headingWeight = FontSelection.HeadingWeight(fixtureFamily.Weights, bodyWeight);
            await OnUi(queue!, () => controller.Preferences.Update(beforeFontFixture with { UiFontFamily = fixtureFamily.Name, UiFontWeight = bodyWeight }));
            // Both directions revisit already-cached page roots. This catches
            // the original root-only preference-key cache without forcing a
            // global traversal on every receiver poll.
            foreach (var pass in new[] { (Direction: "forward", Pages: pages), (Direction: "reverse", Pages: pages.Reverse().ToArray()) })
            foreach (string page in pass.Pages)
            {
                await OnUi(queue!, () => { Navigate(page); Arrange(960, 740); });
                await Task.Delay(80);
                await OnUi(queue!, () =>
                {
                    Background(); Arrange(960, 740);
                    var title = Find<TextBlock>("SettingsPageTitle_" + page);
                    var description = Find<TextBlock>("SettingsPageDescription_" + page);
                    Require(title.FontFamily.Source == fixtureFamily.Name && title.FontWeight.Weight == headingWeight, "settings_cross_page_heading_font_mismatch_" + page);
                    Require(description.FontFamily.Source == fixtureFamily.Name && description.FontWeight.Weight == bodyWeight, "settings_cross_page_body_font_mismatch_" + page);
                    var icons = Find<NavigationView>("SettingsNavigation").MenuItems.OfType<NavigationViewItem>().Select(item => item.Icon).OfType<FontIcon>().ToArray();
                    Require(icons.Length == pages.Length && icons.All(icon => icon.FontFamily.Source == UiTypography.SymbolFamily.Source), "settings_navigation_icon_font_replaced");
                    typography.Add(new { page, direction = pass.Direction, family = title.FontFamily.Source, heading_weight = title.FontWeight.Weight,
                        body_family = description.FontFamily.Source, body_weight = description.FontWeight.Weight, navigation_icon_fonts_preserved = true });
                });
            }
            await OnUi(queue!, () => { Navigate("audio"); Find<Expander>("ConnectionDiagnostics").IsExpanded = true; Arrange(960, 740); });
            await Task.Delay(80);
            await OnUi(queue!, () => Pass(step, () =>
            {
                Require(Find<TextBlock>("ReceiverDiagnostics").FontFamily.Source == "Cascadia Mono", "settings_diagnostic_monospace_replaced");
                Find<Expander>("ConnectionDiagnostics").IsExpanded = false;
            }));
            await OnUi(queue!, () => Pass("native_infobar_symbol_fonts_preserved", () =>
            {
                // Inspect the real native template, not a synthetic FontIcon:
                // InfoBar's standard severity glyphs are ordinary TextBlocks.
                var info = Find<InfoBar>("AudioError"); info.ApplyTemplate();
                var glyphs = Descendants(info).OfType<TextBlock>().Where(text => text.Name is "StandardIcon" or "IconBackground").ToArray();
                Require(glyphs.Length == 2, "settings_infobar_symbol_parts_missing");
                foreach (var glyph in glyphs)
                {
                    Require(glyph.FontFamily.Source == UiTypography.SymbolFamily.Source, "settings_infobar_symbol_font_replaced_" + glyph.Name);
                    symbolFonts.Add(new { control = info.Name, part = glyph.Name, family = glyph.FontFamily.Source });
                }
                controller!.Preferences.Update(beforeFontFixture);
                Require(glyphs.All(glyph => glyph.FontFamily.Source == UiTypography.SymbolFamily.Source), "settings_infobar_symbol_font_changed_after_preference_restore");
            }));
            step = "reopen_real_settings";
            var expectedPreferences = controller!.Preferences.Value;
            await OnUi(queue!, () => { settings!.Close(); settings = null; });
            await controller.DisposeAsync(); controller = null;
            await OnUi(queue!, () => Pass(step, () =>
            {
                CreateController(); Require(controller!.Preferences.Value == expectedPreferences, "reopened_preferences_not_preserved"); CreateSettings();
                Navigate("player");
                Require(Find<ToggleButton>("ShowTransport").IsChecked == expectedPreferences.ShowTransport && Find<ToggleButton>("ShowProgress").IsChecked == expectedPreferences.ShowProgress && Find<ToggleButton>("ShowPinButton").IsChecked == expectedPreferences.ShowPinButton, "reopened_choice_tiles_not_bound");
                Require(Find<ToggleButton>("ShowSettingsButton").IsChecked == expectedPreferences.ShowSettingsButton
                    && Find<ToggleButton>("ShowFullScreenButton").IsChecked == expectedPreferences.ShowFullScreenButton, "reopened_window_button_choices_not_bound");
            }));
            step = "independent_group_apply_intents";
            await OnUi(queue!, () =>
            {
                FixtureProperty(nameof(ReceiverController.Initialized), true); initializedFixture = true;
                typeof(ReceiverController).GetMethod("Notify", PrivateInstance)!.Invoke(controller, null);
                Navigate("audio"); Select(Find<ComboBox>("AudioOutput"), "fixture-headphones");
                Navigate("receiver"); Find<TextBox>("ReceiverName").Text = "Applied Fixture Receiver";
                Select(Find<ComboBox>("NetworkInterface"), fixtureNetworks[0].Name); Invoke("ApplyReceiver");
            });
            await Settled();
            await OnUi(queue!, () => Pass("receiver_apply_does_not_commit_output_draft", () =>
            {
                Require(controller!.Settings.Name == "Applied Fixture Receiver" && controller.Settings.InterfaceName == fixtureNetworks[0].Name && controller.Settings.OutputDevice == fixtureSettings.OutputDevice, "receiver_apply_committed_another_group");
                Require(!Find<Button>("ApplyReceiver").IsEnabled, "clean_receiver_apply_not_disabled");
                Find<TextBox>("ReceiverName").Text = "Unapplied Fixture Receiver"; Select(Find<ComboBox>("NetworkInterface"), fixtureNetworks[1].Name);
                Navigate("audio"); Require(Key(Find<ComboBox>("AudioOutput").SelectedItem) == "fixture-headphones", "output_draft_lost_after_receiver_apply"); Invoke("ApplyOutput");
            }));
            await Settled();
            await OnUi(queue!, () => Pass("output_apply_does_not_commit_receiver_draft", () =>
            {
                Require(controller!.Settings.OutputDevice == "fixture-headphones" && controller.Settings.Name == "Applied Fixture Receiver" && controller.Settings.InterfaceName == fixtureNetworks[0].Name, "output_apply_committed_another_group");
                Require(!Find<Button>("ApplyOutput").IsEnabled, "clean_output_apply_not_disabled");
                Require(!Find<Slider>("CalibrationRange").IsEnabled, "calibration_enabled_without_native_endpoint");
                Navigate("receiver"); Require(Find<TextBox>("ReceiverName").Text == "Unapplied Fixture Receiver" && Key(Find<ComboBox>("NetworkInterface").SelectedItem) == fixtureNetworks[1].Name, "receiver_draft_lost_after_output_apply");
            }));
            step = "page_layouts_and_capture";
            foreach (string language in new[] { "zh-Hans", "en" })
            {
                await OnUi(queue!, () => { Navigate("general"); SelectSegment("InterfaceLanguage", language); });
                foreach (var size in new[] { (Width: 960, Height: 740), (Width: 620, Height: 520) })
                foreach (string page in pages)
                {
                    await OnUi(queue!, () =>
                    {
                        // Let the hidden native host process its resize before
                        // the later measure/assertion round observes XamlRoot.
                        WindowSizing.ResizeContent(settings!, size.Width, size.Height);
                        Navigate(page);
                    });
                    await Task.Delay(700);
                    await OnUi(queue!, () => Inspect(page, size.Width, size.Height, language));
                    if (language == "zh-Hans") await Capture(page, size.Width, size.Height);
                }
            }
            Background(); Require(UnhandledErrors.Count == 0, "settings_unhandled_xaml_errors");
            status = "passed"; step = "complete";
        }
        catch (Exception error)
        {
            status = "failed"; failure = error is CheckFailure checkedError ? checkedError.Message : "settings_check_exception";
            exception = error.GetType().Name; hresult = error.HResult.ToString("X8");
        }
        finally
        {
            try { if (settings != null) await OnUi(queue!, () => { try { Background(); } finally { settings.Close(); settings = null; } }); }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            try { if (controller != null) { await controller.DisposeAsync(); controller = null; } }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            try
            {
                if (capturedPreferences)
                {
                    if (originalBytes != null) { Directory.CreateDirectory(store.Data); File.WriteAllBytes(preferencesPath, originalBytes); }
                    else if (File.Exists(preferencesPath)) File.Delete(preferencesPath);
                    if (Directory.Exists(store.Data)) foreach (string file in Directory.GetFiles(store.Data, "ui-preferences.json.invalid-*"))
                        if (!originalInvalid.Contains(file)) File.Delete(file);
                    preferencesRestored = originalBytes == null ? !File.Exists(preferencesPath) : File.ReadAllBytes(preferencesPath).AsSpan().SequenceEqual(originalBytes);
                    Require(preferencesRestored, "settings_preferences_restore_mismatch");
                }
                L.Language = originalLanguage;
            }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            void Finish()
            {
                try { Background(); Require(UnhandledErrors.Count == 0, "settings_unhandled_xaml_errors"); }
                catch (Exception error) { status = "failed"; failure = error.Message; }
                if (cleanupErrors.Count > 0) { status = "failed"; failure = "settings_cleanup_failed"; }
                try
                {
                    File.WriteAllText(Path.Combine(directory, "settings-layout-check.json"), JsonSerializer.Serialize(new
                    {
                        status, step, failure_code = failure, exception_type = exception, hresult, cases, layout_samples = layouts, typography_samples = typography, symbol_font_samples = symbolFonts, captures,
                        window_remained_hidden = hidden, foreground_unchanged = focus, foreground_not_taken = foregroundNotTaken, preferences_restored = preferencesRestored,
                        controller_created = controllerCreated, initialized_flag_is_fixture = initializedFixture,
                        receiver_initialize_method_called = false, native_receiver_created = false, receiver_polling_started = false,
                        system_media_session_created = false, single_instance_notification_sent = false,
                        unhandled_errors = UnhandledErrors, cleanup_errors = cleanupErrors,
                        scope = "real_hidden_settings_controls_layout_and_group_apply_intents; native_receiver_persistence_and_failure_and_calibration_success_not_tested; capture_availability_reported_separately"
                    }, new JsonSerializerOptions { WriteIndented = true }));
                }
                finally { anchor?.Close(); }
            }
            if (queue == null || queue.HasThreadAccess) Finish(); else await OnUi(queue, Finish);
        }
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(root, index))) yield return child;
    }
    private static Task OnUi(DispatcherQueue queue, Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } })) completion.TrySetException(new CheckFailure("settings_dispatcher_enqueue_failed"));
        return completion.Task;
    }
}
