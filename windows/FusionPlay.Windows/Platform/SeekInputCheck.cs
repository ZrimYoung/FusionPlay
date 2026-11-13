using System.Runtime.InteropServices;
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
using Windows.Graphics;
using VirtualKey = Windows.System.VirtualKey;

namespace FusionPlay.Windows.Platform;

/// <summary>Exercises the seek target and real SDK input regions without creating a receiver or showing a window.</summary>
internal static class SeekInputCheck
{
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    private sealed class CheckFailure(string code) : Exception { public string Code { get; } = code; }

    public static async Task Run(string outputFile)
    {
        var queue = DispatcherQueue.GetForCurrentThread();
        nint foreground = GetForegroundWindow(), hwnd = 0;
        Window? window = null;
        ISquareWindow? sizing = null;
        string status = "failed", step = "create_hidden_window", failure = "", exceptionType = "", hresult = "";
        bool remainedHidden = true, foregroundUnchanged = true;
        var cases = new List<string>();
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
                status = "passed";
            });
        }
        catch (Exception error)
        {
            failure = error is CheckFailure check ? check.Code : "seek_check_failed";
            exceptionType = error.GetType().Name; hresult = error.HResult.ToString("X8");
        }
        finally
        {
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
                        status, step, failure_code = failure, exception_type = exceptionType, hresult,
                        window_remained_hidden = remainedHidden, foreground_unchanged = foregroundUnchanged,
                        receiver_created = false, shell_media_session_created = false, dispatched_fixture_requests = requests.Count,
                        cases, scope = "hidden_seek_component_and_actual_sdk_regions; physical_pointer_and_phone_playback_not_tested"
                    }, new JsonSerializerOptions { WriteIndented = true }));
                }
                finally { window?.Close(); }
            }
            if (queue == null || queue.HasThreadAccess) Finish(); else await OnUi(queue, Finish);
        }
    }
    private static bool Contains(RectInt32 a, RectInt32 b) => a.X <= b.X && a.Y <= b.Y && a.X + a.Width >= b.X + b.Width && a.Y + a.Height >= b.Y + b.Height;
    private static bool Overlaps(RectInt32 a, RectInt32 b) => a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height;
    private static Task OnUi(DispatcherQueue queue, Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } }))
            completion.SetException(new CheckFailure("dispatcher_enqueue_failed"));
        return completion.Task;
    }
}
