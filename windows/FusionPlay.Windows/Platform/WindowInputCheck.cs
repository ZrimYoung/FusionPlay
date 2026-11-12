using System.Runtime.InteropServices;
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
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out NativeRect rect);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    private sealed class CheckFailure(string code, object? details = null) : Exception { public string Code { get; } = code; public object? Details { get; } = details; }
    private sealed record Sample(double RequestedDips, int WidthPixels, int HeightPixels, Dictionary<string, int> RegionCounts, long CoveredPixels);

    public static async Task Run(string outputFile)
    {
        var queue = DispatcherQueue.GetForCurrentThread();
        nint foreground = GetForegroundWindow(), hwnd = 0;
        Window? window = null;
        ISquareWindow? square = null;
        InputNonClientPointerSource? input = null;
        RectInt32 hole = default;
        string step = "create_hidden_window", status = "failed", failureCode = "", exceptionType = "", hresult = "";
        object? failureDetails = null;
        bool visibilityPreserved = true, foregroundPreserved = true;
        var samples = new List<Sample>();
        void Require(bool condition, string code) { if (!condition) throw new CheckFailure(code); }
        void RequireBackground()
        {
            visibilityPreserved &= hwnd == 0 || !IsWindowVisible(hwnd);
            foregroundPreserved &= GetForegroundWindow() == foreground;
            Require(visibilityPreserved, "window_became_visible");
            Require(foregroundPreserved, "foreground_changed");
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
            await OnUi(queue!, () => samples.Add(Inspect(420)));
            foreach (double size in new[] { 360.0, 520.0 })
            {
                step = "hidden_resize";
                await OnUi(queue!, () => { RequireBackground(); WindowSizing.ResizeContent(window!, size, size); RequireBackground(); });
                await Drain(queue!);
                step = "resized_region_registration";
                await OnUi(queue!, () => samples.Add(Inspect(size)));
            }
            Require(samples.Select(sample => sample.WidthPixels).Distinct().Count() >= 2, "insufficient_resize_range");
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
                        try { square?.Dispose(); }
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
                    window_remained_hidden = visibilityPreserved, foreground_unchanged = foregroundPreserved,
                    receiver_created = false, samples,
                    scope = "hidden_sdk_region_registration_and_square_resize; physical_pointer_interaction_not_tested"
                }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch { }
        }

        Sample Inspect(double requested)
        {
            RequireBackground();
            Require(GetClientRect(hwnd, out var client), "client_bounds_unavailable");
            int width = client.Right - client.Left, height = client.Bottom - client.Top;
            Require(width > 0 && width == height, "client_aspect_not_square");
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
            return new(requested, width, height, counts, area);
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
