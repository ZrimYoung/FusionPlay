using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace FusionPlay.Windows.Platform;

/// <summary>Validates actual SDK region registration on a window that is never shown.</summary>
internal static class WindowInputCheck
{
    internal static List<string> UnhandledErrors { get; } = [];
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] private static extern nint SendMessage(nint hwnd, uint message, nuint wParam, nint lParam);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    private sealed class CheckFailure(string code, object? details = null) : Exception { public string Code { get; } = code; public object? Details { get; } = details; }
    private sealed record Sample(double RequestedWidthDips, double RequestedHeightDips, string Mode, int WidthPixels, int HeightPixels, Dictionary<string, int> RegionCounts, long CoveredPixels);

    public static async Task Run(string outputFile)
    {
        var queue = DispatcherQueue.GetForCurrentThread();
        nint foreground = GetForegroundWindow(), hwnd = 0;
        Window? window = null;
        ISquareWindow? square = null;
        WindowResizeTransition? heightTransition = null;
        PlayerLayoutTransition? contentTransition = null;
        InputNonClientPointerSource? input = null;
        RectInt32 hole = default;
        string step = "create_hidden_window", status = "failed", failureCode = "", exceptionType = "", hresult = "";
        object? failureDetails = null;
        bool visibilityPreserved = true, foregroundPreserved = true, foregroundNotTaken = true;
        var samples = new List<Sample>();
        var motionSamples = new List<object>();
        void Require(bool condition, string code) { if (!condition) throw new CheckFailure(code); }
        void RequireBackground()
        {
            visibilityPreserved &= hwnd == 0 || !IsWindowVisible(hwnd);
            foregroundPreserved &= GetForegroundWindow() == foreground;
            foregroundNotTaken &= hwnd == 0 || GetForegroundWindow() != hwnd;
            Require(visibilityPreserved, "window_became_visible");
            Require(foregroundNotTaken, "test_window_took_foreground");
        }
        try
        {
            Require(queue != null, "dispatcher_unavailable");
            await OnUi(queue!, () =>
            {
                RequireBackground();
                window = new Window { Title = "FusionPlay Background Input Check", Content = new Grid() };
                hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
                RequireBackground();
                window.AppWindow.IsShownInSwitchers = false;
                Require(window.AppWindow.Presenter is OverlappedPresenter, "overlapped_presenter_unavailable");
                var presenter = (OverlappedPresenter)window.AppWindow.Presenter;
                presenter.SetBorderAndTitleBar(false, false); presenter.IsResizable = true; presenter.IsMaximizable = false;
                WindowSizing.Apply(window, 420, 420, 260, 260);
                RequireBackground();
                square = WindowSizing.FixedSquare(window, _ => { });
                WindowSizing.ResizeContent(window, 420, 420);
                RequireBackground();
                Require(GetClientRect(hwnd, out var client), "client_bounds_unavailable");
                int side = Math.Min(client.Right - client.Left, client.Bottom - client.Top);
                Require(side >= 64, "client_bounds_too_small");
                hole = new(side / 4, side / 4, side / 8, side / 12);
                square.UpdateInputRegions([hole]);
                input = InputNonClientPointerSource.GetForWindowId(window.AppWindow.Id);
                RequireBackground();
            });
            await Drain(queue!);
            step = "initial_region_registration";
            await OnUi(queue!, () => samples.Add(Inspect(420, 420, compact: true)));
            foreach (double size in new[] { 360.0, 520.0 })
            {
                step = "hidden_resize";
                await OnUi(queue!, () => { RequireBackground(); WindowSizing.ResizeContent(window!, size, size); RequireBackground(); });
                await Drain(queue!);
                step = "resized_region_registration";
                await OnUi(queue!, () => samples.Add(Inspect(size, size, compact: true)));
            }
            step = "hidden_expanded_resize";
            await OnUi(queue!, () => { RequireBackground(); WindowSizing.ResizeContent(window!, 820, 480); RequireBackground(); });
            await Drain(queue!);
            step = "expanded_region_registration";
            await OnUi(queue!, () => samples.Add(Inspect(820, 480, compact: false)));
            step = "hidden_compact_resize";
            await OnUi(queue!, () => { RequireBackground(); WindowSizing.ResizeContent(window!, 420, 300); RequireBackground(); });
            await Drain(queue!);
            step = "compact_region_registration";
            await OnUi(queue!, () => samples.Add(Inspect(420, 300, compact: true)));
            Require(samples.Select(sample => sample.WidthPixels).Distinct().Count() >= 2, "insufficient_resize_range");
            await OnUi(queue!, () =>
            {
                WindowSizing.ResizeContent(window!, 420, 420);
                heightTransition = new WindowResizeTransition(window!, square!);
                square!.MoveSizeStarted += () => heightTransition.Cancel();
            });
            await Drain(queue!);
            bool motion = Backdrop.AnimationsEnabled;
            foreach (bool visible in new[] { true, false })
            {
                step = visible ? "animated_lyric_expansion" : "animated_lyric_collapse";
                bool completed = false;
                await OnUi(queue!, () =>
                {
                    RequireBackground();
                    heightTransition!.AnimateLyrics(visible, motion, () => completed = true);
                    square!.SetPlayerLayout(visible, false);
                });
                var heights = new List<int>();
                for (int tick = 0; tick < 50; tick++)
                {
                    await OnUi(queue!, () => { RequireBackground(); Require(GetClientRect(hwnd, out var client), "animated_client_unavailable"); heights.Add(client.Bottom - client.Top); });
                    if (completed) break;
                    await Task.Delay(20);
                }
                await Drain(queue!);
                await OnUi(queue!, () =>
                {
                    Require(completed && !heightTransition!.IsRunning, "lyric_height_animation_did_not_finish");
                    Require(GetClientRect(hwnd, out var client), "animated_client_unavailable");
                    int width = client.Right - client.Left, height = client.Bottom - client.Top;
                    Require(visible ? height > width : Math.Abs(height - width) <= 1, "lyric_height_final_shape_wrong");
                    if (motion) Require(heights.Distinct().Count() >= 3, "lyric_height_animation_had_no_intermediate_sizes");
                    for (int i = 1; i < heights.Count; i++) Require(visible ? heights[i] >= heights[i - 1] : heights[i] <= heights[i - 1], "lyric_height_animation_reversed");
                    motionSamples.Add(new { visible, motion, heights, width, height, updates = heightTransition!.HeightUpdates });
                });
            }
            step = "rapid_lyric_height_reversal";
            bool oldCompleted = false, latestCompleted = false;
            await OnUi(queue!, () => { heightTransition!.AnimateLyrics(true, true, () => oldCompleted = true); square!.SetPlayerLayout(true, false); });
            await Task.Delay(45);
            await OnUi(queue!, () => { heightTransition!.AnimateLyrics(false, true, () => latestCompleted = true); square!.SetPlayerLayout(false, false); });
            await Task.Delay(420);
            await OnUi(queue!, () =>
            {
                Require(latestCompleted && !heightTransition!.IsRunning, "latest_height_reversal_did_not_finish");
                Require(!motion || !oldCompleted, "cancelled_height_animation_called_old_completion");
                Require(GetClientRect(hwnd, out var client) && Math.Abs(client.Right - client.Left - client.Bottom + client.Top) <= 1, "reversed_height_did_not_restore_square");
                motionSamples.Add(new { name = "rapid_reversal", latestCompleted, oldCompleted });
            });
            step = "manual_move_cancels_height_transition";
            bool gestureCompletion = false;
            await OnUi(queue!, () => { heightTransition!.AnimateLyrics(true, true, () => gestureCompletion = true); square!.SetPlayerLayout(true, false); });
            await Task.Delay(45);
            await OnUi(queue!, () =>
            {
                RequireBackground();
                _ = SendMessage(hwnd, 0x0231, 0, 0);
                Require(!heightTransition!.IsRunning, "manual_move_did_not_cancel_height_animation");
                Require(!motion || !gestureCompletion, "manual_move_completed_cancelled_animation");
                _ = SendMessage(hwnd, 0x0232, 0, 0);
                motionSamples.Add(new { name = "own_window_move_message_cancels_animation", gestureCompletion });
            });
            step = "controlled_compositor_layout_transition";
            Border? card = null; bool contentComplete = false; int commits = 0;
            long contentStarted = 0; double firstCommitDelay = 0, latestCommitDelay = 0;
            await OnUi(queue!, () =>
            {
                var root = (Grid)window!.Content;
                card = new Border { Width = 64, Height = 64, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(20) };
                root.Children.Add(card);
                root.Measure(new global::Windows.Foundation.Size(420, 600)); root.Arrange(new global::Windows.Foundation.Rect(0, 0, 420, 600)); root.UpdateLayout();
                contentTransition = new PlayerLayoutTransition(root, [card], [(card, true)]);
                contentStarted = Stopwatch.GetTimestamp();
                contentTransition.Run(() => { firstCommitDelay = Stopwatch.GetElapsedTime(contentStarted).TotalMilliseconds; commits++; card.Width = card.Height = 96; card.Margin = new Thickness(70, 40, 0, 0); }, () => contentComplete = true, animate: true);
                Require(contentTransition.IsRunning, "compositor_transition_did_not_start");
            });
            await Task.Delay(560);
            await OnUi(queue!, () =>
            {
                Require(contentComplete && commits == 1 && !contentTransition!.IsRunning, "compositor_layout_transition_did_not_finish");
                Require(contentTransition!.AnimationFailures == 0, "compositor_animation_fell_back_after_native_error");
                Require(firstCommitDelay >= 100, "layout_committed_before_content_faded_out");
                Require(UnhandledErrors.Count == 0, "compositor_transition_unhandled_exception");
                motionSamples.Add(new { name = "controlled_compositor_layout_transition", commits, contentComplete, firstCommitDelay });
                contentComplete = false; oldCompleted = false;
                contentTransition.Run(() => commits++, () => oldCompleted = true, animate: true);
            });
            await Task.Delay(45);
            await OnUi(queue!, () =>
            {
                contentStarted = Stopwatch.GetTimestamp();
                contentTransition!.Run(() => { latestCommitDelay = Stopwatch.GetElapsedTime(contentStarted).TotalMilliseconds; commits++; card!.Margin = new Thickness(35); }, () => contentComplete = true, animate: true);
            });
            await Task.Delay(560);
            await OnUi(queue!, () =>
            {
                Require(contentComplete && !oldCompleted && commits == 2 && !contentTransition!.IsRunning, "compositor_transition_reversal_used_stale_completion");
                Require(contentTransition!.AnimationFailures == 0, "reversed_compositor_animation_fell_back_after_native_error");
                Require(latestCommitDelay >= 100, "stale_tick_committed_reversed_layout_before_fade");
                Require(UnhandledErrors.Count == 0, "compositor_transition_unhandled_exception");
                motionSamples.Add(new { name = "controlled_compositor_rapid_reversal", commits, contentComplete, oldCompleted, latestCommitDelay });
            });
            status = "passed";
        }
        catch (Exception error)
        {
            failureCode = error is CheckFailure check ? check.Code : "native_api_failed";
            failureDetails = (error as CheckFailure)?.Details;
            exceptionType = error.GetType().Name; hresult = error.HResult.ToString("X8");
        }
        finally
        {
            try
            {
                if (queue != null) await OnUi(queue, () =>
                {
                    try { RequireBackground(); }
                    finally
                    {
                        try { contentTransition?.Dispose(); heightTransition?.Dispose(); square?.Dispose(); }
                        finally { window?.Close(); }
                    }
                    RequireBackground();
                });
            }
            catch (Exception error)
            {
                status = "failed"; step = "hidden_window_cleanup";
                failureCode = error is CheckFailure check ? check.Code : "cleanup_failed";
                failureDetails = (error as CheckFailure)?.Details;
                exceptionType = error.GetType().Name; hresult = error.HResult.ToString("X8");
            }
            // This diagnostic must never escape into the app's normal launch/fallback
            // flow. A missing report is a failed check, not grounds to show a window.
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputFile))!);
                File.WriteAllText(outputFile, JsonSerializer.Serialize(new
                {
                    status, step, failure_code = failureCode, exception_type = exceptionType, hresult,
                    failure_details = failureDetails,
                    window_remained_hidden = visibilityPreserved, foreground_unchanged = foregroundPreserved, foreground_not_taken = foregroundNotTaken,
                    receiver_created = false, samples, motion_samples = motionSamples, unhandled_errors = UnhandledErrors,
                    scope = "hidden_sdk_region_registration_height_motion_and_responsive_resize; physical_pointer_interaction_and_visible_DWM_frames_not_tested"
                }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }

        Sample Inspect(double requestedWidth, double requestedHeight, bool compact)
        {
            RequireBackground();
            Require(GetClientRect(hwnd, out var client), "client_bounds_unavailable");
            int width = client.Right - client.Left, height = client.Bottom - client.Top;
            Require(width > 0 && height > 0, "client_bounds_empty");
            double scale = Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
            Require(WindowSizing.IsCompactContent(width / scale, height / scale) == compact, "unexpected_responsive_mode");
            if (compact)
            {
                Require(width == height, "compact_client_aspect_not_square");
                int expected = (int)Math.Ceiling(Math.Min(requestedWidth, requestedHeight) * scale);
                Require(Math.Abs(width - expected) <= 1, "compact_settlement_changed_requested_extent");
            }
            else
            {
                Require(width != height, "expanded_client_aspect_was_constrained");
                Require(Math.Abs(width - Math.Ceiling(requestedWidth * scale)) <= 1 && Math.Abs(height - Math.Ceiling(requestedHeight * scale)) <= 1,
                    "expanded_client_rectangle_changed");
            }
            var kinds = new[] { NonClientRegionKind.Caption, NonClientRegionKind.TopBorder, NonClientRegionKind.LeftBorder, NonClientRegionKind.BottomBorder, NonClientRegionKind.RightBorder, NonClientRegionKind.Passthrough };
            var all = new List<RectInt32>(); var counts = new Dictionary<string, int>();
            foreach (var kind in kinds)
            {
                var rectangles = input!.GetRegionRects(kind);
                Require(rectangles.Length > 0, "sdk_region_missing"); counts[kind.ToString()] = rectangles.Length;
                foreach (var rect in rectangles)
                {
                    if (!(rect.Width > 0 && rect.Height > 0 && rect.X >= 0 && rect.Y >= 0 && rect.X + rect.Width <= width && rect.Y + rect.Height <= height))
                        throw new CheckFailure("sdk_region_out_of_bounds", new { region = kind.ToString(), rectangle = new[] { rect.X, rect.Y, rect.Width, rect.Height }, client = new[] { width, height } });
                    all.Add(rect);
                }
            }
            var actualHole = input!.GetRegionRects(NonClientRegionKind.Passthrough);
            Require(actualHole.Length == 1 && actualHole[0].Equals(hole), "sdk_passthrough_mismatch");
            foreach (var kind in new[] { NonClientRegionKind.Close, NonClientRegionKind.Minimize, NonClientRegionKind.Maximize, NonClientRegionKind.Icon })
                Require(input.GetRegionRects(kind).Length == 0, "unexpected_system_caption_region");
            for (int a = 0; a < all.Count; a++)
                for (int b = a + 1; b < all.Count; b++) Require(!Overlaps(all[a], all[b]), "sdk_regions_overlap");
            long area = all.Sum(rect => (long)rect.Width * rect.Height);
            Require(area == (long)width * height, "sdk_regions_leave_gaps");
            RequireBackground();
            return new(requestedWidth, requestedHeight, compact ? "compact" : "expanded", width, height, counts, area);
        }
    }
    private static bool Overlaps(RectInt32 a, RectInt32 b)
        => a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height;
    private static Task OnUi(DispatcherQueue queue, Action action)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } }))
            completion.SetException(new CheckFailure("dispatcher_enqueue_failed"));
        return completion.Task;
    }
    private static async Task Drain(DispatcherQueue queue)
    {
        await OnUi(queue, () => { });
        await Task.Delay(60);
        await OnUi(queue, () => { });
    }
}
