using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Numerics;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
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
            Border? card = null; bool contentComplete = false; int commits = 0, completions = 0;
            long contentStarted = 0; double firstCommitDelay = 0, latestCommitDelay = 0;
            await OnUi(queue!, () =>
            {
                var root = (Grid)window!.Content;
                card = new Border { Width = 64, Height = 64, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(20) };
                root.Children.Add(card);
                root.Measure(new global::Windows.Foundation.Size(420, 600)); root.Arrange(new global::Windows.Foundation.Rect(0, 0, 420, 600)); root.UpdateLayout();
                contentTransition = new PlayerLayoutTransition(root, [card], [(card, true)]);
                contentStarted = Stopwatch.GetTimestamp();
                contentTransition.Run(() => { firstCommitDelay = Stopwatch.GetElapsedTime(contentStarted).TotalMilliseconds; commits++; card.Width = card.Height = 96; card.Margin = new Thickness(70, 40, 0, 0); }, () => { contentComplete = true; completions++; }, animate: true);
                Require(contentTransition.IsRunning, "compositor_transition_did_not_start");
                Require(commits == 1, "overlap_transition_did_not_commit_immediately");
            });
            await Task.Delay(560);
            await OnUi(queue!, () =>
            {
                Require(contentComplete && commits == 1 && completions == 1 && !contentTransition!.IsRunning, "compositor_layout_transition_did_not_finish");
                Require(contentTransition!.AnimationFailures == 0, "compositor_animation_fell_back_after_native_error");
                Require(UnhandledErrors.Count == 0, "compositor_transition_unhandled_exception");
                motionSamples.Add(new { name = "controlled_compositor_layout_transition", commits, completions, contentComplete, firstCommitDelay });
                contentComplete = false; oldCompleted = false;
                contentTransition.Run(() => commits++, () => oldCompleted = true, animate: true);
            });
            await Task.Delay(45);
            await OnUi(queue!, () =>
            {
                contentStarted = Stopwatch.GetTimestamp();
                contentTransition!.Run(() => { latestCommitDelay = Stopwatch.GetElapsedTime(contentStarted).TotalMilliseconds; commits++; card!.Margin = new Thickness(35); }, () => { contentComplete = true; completions++; }, animate: true);
                Require(commits == 3, "reversed_overlap_transition_did_not_commit_latest_layout_immediately");
            });
            await Task.Delay(560);
            await OnUi(queue!, () =>
            {
                Require(contentComplete && !oldCompleted && commits == 3 && completions == 2 && !contentTransition!.IsRunning, "compositor_transition_reversal_used_stale_completion");
                Require(contentTransition!.AnimationFailures == 0, "reversed_compositor_animation_fell_back_after_native_error");
                Require(UnhandledErrors.Count == 0, "compositor_transition_unhandled_exception");
                motionSamples.Add(new { name = "controlled_compositor_rapid_reversal", commits, completions, contentComplete, oldCompleted, latestCommitDelay });
                contentComplete = false;
                contentTransition.Run(() => { commits++; card!.Width = card.Height = 64; card.Margin = new Thickness(20); }, () => { contentComplete = true; completions++; }, animate: false);
                Require(contentComplete && commits == 4 && completions == 3 && !contentTransition.IsRunning && contentTransition.AnimationFailures == 0,
                    "reduced_motion_layout_did_not_commit_and_complete_synchronously");
                motionSamples.Add(new { name = "controlled_compositor_reduced_motion_snap", commits, completions, contentComplete });
            });
            step = "external_native_geometry_screen_space_bridge";
            Grid? oldScene = null, newScene = null; Border? oldCover = null, newCover = null;
            FrameworkElement? activeScene = null;
            var clientOrigin = new global::Windows.Foundation.Point(100, 200); double simulatedScale = 1.5;
            int geometryCommits = 0, geometryCompletions = 0; bool cancelledGeometryCompleted = false;
            await OnUi(queue!, () =>
            {
                RequireBackground(); contentTransition!.Dispose();
                square!.SetPlayerLayout(true, false); WindowSizing.ResizeContent(window!, 420, 600);
            });
            await Drain(queue!);
            await OnUi(queue!, () =>
            {
                var content = (Grid)window!.Content; content.Children.Clear();
                oldScene = new Grid { Name = "GeometryOldScene" }; newScene = new Grid { Name = "GeometryNewScene", Visibility = Visibility.Collapsed };
                oldCover = new Border { Name = "GeometryOldCover", Width = 64, Height = 64, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(20), Background = new SolidColorBrush(Microsoft.UI.Colors.CornflowerBlue) };
                newCover = new Border { Name = "GeometryNewCover", Width = 96, Height = 96, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(70, 40, 0, 0), Background = new SolidColorBrush(Microsoft.UI.Colors.Coral) };
                oldScene.Children.Add(oldCover); newScene.Children.Add(newCover); content.Children.Add(oldScene); content.Children.Add(newScene); activeScene = oldScene;
                content.Measure(new global::Windows.Foundation.Size(420, 600)); content.Arrange(new global::Windows.Foundation.Rect(0, 0, 420, 600)); content.UpdateLayout();
                contentTransition = new PlayerLayoutTransition(content, [oldScene, newScene], [(oldCover, true), (newCover, true)],
                    scenes: [oldScene, newScene], activeScene: () => activeScene!, semanticPairs: [(oldCover, newCover)], clientFrame: () => (clientOrigin, simulatedScale));
                contentTransition.Remember(); contentTransition.Capture(useRemembered: true);
                // This is an external geometry change on the same hidden native
                // window. The injected frame simulates a new screen origin/DPI;
                // no fullscreen presenter is created or attached by this check.
                clientOrigin = new global::Windows.Foundation.Point(400, 100); simulatedScale = 2;
                WindowSizing.ResizeContent(window, 820, 480);
            });
            await Drain(queue!);
            await OnUi(queue!, () =>
            {
                RequireBackground(); var content = (Grid)window!.Content;
                content.Measure(new global::Windows.Foundation.Size(820, 480)); content.Arrange(new global::Windows.Foundation.Rect(0, 0, 820, 480)); content.UpdateLayout();
                contentTransition!.Run(() => { geometryCommits++; activeScene = newScene; oldScene!.Visibility = Visibility.Collapsed; newScene!.Visibility = Visibility.Visible; }, () => geometryCompletions++, animate: true);
                Require(geometryCommits == 1 && geometryCompletions == 0 && contentTransition.IsRunning, "external_geometry_did_not_commit_before_overlap");
                Require(ReferenceEquals(contentTransition.RetainedScene, oldScene) && oldScene!.Visibility == Visibility.Visible && newScene!.Visibility == Visibility.Visible,
                    "external_geometry_did_not_retain_outgoing_scene");
                var bridge = contentTransition.LastBridges.SingleOrDefault(item => item.Element == newCover!.Name)
                    ?? throw new CheckFailure("external_geometry_semantic_cover_bridge_missing");
                Require(Math.Abs(bridge.From.X + 135) < .01 && Math.Abs(bridge.From.Y - 65) < .01
                    && Math.Abs(bridge.From.Width - 48) < .01 && Math.Abs(bridge.From.Height - 48) < .01
                    && Math.Abs(bridge.To.X - 70) < .01 && Math.Abs(bridge.To.Y - 40) < .01 && Math.Abs(bridge.To.Width - 96) < .01,
                    "external_geometry_did_not_map_old_physical_screen_bounds_into_new_dips");
                Require(contentTransition.AnimationFailures == 0 && window.AppWindow.Presenter.Kind == AppWindowPresenterKind.Overlapped,
                    "external_geometry_bridge_failed_or_changed_presenter");
                motionSamples.Add(new
                {
                    name = "external_native_geometry_overlap_created", geometryCommits, geometryCompletions,
                    retained_scene = contentTransition.RetainedScene?.Name, bridge.Element,
                    from = new[] { bridge.From.X, bridge.From.Y, bridge.From.Width, bridge.From.Height }, to = new[] { bridge.To.X, bridge.To.Y, bridge.To.Width, bridge.To.Height },
                    translation_start = new[] { bridge.From.X - bridge.To.X, bridge.From.Y - bridge.To.Y }, scale_start = bridge.From.Width / bridge.To.Width,
                    simulated_screen_origin_and_dpi = true, fullscreen_presenter_attached = false, visible_presentation_verified = false
                });
            });
            await Task.Delay(45);
            await OnUi(queue!, () =>
            {
                RequireBackground(); contentTransition!.Capture();
                clientOrigin = new global::Windows.Foundation.Point(100, 200); simulatedScale = 1.5;
                contentTransition.Run(() =>
                {
                    geometryCommits++; activeScene = oldScene; newScene!.Visibility = Visibility.Collapsed; oldScene!.Visibility = Visibility.Visible;
                    oldCover!.Width = oldCover.Height = 80; oldCover.Margin = new Thickness(30, 10, 0, 0);
                }, () => geometryCompletions++, animate: true);
                var bridge = contentTransition.LastBridges.SingleOrDefault(item => item.Element == oldCover!.Name)
                    ?? throw new CheckFailure("reversed_geometry_semantic_cover_bridge_missing");
                var visual = ElementCompositionPreview.GetElementVisual(oldScene!);
                var translationStatus = visual.Properties.TryGetVector3("Translation", out var translation);
                var rawCover = oldCover!.TransformToVisual((Grid)window!.Content).TransformBounds(new global::Windows.Foundation.Rect(0, 0, oldCover.ActualWidth, oldCover.ActualHeight));
                var localCover = oldCover.TransformToVisual(oldScene!).TransformBounds(new global::Windows.Foundation.Rect(0, 0, oldCover.ActualWidth, oldCover.ActualHeight));
                var sceneOrigin = oldScene!.TransformToVisual((Grid)window.Content).TransformPoint(new global::Windows.Foundation.Point());
                motionSamples.Add(new
                {
                    name = "external_geometry_parent_reverse_before_assert", geometryCommits, geometryCompletions, contentTransition.ParentNormalizations, contentTransition.AnimationFailures,
                    from = new[] { bridge.From.X, bridge.From.Y, bridge.From.Width, bridge.From.Height }, to = new[] { bridge.To.X, bridge.To.Y, bridge.To.Width, bridge.To.Height },
                    root_translation_status = translationStatus.ToString(), root_translation = new[] { translation.X, translation.Y, translation.Z },
                    root_scale = new[] { visual.Scale.X, visual.Scale.Y, visual.Scale.Z },
                    old_cover_raw_root_bounds = new[] { rawCover.X, rawCover.Y, rawCover.Width, rawCover.Height },
                    old_cover_scene_bounds = new[] { localCover.X, localCover.Y, localCover.Width, localCover.Height }, scene_raw_root_origin = new[] { sceneOrigin.X, sceneOrigin.Y },
                    old_scene_actual = new[] { oldScene!.ActualWidth, oldScene.ActualHeight }, old_cover_actual = new[] { oldCover.ActualWidth, oldCover.ActualHeight }
                });
                Require(geometryCommits == 2 && geometryCompletions == 0 && contentTransition.ParentNormalizations >= 1
                    && Math.Abs(bridge.From.X - 20) < .01 && Math.Abs(bridge.From.Y - 20) < .01
                    && Math.Abs(bridge.From.Width - 64) < .01 && Math.Abs(bridge.From.Height - 64) < .01
                    && Math.Abs(bridge.To.X - 30) < .01 && Math.Abs(bridge.To.Y - 10) < .01 && Math.Abs(bridge.To.Width - 80) < .01,
                    "reversed_geometry_did_not_normalize_incoming_scene_screen_bounds");
                Require(translationStatus == Microsoft.UI.Composition.CompositionGetValueStatus.Succeeded
                    && translation == Vector3.Zero && visual.Scale == Vector3.One, "incoming_scene_retained_outgoing_static_transform");
                motionSamples.Add(new { name = "external_geometry_rapid_parent_reverse", geometryCommits, geometryCompletions, contentTransition.ParentNormalizations,
                    from = new[] { bridge.From.X, bridge.From.Y, bridge.From.Width, bridge.From.Height }, to = new[] { bridge.To.X, bridge.To.Y, bridge.To.Width, bridge.To.Height }, root_normalized_before_return = true });
            });
            await Task.Delay(420);
            await OnUi(queue!, () =>
            {
                RequireBackground();
                Require(geometryCommits == 2 && geometryCompletions == 1 && !contentTransition!.IsRunning && contentTransition.RetainedScene == null
                    && newScene!.Visibility == Visibility.Collapsed && oldScene!.Visibility == Visibility.Visible && contentTransition.AnimationFailures == 0,
                    "external_geometry_overlap_did_not_finish_exactly_once");
                contentTransition!.Capture();
                contentTransition.Run(() => { geometryCommits++; activeScene = newScene; oldScene!.Visibility = Visibility.Collapsed; newScene!.Visibility = Visibility.Visible; }, () => cancelledGeometryCompleted = true, animate: true);
                Require(contentTransition.IsRunning && contentTransition.RetainedScene != null, "external_geometry_cancel_fixture_did_not_start");
                contentTransition.Cancel();
                Require(!contentTransition.IsRunning && contentTransition.RetainedScene == null && oldScene!.IsHitTestVisible && newScene!.IsHitTestVisible,
                    "external_geometry_cancel_did_not_restore_scene_input");
            });
            await Task.Delay(380);
            await OnUi(queue!, () =>
            {
                RequireBackground(); Require(!cancelledGeometryCompleted && geometryCompletions == 1, "cancelled_external_geometry_used_stale_completion");
                contentTransition!.Run(() => { geometryCommits++; activeScene = oldScene; newScene!.Visibility = Visibility.Collapsed; oldScene!.Visibility = Visibility.Visible; }, () => geometryCompletions++, animate: false);
                Require(geometryCommits == 4 && geometryCompletions == 2 && !contentTransition.IsRunning && contentTransition.RetainedScene == null
                    && contentTransition.AnimationFailures == 0, "external_geometry_reduced_motion_did_not_snap_synchronously");
                motionSamples.Add(new { name = "external_geometry_cancel_and_reduced_motion_snap", geometryCommits, geometryCompletions, cancelledGeometryCompleted, fullscreen_presenter_attached = false });
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
                    scope = "hidden_sdk_regions_height_motion_responsive_resize_and_screen_space_geometry_overlap; fullscreen_geometry_simulated_via_client_frame_delegate_no_presenter_attachment; physical_pointer_and_visible_DWM_frames_not_tested"
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
