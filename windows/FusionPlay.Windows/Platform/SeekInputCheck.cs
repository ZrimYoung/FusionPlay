using System.Runtime.InteropServices;
using System.Reflection;
using System.Text.Json;
using FusionPlay.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Rectangle = Microsoft.UI.Xaml.Shapes.Rectangle;
using Windows.Graphics;
using VirtualKey = Windows.System.VirtualKey;

namespace FusionPlay.Windows.Platform;

/// <summary>Exercises seek targets and the real player without creating a native receiver or showing a window.</summary>
internal static class SeekInputCheck
{
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out ClientRect rect);
    [StructLayout(LayoutKind.Sequential)] private struct ClientRect { public int Left, Top, Right, Bottom; }
    private sealed class CheckFailure(string code) : Exception { public string Code { get; } = code; }

    public static async Task Run(string outputFile)
    {
        var queue = DispatcherQueue.GetForCurrentThread();
        nint foreground = GetForegroundWindow(), hwnd = 0;
        Window? window = null;
        ISquareWindow? sizing = null;
        MainWindow? main = null;
        ReceiverController? controller = null;
        PlaybackTimeline? mainTimeline = null;
        MethodInfo? acceptSource = null;
        ulong mainRevision = 0;
        UiPreferences? originalPreferences = null;
        nint mainHwnd = 0;
        string preferencesPath = Path.Combine(new PortableStore(AppContext.BaseDirectory).Data, "ui-preferences.json");
        byte[]? originalPreferencesFile = null;
        bool preferencesCaptured = false, controllerCreated = false, initializedFlagIsFixture = false;
        string status = "failed", step = "create_hidden_window", failure = "", exceptionType = "", hresult = "";
        string fixtureXamlError = "";
        bool remainedHidden = true, foregroundUnchanged = true;
        var cases = new List<string>();
        var mainSamples = new List<object>();
        var indicatorSamples = new List<object>();
        var requests = new List<SeekRequest>();
        var initial = new ReceiverSnapshot { Phase = ReceiverPhase.Playing, ControlsAvailable = true, TrackId = "fixture-track", Title = "Fixture", DurationMs = 200_000, PositionMs = 50_000 };
        var snapshot = initial;
        ProgressSeekButton? target = null;
        ProgressBar? bar = null;
        Grid? root = null;
        void Require(bool value, string code) { if (!value) throw new CheckFailure(code); }
        void Background()
        {
            remainedHidden &= hwnd == 0 || !IsWindowVisible(hwnd);
            remainedHidden &= mainHwnd == 0 || !IsWindowVisible(mainHwnd);
            foregroundUnchanged &= GetForegroundWindow() == foreground;
            Require(remainedHidden, "window_became_visible"); Require(foregroundUnchanged, "foreground_changed");
        }
        void Pass(string name, Action check) { Background(); check(); Background(); cases.Add(name); }
        void NoRequest(string name, Action check) => Pass(name, () => { int count = requests.Count; check(); Require(requests.Count == count, name); });
        try
        {
            Require(queue != null, "dispatcher_unavailable");
            await OnUi(queue!, () =>
            {
                Background();
                bar = new ProgressBar { Minimum = 0, Maximum = 100, Value = 25, Height = 3, IsHitTestVisible = false };
                target = new ProgressSeekButton { Width = 300, Height = 24, MinHeight = 24, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(24), Content = bar, Snapshot = () => snapshot };
                target.SeekRequested += requests.Add;
                root = new Grid(); root.Children.Add(target);
                window = new Window { Title = "FusionPlay Background Seek Check", Content = root };
                hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
                window.AppWindow.IsShownInSwitchers = false;
                Require(window.AppWindow.Presenter is OverlappedPresenter, "overlapped_presenter_unavailable");
                var presenter = (OverlappedPresenter)window.AppWindow.Presenter;
                presenter.SetBorderAndTitleBar(false, false); presenter.IsResizable = true; presenter.IsMaximizable = false; presenter.IsMinimizable = false;
                WindowSizing.Apply(window, 420, 420, 260, 260);
                sizing = WindowSizing.FixedSquare(window, _ => { });
                WindowSizing.ResizeContent(window, 420, 420);
                root.Measure(new global::Windows.Foundation.Size(420, 420));
                root.Arrange(new global::Windows.Foundation.Rect(0, 0, 420, 420)); root.UpdateLayout();
                Background();
            });
            await OnUi(queue!, () => { });
            step = "seek_target_and_snapshot_guards";
            await OnUi(queue!, () =>
            {
                Pass("native_target_24_dip_bar_3_dip", () => Require(target!.ActualHeight >= 24 && bar!.Height == 3, "seek_target_dimensions"));
                NoRequest("release_without_press_rejected", () => Require(!target!.CommitPointerClick(), "unexpected_click"));
                Pass("left_mouse_and_touch_only", () =>
                {
                    Require(ProgressSeekButton.AllowsPointer(PointerDeviceType.Mouse, true, false, false), "left_mouse_rejected");
                    Require(ProgressSeekButton.AllowsPointer(PointerDeviceType.Touch, false, false, false), "touch_rejected");
                    Require(!ProgressSeekButton.AllowsPointer(PointerDeviceType.Mouse, false, true, false), "right_mouse_allowed");
                    Require(!ProgressSeekButton.AllowsPointer(PointerDeviceType.Mouse, false, false, true), "middle_mouse_allowed");
                    Require(!ProgressSeekButton.AllowsPointer(PointerDeviceType.Pen, true, false, false), "pen_allowed");
                });
                Pass("captured_point_single_commit", () =>
                {
                    target!.BeginPointer(1, 75, 300, true);
                    snapshot = initial with { PositionMs = 60_000 };
                    int before = requests.Count;
                    Require(target.CommitPointerClick() && requests.Count == before + 1, "click_not_dispatched_once");
                    Require(requests[^1] == new SeekRequest(50_000, initial.TrackId, initial.Title), "captured_point_mismatch");
                    Require(!target.CommitPointerClick() && requests.Count == before + 1, "duplicate_click");
                    Require(snapshot.PositionMs == 60_000 && bar!.Value == 25, "local_progress_was_fabricated");
                });
                foreach (var invalid in new[]
                {
                    initial with { TrackId = "other-track" }, initial with { Title = "Other" },
                    initial with { Phase = ReceiverPhase.Ready, ControlsAvailable = false },
                    initial with { DurationMs = null }, initial with { PositionMs = null }, initial with { ControlsAvailable = false }
                })
                {
                    NoRequest("changed_or_invalid_snapshot_rejected", () =>
                    {
                        snapshot = initial; target!.BeginPointer(2, 150, 300, true); snapshot = invalid;
                        target.RefreshState(); Require(!target.CommitPointerClick(), "stale_request_dispatched");
                    });
                }
                snapshot = initial;
                NoRequest("disabled_target_rejected", () => { target!.BeginPointer(3, 150, 300, true); target.IsEnabled = false; Require(!target.CommitPointerClick(), "disabled_request_dispatched"); target.IsEnabled = true; });
                NoRequest("canceled_pointer_rejected", () => { target!.BeginPointer(4, 150, 300, true); target.CancelPointer(); Require(!target.CommitPointerClick(), "canceled_request_dispatched"); });
                NoRequest("unsupported_pointer_rejected", () => { target!.BeginPointer(5, 150, 300, false); Require(!target.CommitPointerClick(), "unsupported_request_dispatched"); });
                NoRequest("multiple_pointers_canceled", () => { target!.BeginPointer(6, 150, 300, true); target.BeginPointer(7, 50, 300, true); Require(!target.CommitPointerClick(), "multiple_pointer_request_dispatched"); });
                Pass("keyboard_seek_from_source_timeline", () =>
                {
                    foreach (var (key, position) in new[] { (VirtualKey.Left, 40_000UL), (VirtualKey.Right, 60_000UL), (VirtualKey.Home, 0UL), (VirtualKey.End, 200_000UL) })
                    { Require(target!.SeekFromKey(key) && requests[^1].PositionMs == position, "keyboard_target_mismatch"); }
                    Require(snapshot.PositionMs == 50_000 && bar!.Value == 25, "keyboard_changed_local_progress");
                });
                Pass("automation_range_requests_source_seek", () =>
                {
                    var peer = FrameworkElementAutomationPeer.CreatePeerForElement(target!);
                    Require(peer?.GetPattern(PatternInterface.RangeValue) is IRangeValueProvider, "range_pattern_missing");
                    var range = (IRangeValueProvider)peer!.GetPattern(PatternInterface.RangeValue);
                    Require(range.Minimum == 0 && range.Maximum == 100 && range.Value == 25 && !range.IsReadOnly, "range_values_incorrect");
                    range.SetValue(75);
                    Require(requests[^1].PositionMs == 150_000 && range.Value == 25 && bar!.Value == 25, "range_seek_or_progress_incorrect");
                    target!.IsEnabled = false; Require(range.IsReadOnly, "disabled_range_writable"); target.IsEnabled = true;
                });
                Pass("presentation_position_drives_keyboard_and_accessibility", () =>
                {
                    target!.Snapshot = () => snapshot with { PositionMs = 120_000 };
                    try
                    {
                        Require(target.SeekFromKey(VirtualKey.Right) && requests[^1].PositionMs == 130_000, "keyboard_ignored_presentation_position");
                        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(target);
                        Require(peer?.GetPattern(PatternInterface.RangeValue) is IRangeValueProvider, "presentation_range_pattern_missing");
                        var range = (IRangeValueProvider)peer!.GetPattern(PatternInterface.RangeValue);
                        Require(range.Value == 60 && snapshot.PositionMs == 50_000, "presentation_changed_source_or_accessibility_mismatch");
                        target.BeginPointer(9, 150, 300, true); target.CancelPointer(); target.IsEnabled = false;
                        Require(!target.CommitPointerClick(), "hidden_progress_committed_request");
                    }
                    finally { target.Snapshot = () => snapshot; target.IsEnabled = true; }
                });
                Pass("progress_visual_color_preserved", () =>
                {
                    var white = new SolidColorBrush(Microsoft.UI.Colors.White); bar!.Foreground = white;
                    target!.BeginPointer(8, 150, 300, true); target.CommitPointerClick(); Require(ReferenceEquals(bar.Foreground, white), "white_color_changed");
                    var custom = new SolidColorBrush(Microsoft.UI.Colors.CornflowerBlue); bar.Foreground = custom;
                    target.SeekFromKey(VirtualKey.Right); Require(ReferenceEquals(bar.Foreground, custom), "custom_color_changed");
                    bar.ClearValue(Control.ForegroundProperty);
                    Require(bar.ReadLocalValue(Control.ForegroundProperty) == DependencyProperty.UnsetValue, "system_color_not_restored");
                });
                step = "sdk_seek_passthrough_registration";
                double scale = Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
                var bounds = target!.TransformToVisual(root).TransformBounds(new global::Windows.Foundation.Rect(0, 0, target.ActualWidth, target.ActualHeight));
                int x = (int)Math.Floor(bounds.X * scale), y = (int)Math.Floor(bounds.Y * scale);
                var hole = new RectInt32(x, y, (int)Math.Ceiling(bounds.Right * scale) - x, (int)Math.Ceiling(bounds.Bottom * scale) - y);
                sizing!.UpdateInputRegions([hole]);
                var input = InputNonClientPointerSource.GetForWindowId(window!.AppWindow.Id);
                Pass("sdk_actual_seek_passthrough_not_caption", () =>
                {
                    Require(input.GetRegionRects(NonClientRegionKind.Passthrough).Any(rect => Contains(rect, hole)), "seek_passthrough_missing");
                    Require(input.GetRegionRects(NonClientRegionKind.Caption).All(rect => !Overlaps(rect, hole)), "seek_region_is_draggable");
                });
                Pass("hidden_seek_has_no_passthrough", () =>
                {
                    target.Visibility = Visibility.Collapsed; sizing.UpdateInputRegions([]);
                    Require(input.GetRegionRects(NonClientRegionKind.Passthrough).Length == 0, "hidden_seek_passthrough_remains");
                });
            });
            step = "create_real_hidden_main_with_fixture_controller";
            await OnUi(queue!, () =>
            {
                Background();
                originalPreferencesFile = File.Exists(preferencesPath) ? File.ReadAllBytes(preferencesPath) : null;
                preferencesCaptured = true;
                controller = new ReceiverController(queue!); controllerCreated = true;
                originalPreferences = controller.Preferences.Value;
                controller.Preferences.Update(originalPreferences with { AlwaysShowControls = true, ShowProgress = true, Pinned = false, ShowPinButton = false });
                var initialized = typeof(ReceiverController).GetProperty(nameof(ReceiverController.Initialized));
                Require(initialized?.GetSetMethod(nonPublic: true) != null, "initialized_fixture_setter_missing");
                initialized!.SetValue(controller, true); initializedFlagIsFixture = true;
                // This flag only enables the real UI. No Initialize/Start/native
                // construction or SeekRequested/Commit invocation occurs here.
                acceptSource = typeof(ReceiverController).GetMethod("Accept", BindingFlags.Instance | BindingFlags.NonPublic, null, [typeof(PollResult)], null);
                Require(acceptSource != null, "source_fixture_accept_missing");
                mainTimeline = typeof(ReceiverController).GetField("timeline", BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(controller) as PlaybackTimeline;
                Require(mainTimeline != null, "presentation_timeline_fixture_missing");
                AcceptMain(initial);
                main = new MainWindow(controller, () => { }) { AllowClose = true };
                mainHwnd = WinRT.Interop.WindowNative.GetWindowHandle(main);
                main.AppWindow.IsShownInSwitchers = false;
                Background();
            });
            foreach (var (width, height, mode) in new[] { (420.0, 420.0, "compact"), (820.0, 480.0, "expanded") })
            {
                step = "resize_real_hidden_main_" + mode;
                await OnUi(queue!, () => { Background(); AcceptMain(initial); WindowSizing.ResizeContent(main!, width, height); });
                await Settle(queue!);
                foreach (string colorMode in new[] { "white", "custom", "system" })
                {
                    step = "inspect_real_main_progress_visible_" + mode + "_" + colorMode;
                    await OnUi(queue!, () =>
                    {
                        controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = true, ProgressColorMode = colorMode, ProgressCustomColor = "#3689EC" });
                        ArrangeMain(width, height);
                    });
                    await Settle(queue!);
                    await WaitForProgress(visible: true);
                    await OnUi(queue!, () => Pass("real_main_progress_visible_" + mode + "_" + colorMode, () =>
                    {
                        ArrangeMain(width, height);
                        var playerRoot = (FrameworkElement)main!.Content;
                        var active = Find<ProgressSeekButton>(mode == "compact" ? "MiniProgressSeek" : "ProgressSeek");
                        Require(Find<FrameworkElement>(mode == "compact" ? "MiniRoot" : "ExpandedRoot").Visibility == Visibility.Visible, "real_main_mode_not_applied");
                        Require(Find<FrameworkElement>("ProgressPanel").Visibility == Visibility.Visible && Find<FrameworkElement>("MiniProgressPanel").Visibility == Visibility.Visible, "real_main_progress_not_visible");
                        Require(active.IsEnabled && active.ActualHeight >= 24, "real_main_seek_target_unavailable");
                        foreach (var progressBar in new[] { Find<ProgressBar>("Progress"), Find<ProgressBar>("MiniProgress") })
                        {
                            Require(progressBar.Height == 3 && progressBar.Value == 25, "real_main_progress_visual_changed");
                            if (colorMode == "system") Require(progressBar.ReadLocalValue(Control.ForegroundProperty) == DependencyProperty.UnsetValue, "real_main_system_color_not_restored");
                            else
                            {
                                var expected = colorMode == "white" ? Microsoft.UI.Colors.White : global::Windows.UI.Color.FromArgb(255, 0x36, 0x89, 0xEC);
                                Require(progressBar.Foreground is SolidColorBrush brush && brush.Color.Equals(expected), "real_main_progress_color_changed");
                            }
                        }
                        RectInt32 region = MainRegion(active, playerRoot);
                        var input = InputNonClientPointerSource.GetForWindowId(main.AppWindow.Id);
                        var holes = input.GetRegionRects(NonClientRegionKind.Passthrough);
                        Require(holes.Any(rect => Contains(rect, region)), "real_main_seek_passthrough_missing");
                        Require(input.GetRegionRects(NonClientRegionKind.Caption).All(rect => !Overlaps(rect, region)), "real_main_progress_is_caption");
                        mainSamples.Add(new { mode, width, height, show_progress = true, color_mode = colorMode, bar_height_dips = 3, target_height_dips = active.ActualHeight, seek_region = new[] { region.X, region.Y, region.Width, region.Height }, registered_passthrough_count = holes.Length });
                    }));
                }
                step = "real_main_indicator_left_anchor_" + mode;
                foreach (var (position, direction) in new[]
                {
                    (150_000UL, "forward"), (40_000UL, "backward"), (40_000UL, "repeat_backward_report"),
                    (120_500UL, "forward_again"), (25_000UL, "backward_again"), (25_000UL, "repeat_again")
                })
                {
                    await OnUi(queue!, () => { Background(); AcceptMain(initial with { PositionMs = position }); ArrangeMain(width, height); });
                    int sample = 0;
                    foreach (int delay in new[] { 0, 40, 60, 180 })
                    {
                        if (delay > 0) await Task.Delay(delay);
                        int capturedSample = sample++;
                        await OnUi(queue!, () => InspectIndicator(mode, width, height, position, direction, capturedSample));
                    }
                    await OnUi(queue!, () => Pass("real_main_indicator_left_fixed_" + mode + "_" + direction, () =>
                        Require(controller!.State.PositionMs == position && controller.DisplayPositionMs == position, "indicator_fixture_changed_position")));
                }
                ProgressBar? themeBar = null;
                ElementTheme originalTheme = ElementTheme.Default;
                await OnUi(queue!, () =>
                {
                    themeBar = Find<ProgressBar>(mode == "compact" ? "MiniProgress" : "Progress");
                    originalTheme = themeBar.RequestedTheme;
                    Require(themeBar.Template != null && themeBar.ReadLocalValue(Control.TemplateProperty) == DependencyProperty.UnsetValue, "player_progress_template_not_native_theme");
                });
                // Exercise the real theme source without replacing the native
                // template with a synthetic one. Theme/layout work gets its own
                // dispatcher turns before measuring the existing indicator.
                try
                {
                    foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
                    {
                        step = "real_main_indicator_template_theme_refresh_" + mode + "_" + theme;
                        await OnUi(queue!, () => { themeBar!.RequestedTheme = theme; themeBar.ApplyTemplate(); ArrangeMain(width, height); });
                        await Settle(queue!);
                        await OnUi(queue!, () => InspectIndicator(mode, width, height, 25_000, "native_theme_" + theme, 0));
                    }
                }
                finally
                {
                    await OnUi(queue!, () => { themeBar!.RequestedTheme = originalTheme; themeBar.ApplyTemplate(); ArrangeMain(width, height); });
                }
                await Settle(queue!);
                await OnUi(queue!, () => Pass("real_main_indicator_native_theme_refresh_is_safe_" + mode, () =>
                {
                    Require(themeBar!.ReadLocalValue(Control.TemplateProperty) == DependencyProperty.UnsetValue, "player_progress_theme_template_not_restored");
                    InspectIndicator(mode, width, height, 25_000, "native_theme_restored", 0);
                }));
                await OnUi(queue!, () => AcceptMain(initial));
                step = "real_main_seek_presentation_feedback_" + mode;
                await OnUi(queue!, () =>
                {
                    Pass("real_main_pending_seek_updates_actual_progress_" + mode, () =>
                    {
                        Require(mainTimeline!.Begin(new SeekRequest(120_000, initial.TrackId, initial.Title)) != 0, "real_main_pending_seek_fixture_rejected");
                        main!.RefreshAppearance(); ArrangeMain(width, height);
                        Require(controller!.State.PositionMs == 50_000 && controller.DisplayPositionMs == 120_000, "real_main_pending_seek_changed_source");
                        VerifyMainPosition(60, "2:00");
                        Require(Find<ProgressSeekButton>(mode == "compact" ? "MiniProgressSeek" : "ProgressSeek").Snapshot?.Invoke().PositionMs == 120_000, "real_main_seek_snapshot_not_presentation");
                        mainSamples.Add(new { mode, phase = "pending_seek", source_position_ms = controller.State.PositionMs, display_position_ms = controller.DisplayPositionMs, bar_value = Find<ProgressBar>(mode == "compact" ? "MiniProgress" : "Progress").Value, time_text = Find<PlayerText>(mode == "compact" ? "MiniPosition" : "PositionText").Text });
                    });
                    Pass("real_main_source_report_reconciles_seek_feedback_" + mode, () =>
                    {
                        AcceptMain(initial with { PositionMs = 120_500 }); ArrangeMain(width, height);
                        Require(!mainTimeline!.IsPending && controller!.State.PositionMs == 120_500 && controller.DisplayPositionMs == 120_500, "real_main_source_report_not_reconciled");
                        VerifyMainPosition(60.25, "2:00");
                    });
                    Pass("real_main_stale_revision_cannot_rewind_progress_" + mode, () =>
                    {
                        Require(acceptSource!.Invoke(controller, [new PollResult(mainRevision - 1, initial)]) is false, "real_main_old_revision_accepted");
                        main!.RefreshAppearance(); ArrangeMain(width, height);
                        Require(controller!.State.PositionMs == 120_500 && controller.DisplayPositionMs == 120_500, "real_main_stale_revision_rewound_source");
                        VerifyMainPosition(60.25, "2:00");
                        mainSamples.Add(new { mode, phase = "source_report_and_stale_rejected", source_revision = mainRevision, source_position_ms = controller.State.PositionMs, display_position_ms = controller.DisplayPositionMs, bar_value = Find<ProgressBar>(mode == "compact" ? "MiniProgress" : "Progress").Value, time_text = Find<PlayerText>(mode == "compact" ? "MiniPosition" : "PositionText").Text });
                    });
                });
                RectInt32 oldProgressRegion = default;
                step = "hide_real_main_progress_" + mode;
                await OnUi(queue!, () =>
                {
                    ArrangeMain(width, height);
                    var active = Find<ProgressSeekButton>(mode == "compact" ? "MiniProgressSeek" : "ProgressSeek");
                    oldProgressRegion = MainRegion(active, (FrameworkElement)main!.Content);
                    active.BeginPointer(20, active.ActualWidth / 2, active.ActualWidth, true);
                    Require(PendingRequest(active) != null, "real_main_pointer_fixture_not_captured");
                    controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = false });
                    // Check the synchronous preference notification before layout
                    // can unload controls and independently cancel the gesture.
                    Require(PendingRequest(active) == null && !active.IsEnabled, "real_main_hidden_gesture_not_canceled_immediately");
                    Pass("real_main_hide_immediately_removes_seek_passthrough_" + mode, () =>
                    {
                        var holes = InputNonClientPointerSource.GetForWindowId(main!.AppWindow.Id).GetRegionRects(NonClientRegionKind.Passthrough);
                        Require(holes.All(rect => !Contains(rect, oldProgressRegion)), "real_main_fading_progress_hole_remains");
                    });
                    ArrangeMain(width, height);
                });
                await WaitForProgress(visible: false);
                await OnUi(queue!, () => Pass("real_main_progress_hidden_" + mode, () =>
                {
                    ArrangeMain(width, height);
                    Require(Find<FrameworkElement>("ProgressPanel").Visibility == Visibility.Collapsed && Find<FrameworkElement>("MiniProgressPanel").Visibility == Visibility.Collapsed, "real_main_progress_group_not_collapsed");
                    foreach (var seek in new[] { Find<ProgressSeekButton>("ProgressSeek"), Find<ProgressSeekButton>("MiniProgressSeek") })
                        Require(!seek.IsEnabled && PendingRequest(seek) == null, "real_main_hidden_seek_still_available");
                    var holes = InputNonClientPointerSource.GetForWindowId(main!.AppWindow.Id).GetRegionRects(NonClientRegionKind.Passthrough);
                    // Transport can move into the old progress strip. It must not
                    // preserve a full-width hole that covered the old seek target.
                    Require(holes.All(rect => !Contains(rect, oldProgressRegion)), "real_main_hidden_progress_hole_remains");
                    mainSamples.Add(new { mode, width, height, show_progress = false, old_seek_region = new[] { oldProgressRegion.X, oldProgressRegion.Y, oldProgressRegion.Width, oldProgressRegion.Height }, registered_passthrough_count = holes.Length });
                }));
                step = "reverse_real_main_progress_animation_" + mode;
                await OnUi(queue!, () => { controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = true }); ArrangeMain(width, height); });
                await Task.Delay(50);
                await OnUi(queue!, () =>
                {
                    ArrangeMain(width, height);
                    Pass("real_main_expanding_progress_input_is_clipped_" + mode, () =>
                    {
                        var panel = Find<FrameworkElement>(mode == "compact" ? "MiniProgressPanel" : "ProgressPanel");
                        var active = Find<ProgressSeekButton>(mode == "compact" ? "MiniProgressSeek" : "ProgressSeek");
                        Require(panel.Clip is RectangleGeometry clip && Math.Abs(clip.Rect.Height - panel.ActualHeight) < .01 && Math.Abs(clip.Rect.Width - panel.ActualWidth) < .01, "real_main_animated_progress_not_clipped");
                        var full = MainRegion(active, (FrameworkElement)main!.Content);
                        var viewport = MainRegion(panel, (FrameworkElement)main.Content);
                        var holes = InputNonClientPointerSource.GetForWindowId(main.AppWindow.Id).GetRegionRects(NonClientRegionKind.Passthrough);
                        foreach (var hole in holes.Where(rect => Overlaps(rect, full) && rect.Width >= full.Width))
                            Require(Contains(viewport, Intersect(hole, full)), "real_main_expanding_seek_hole_exceeds_viewport");
                        mainSamples.Add(new { mode, phase = "progress_expansion_clip", mid_animation_observed = !double.IsNaN(panel.Height), viewport_region = new[] { viewport.X, viewport.Y, viewport.Width, viewport.Height }, full_target_region = new[] { full.X, full.Y, full.Width, full.Height } });
                    });
                    controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = false }); ArrangeMain(width, height);
                });
                await Task.Delay(50);
                await OnUi(queue!, () => { controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = true }); ArrangeMain(width, height); });
                await WaitForProgress(visible: true);
                await OnUi(queue!, () => Pass("real_main_rapid_progress_reversal_finishes_visible_" + mode, () =>
                {
                    ArrangeMain(width, height);
                    Require(Find<ProgressSeekButton>(mode == "compact" ? "MiniProgressSeek" : "ProgressSeek").IsEnabled, "real_main_reversed_progress_disabled");
                    var active = Find<ProgressSeekButton>(mode == "compact" ? "MiniProgressSeek" : "ProgressSeek");
                    var region = MainRegion(active, (FrameworkElement)main!.Content);
                    Require(InputNonClientPointerSource.GetForWindowId(main.AppWindow.Id).GetRegionRects(NonClientRegionKind.Passthrough).Any(rect => Contains(rect, region)), "real_main_reversed_progress_hole_missing");
                }));
                await OnUi(queue!, () => { controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = false }); ArrangeMain(width, height); });
                await WaitForProgress(visible: false);
                await OnUi(queue!, () => Pass("real_main_reversed_progress_finishes_collapsed_" + mode, () =>
                    Require(Find<FrameworkElement>("ProgressPanel").Visibility == Visibility.Collapsed && Find<FrameworkElement>("MiniProgressPanel").Visibility == Visibility.Collapsed, "real_main_reversed_progress_not_collapsed")));
            }
            step = "real_main_progress_animation_mode_switch";
            await OnUi(queue!, () => { controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = true }); ArrangeMain(820, 480); });
            await WaitForProgress(visible: true);
            await OnUi(queue!, () => { controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = false }); WindowSizing.ResizeContent(main!, 420, 420); });
            await Settle(queue!);
            await OnUi(queue!, () => ArrangeMain(420, 420));
            await WaitForProgress(visible: false);
            await OnUi(queue!, () => Pass("real_main_mode_switch_during_progress_hide_snaps_collapsed", () =>
                Require(Find<FrameworkElement>("MiniRoot").Visibility == Visibility.Visible && Find<FrameworkElement>("ProgressPanel").Visibility == Visibility.Collapsed && Find<FrameworkElement>("MiniProgressPanel").Visibility == Visibility.Collapsed, "real_main_mode_switch_retained_old_hide")));
            await OnUi(queue!, () => { controller!.Preferences.Update(controller.Preferences.Value with { ShowProgress = true }); WindowSizing.ResizeContent(main!, 820, 480); });
            await Settle(queue!);
            await OnUi(queue!, () => ArrangeMain(820, 480));
            await WaitForProgress(visible: true);
            await OnUi(queue!, () => Pass("real_main_mode_switch_during_progress_show_snaps_visible", () =>
                Require(Find<FrameworkElement>("ExpandedRoot").Visibility == Visibility.Visible && Find<ProgressSeekButton>("ProgressSeek").IsEnabled, "real_main_mode_switch_retained_old_show")));
            await OnUi(queue!, () => Pass("plain_progress_theme_keeps_native_reposition_transition", () =>
            {
                bar!.ApplyTemplate();
                var templateRoot = ProgressTemplateRoot(bar);
                Require(VisualStateManager.GetVisualStateGroups(templateRoot).SelectMany(group => group.Transitions)
                    .Any(transition => HasIndicatorReposition(transition.Storyboard)), "player_progress_changed_global_theme");
            }));
            status = "passed";
        }
        catch (Exception error)
        {
            failure = error is CheckFailure check ? check.Code : "seek_check_failed";
            exceptionType = error.GetType().Name; hresult = error.HResult.ToString("X8");
            if (error.GetType().Name == "XamlParseException" && step.StartsWith("real_main_indicator_template_", StringComparison.Ordinal))
                fixtureXamlError = error.Message.Length <= 768 ? error.Message : error.Message[..768];
        }
        finally
        {
            if (controller != null)
            {
                try
                {
                    await OnUi(queue!, () =>
                    {
                        Background();
                        try { if (originalPreferences != null) controller.Preferences.Update(originalPreferences); }
                        finally
                        {
                            if (preferencesCaptured)
                            {
                                if (originalPreferencesFile != null) File.WriteAllBytes(preferencesPath, originalPreferencesFile);
                                else if (File.Exists(preferencesPath)) File.Delete(preferencesPath);
                            }
                        }
                    });
                }
                catch (Exception error) { CleanupFailure(error); }
                try { await controller.DisposeAsync(); }
                catch (Exception error) { CleanupFailure(error); }
                try { await OnUi(queue!, () => { Background(); main?.Close(); main = null; mainHwnd = 0; Background(); }); }
                catch (Exception error) { CleanupFailure(error); }
            }
            // Write while the only hidden window is alive: closing it first can
            // end the WinUI dispatcher before a continuation writes the report.
            void Finish()
            {
                try { Background(); sizing?.Dispose(); Background(); }
                catch (Exception error) { status = "failed"; failure = "hidden_cleanup_failed"; exceptionType = error.GetType().Name; hresult = error.HResult.ToString("X8"); }
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputFile))!);
                    File.WriteAllText(outputFile, JsonSerializer.Serialize(new
                    {
                        status, step, failure_code = failure, exception_type = exceptionType, hresult, fixture_xaml_error = fixtureXamlError,
                        window_remained_hidden = remainedHidden, foreground_unchanged = foregroundUnchanged,
                        receiver_created = false, native_receiver_created = false, controller_created = controllerCreated,
                        initialized_flag_is_fixture = initializedFlagIsFixture, receiver_initialize_method_called = false,
                        shell_media_session_created = false, dispatched_fixture_requests = requests.Count,
                        cases, main_samples = mainSamples, indicator_samples = indicatorSamples,
                        scope = "hidden_seek_component_and_real_main_show_progress_binding_and_actual_sdk_regions; physical_pointer_and_phone_playback_not_tested"
                    }, new JsonSerializerOptions { WriteIndented = true }));
                }
                finally { window?.Close(); }
            }
            if (queue == null || queue.HasThreadAccess) Finish(); else await OnUi(queue, Finish);
        }
        void CleanupFailure(Exception error)
        { status = "failed"; failure = "real_main_cleanup_failed"; exceptionType = error.GetType().Name; hresult = error.HResult.ToString("X8"); }
        void AcceptMain(ReceiverSnapshot source)
        {
            Require(acceptSource!.Invoke(controller, [new PollResult(++mainRevision, source)]) is true, "source_fixture_not_accepted");
        }
        void VerifyMainPosition(double expectedPercent, string expectedTime)
        {
            foreach (var progressBar in new[] { Find<ProgressBar>("Progress"), Find<ProgressBar>("MiniProgress") })
                Require(Math.Abs(progressBar.Value - expectedPercent) < 0.000001, "real_main_bar_ignored_display_position");
            foreach (var text in new[] { Find<PlayerText>("PositionText"), Find<PlayerText>("MiniPosition") })
                Require(text.Text == expectedTime, "real_main_time_ignored_display_position");
        }
        void InspectIndicator(string mode, double width, double height, ulong position, string direction, int sample)
        {
            ArrangeMain(width, height);
            var progressBar = Find<ProgressBar>(mode == "compact" ? "MiniProgress" : "Progress");
            Require(progressBar is PlayerProgressBar, "real_main_player_progress_type_missing");
            progressBar.ApplyTemplate();
            var templateRoot = ProgressTemplateRoot(progressBar);
            var indicator = Descendants(templateRoot).OfType<Rectangle>().FirstOrDefault(element => element.Name == "DeterminateProgressBarIndicator");
            Require(indicator != null, "native_progress_indicator_missing");
            var transitions = VisualStateManager.GetVisualStateGroups(templateRoot).SelectMany(group => group.Transitions);
            Require(transitions.All(transition => !HasIndicatorReposition(transition.Storyboard)), "native_progress_reposition_transition_remains");
            double percent = 100.0 * position / initial.DurationMs!.Value;
            Require(Math.Abs(progressBar.Value - percent) < .000001, "native_progress_value_incorrect");
            var bounds = indicator!.TransformToVisual(templateRoot).TransformBounds(new global::Windows.Foundation.Rect(0, 0, indicator.ActualWidth, indicator.ActualHeight));
            double scale = progressBar.XamlRoot?.RasterizationScale ?? 1;
            var border = progressBar.BorderThickness;
            double Border(double value) => progressBar.UseLayoutRounding ? Math.Round(value * scale, MidpointRounding.AwayFromZero) / scale : value;
            double expectedWidth = Math.Max(0, templateRoot.ActualWidth - progressBar.Padding.Left - progressBar.Padding.Right - Border(border.Left) - Border(border.Right)) * percent / 100;
            Require(Math.Abs(bounds.Left) <= 1 / scale, "native_progress_indicator_left_moved");
            Require(Math.Abs(indicator.ActualWidth - expectedWidth) <= 1 / scale, "native_progress_indicator_length_incorrect");
            Require(indicator.HorizontalAlignment == HorizontalAlignment.Left && progressBar.Height == 3, "native_progress_indicator_alignment_changed");
            Require(ReferenceEquals(indicator.Fill, progressBar.Foreground), "native_progress_foreground_binding_lost");
            indicatorSamples.Add(new { mode, direction, sample, source_position_ms = position, value = progressBar.Value, left_dips = bounds.Left, width_dips = indicator.ActualWidth, expected_width_dips = expectedWidth, height_dips = progressBar.Height, reposition_transition_present = false });
            Background();
        }
        async Task WaitForProgress(bool visible)
        {
            // Completion is an observed layout state, not an assumed timer.
            // Bound the check so a lost/stale storyboard callback is a failure.
            long started = Environment.TickCount64;
            do
            {
                bool settled = false;
                await OnUi(queue!, () =>
                {
                    Background();
                    settled = new[] { Find<FrameworkElement>("ProgressPanel"), Find<FrameworkElement>("MiniProgressPanel") }.All(panel =>
                        visible ? panel.Visibility == Visibility.Visible && double.IsNaN(panel.Height) && Math.Abs(panel.Opacity - 1) < .001
                            : panel.Visibility == Visibility.Collapsed);
                });
                if (settled) return;
                await Task.Delay(20);
            } while (Environment.TickCount64 - started < 1500);
            throw new CheckFailure(visible ? "real_main_progress_show_animation_did_not_settle" : "real_main_progress_hide_animation_did_not_settle");
        }
        T Find<T>(string name) where T : FrameworkElement
        {
            var content = (FrameworkElement)main!.Content;
            // FindName also reaches controls below an inactive layout whose
            // Button template has not yet materialized its ContentPresenter.
            return content.FindName(name) as T ?? Descendants(content).OfType<T>().FirstOrDefault(element => element.Name == name)
                ?? throw new CheckFailure("real_main_named_element_missing");
        }
        void ArrangeMain(double width, double height)
        {
            Background();
            Require(GetClientRect(mainHwnd, out var client), "real_main_client_rect_missing");
            double scale = Math.Max(96, GetDpiForWindow(mainHwnd)) / 96.0;
            Require(Math.Abs((client.Right - client.Left) / scale - width) <= 1 && Math.Abs((client.Bottom - client.Top) / scale - height) <= 1, "real_main_native_size_not_applied");
            var content = (FrameworkElement)main!.Content;
            content.Measure(new global::Windows.Foundation.Size(width, height)); content.Arrange(new global::Windows.Foundation.Rect(0, 0, width, height)); content.UpdateLayout();
            main.RefreshAppearance(); content.UpdateLayout(); Background();
        }
        RectInt32 MainRegion(FrameworkElement element, FrameworkElement content)
        {
            Require(content.XamlRoot != null, "real_main_xaml_root_missing");
            double scale = content.XamlRoot!.RasterizationScale;
            var bounds = element.TransformToVisual(content).TransformBounds(new global::Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
            int x = (int)Math.Floor(bounds.X * scale), y = (int)Math.Floor(bounds.Y * scale);
            return new(x, y, (int)Math.Ceiling(bounds.Right * scale) - x, (int)Math.Ceiling(bounds.Bottom * scale) - y);
        }
    }
    private static object? PendingRequest(ProgressSeekButton target)
        => (typeof(ProgressSeekButton).GetField("pointerRequest", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new CheckFailure("pending_pointer_fixture_field_missing")).GetValue(target);
    private static FrameworkElement ProgressTemplateRoot(ProgressBar progressBar)
        => Descendants(progressBar).OfType<Grid>().FirstOrDefault(element => element.Name == "LayoutRoot")
            ?? throw new CheckFailure("native_progress_template_root_missing");
    private static bool HasIndicatorReposition(Storyboard? storyboard)
        => storyboard != null && storyboard.Children.Any(child => child is RepositionThemeAnimation { TargetName: "DeterminateProgressBarIndicator" }
            || child is Storyboard nested && HasIndicatorReposition(nested));
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        yield return parent;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
            foreach (var child in Descendants(VisualTreeHelper.GetChild(parent, index))) yield return child;
    }
    private static bool Contains(RectInt32 a, RectInt32 b) => a.X <= b.X && a.Y <= b.Y && a.X + a.Width >= b.X + b.Width && a.Y + a.Height >= b.Y + b.Height;
    private static RectInt32 Intersect(RectInt32 a, RectInt32 b)
    {
        int left = Math.Max(a.X, b.X), top = Math.Max(a.Y, b.Y);
        return new(left, top, Math.Max(0, Math.Min(a.X + a.Width, b.X + b.Width) - left), Math.Max(0, Math.Min(a.Y + a.Height, b.Y + b.Height) - top));
    }
    private static bool Overlaps(RectInt32 a, RectInt32 b) => a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height;
    private static Task OnUi(DispatcherQueue queue, Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } }))
            completion.SetException(new CheckFailure("dispatcher_enqueue_failed"));
        return completion.Task;
    }
    private static async Task Settle(DispatcherQueue queue)
    {
        await OnUi(queue, () => { }); await Task.Delay(60); await OnUi(queue, () => { });
    }
}
