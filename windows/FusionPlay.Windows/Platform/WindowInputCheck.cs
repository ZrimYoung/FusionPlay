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
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] private static extern nint SendMessage(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] private static extern nint SendSizing(nint hwnd, uint message, nuint wParam, ref NativeRect bounds);
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
        var coverCues = new List<CoverResizeCue>();
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
                square = WindowSizing.FixedSquare(window, _ => { }, coverCues.Add);
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
            step = "native_resize_starts_only_on_sizing";
            await OnUi(queue!, () =>
            {
                RequireBackground();
                int starts = 0;
                void Started() => starts++;
                square!.ResizeStarted += Started;
                try
                {
                    _ = SendMessage(hwnd, 0x0231, 0, 0);
                    _ = SendMessage(hwnd, 0x0232, 0, 0);
                    Require(starts == 0, "moving_window_started_resize_mode");
                    Require(GetWindowRect(hwnd, out var bounds), "native_resize_fixture_bounds_unavailable");
                    for (int gesture = 1; gesture <= 2; gesture++)
                    {
                        _ = SendMessage(hwnd, 0x0231, 0, 0);
                        _ = SendSizing(hwnd, 0x0214, 8, ref bounds);
                        _ = SendSizing(hwnd, 0x0214, 8, ref bounds);
                        Require(starts == gesture, "resize_signal_not_once_per_gesture");
                        _ = SendMessage(hwnd, 0x0232, 0, 0);
                    }
                    motionSamples.Add(new { name = step, starts });
                }
                finally { square.ResizeStarted -= Started; }
            });
            step = "native_cover_bottom_lyrics_and_album_sizing";
            await OnUi(queue!, () =>
            {
                RequireBackground();
                int starts = 0, previews = 0, cancels = 0;
                var commits = new List<bool>();
                var ordering = new List<string>();
                double scale = Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
                int Pixels(double value) => (int)Math.Ceiling(value * scale);
                var work = DisplayArea.GetFromWindowId(window!.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
                int side = Pixels(360);
                Require(work.Height >= side + Pixels(136) + 12, "cover_lyrics_work_area_too_small");
                square!.SetPlayerLayout(false, false, compactPaging: true, coverBottomResize: true);
                window.AppWindow.MoveAndResize(new(work.X + 8, work.Y + 8, side, side));
                Require(GetWindowRect(hwnd, out var original), "cover_lyrics_fixture_bounds_unavailable");
                square.CoverLyricsResizeStarted += Started;
                square.CoverLyricsResizeExpanded += Expanded;
                square.CoverLyricsResizeCanceled += Canceled;
                square.CoverLyricsResizeCompleted += Completed;
                square.MoveSizeEnded += MoveSizeEnded;
                try
                {
                    coverCues.Clear();
                    Begin();
                    Apply(6, original, side, side + Pixels(2));
                    End();
                    Require(starts == 0 && previews == 0 && commits.Count == 0, "minor_bottom_jitter_started_lyrics");
                    window.AppWindow.MoveAndResize(new(original.Left, original.Top, side, side));

                    square.SetPlayerLayout(true, false, compactPaging: true, coverBottomResize: true, allowCoverBottomResize: false);
                    Begin();
                    // Beginning the native gesture may settle an outgoing page
                    // transition before the system delivers its first resize.
                    square.SetPlayerLayout(true, false, compactPaging: true, coverBottomResize: true);
                    var blocked = Apply(6, original, side, side + Pixels(80));
                    int maximumSide = Math.Min(work.Width, work.Height);
                    Require(blocked.Right - blocked.Left == blocked.Bottom - blocked.Top
                        && blocked.Bottom - blocked.Top == Math.Min(maximumSide, side + Pixels(80)),
                        "bottom_resize_on_lyrics_page_lost_square");
                    var stillBlocked = Apply(6, original, side, side + Pixels(96));
                    End();
                    Require(stillBlocked.Right - stillBlocked.Left == stillBlocked.Bottom - stillBlocked.Top
                        && starts == 0 && previews == 0 && cancels == 0 && commits.Count == 0,
                        "bottom_resize_on_lyrics_page_opened_stacked_lyrics");
                    window.AppWindow.MoveAndResize(new(original.Left, original.Top, side, side));

                    Begin();
                    var opened = Apply(6, original, side + Pixels(37), side + Pixels(80));
                    Require(opened.Left == original.Left && opened.Top == original.Top && opened.Right == original.Right,
                        "cover_lyrics_drag_changed_top_left_or_width");
                    Require(opened.Bottom - opened.Top == side + Pixels(80), "cover_lyrics_live_rectangle_was_clamped_to_settled_height");
                    Require(starts == 1 && previews == 1 && commits.Count == 0, "cover_lyrics_preview_order");
                    Require(coverCues.Count(cue => cue == CoverResizeCue.Dragging) == 2,
                        "cover_resize_cue_did_not_follow_eligible_gestures");
                    End();
                    Require(coverCues.LastOrDefault() == CoverResizeCue.Hidden, "cover_resize_cue_survived_release");
                    Require(GetWindowRect(hwnd, out opened) && opened.Bottom - opened.Top == side + Pixels(136)
                        && opened.Left == original.Left && opened.Top == original.Top, "cover_lyrics_open_snap_wrong");
                    Require(commits.SequenceEqual(new[] { true }) && ordering.TakeLast(2).SequenceEqual(new[] { "commit", "ended" }),
                        "cover_lyrics_open_not_committed_before_resize_end");

                    Begin();
                    int narrower = Pixels(300);
                    var scaled = Apply(2, opened, narrower, opened.Bottom - opened.Top);
                    End();
                    Require(Math.Abs((scaled.Bottom - scaled.Top) - (opened.Bottom - opened.Top) * (double)narrower / side) <= 1,
                        "ordinary_cover_side_did_not_scale_proportionally");
                    Require(starts == 1 && commits.Count == 1, "ordinary_cover_side_committed_lyrics_pane");

                    Begin();
                    var sliver = Apply(6, scaled, narrower, narrower + Pixels(40));
                    Require(sliver.Bottom - sliver.Top == narrower + Pixels(40) && commits.Count == 1, "cover_lyrics_closed_before_release");
                    End();
                    Require(GetWindowRect(hwnd, out var closed) && closed.Bottom - closed.Top == narrower
                        && commits.SequenceEqual(new[] { true, false }), "cover_lyrics_collapse_did_not_snap_square");
                    Require(starts == 2 && previews == 1, "cover_lyrics_collapse_reopened_preview");

                    Begin();
                    var corner = Apply(8, closed, Pixels(335), Pixels(350));
                    End();
                    Require(corner.Bottom - corner.Top == corner.Right - corner.Left && starts == 2 && commits.Count == 2,
                        "corner_was_routed_to_lyrics_resize");

                    square.SetPlayerLayout(true, false, compactPaging: true, independentAlbum: true);
                    Begin();
                    var album = Apply(6, corner, corner.Right - corner.Left, Pixels(450));
                    End();
                    Require(GetWindowRect(hwnd, out var actualAlbum) && actualAlbum.Bottom == album.Bottom
                        && actualAlbum.Right == album.Right && actualAlbum.Bottom - actualAlbum.Top == Pixels(450)
                        && starts == 2 && commits.Count == 2, "album_sizing_inherited_cover_policy");

                    square.SetPlayerLayout(false, false, compactPaging: true, coverBottomResize: true);
                    window.AppWindow.MoveAndResize(new(original.Left, original.Top, side, side));
                    Begin();
                    Apply(6, original, side, side + Pixels(80));
                    window.AppWindow.MoveAndResize(new(original.Left, original.Top, side, side));
                    End();
                    Require(starts == 3 && previews == 2 && cancels == 1 && commits.Count == 2
                        && ordering.TakeLast(2).SequenceEqual(new[] { "cancel", "ended" }), "cancelled_cover_resize_committed_preview");
                    motionSamples.Add(new { name = step, starts, previews, cancels, commits, ordering });
                }
                finally
                {
                    End();
                    square.CoverLyricsResizeStarted -= Started;
                    square.CoverLyricsResizeExpanded -= Expanded;
                    square.CoverLyricsResizeCanceled -= Canceled;
                    square.CoverLyricsResizeCompleted -= Completed;
                    square.MoveSizeEnded -= MoveSizeEnded;
                    square.SetPlayerLayout(false, false);
                }
                void Started() { starts++; ordering.Add("start"); }
                void Expanded() { previews++; ordering.Add("preview"); square.SetPlayerLayout(true, false, coverBottomResize: true); }
                void Canceled()
                {
                    cancels++; ordering.Add("cancel");
                    square.SetPlayerLayout(false, false, compactPaging: true, coverBottomResize: true);
                }
                void Completed(bool expanded)
                {
                    commits.Add(expanded); ordering.Add("commit");
                    square.SetPlayerLayout(expanded, false, compactPaging: !expanded, coverBottomResize: true);
                }
                void MoveSizeEnded() => ordering.Add("ended");
                void Begin() => _ = SendMessage(hwnd, 0x0231, 0, 0);
                void End() => _ = SendMessage(hwnd, 0x0232, 0, 0);
                NativeRect Apply(nuint edge, NativeRect anchor, int width, int height)
                {
                    var proposed = new NativeRect { Left = anchor.Left, Top = anchor.Top, Right = anchor.Left + width, Bottom = anchor.Top + height };
                    _ = SendSizing(hwnd, 0x0214, edge, ref proposed);
                    window.AppWindow.MoveAndResize(new(proposed.Left, proposed.Top, proposed.Right - proposed.Left, proposed.Bottom - proposed.Top));
                    return proposed;
                }
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
                    old_scene_layout_offset = new[] { oldScene.ActualOffset.X, oldScene.ActualOffset.Y },
                    old_cover_layout_offset = new[] { oldCover.ActualOffset.X, oldCover.ActualOffset.Y },
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
