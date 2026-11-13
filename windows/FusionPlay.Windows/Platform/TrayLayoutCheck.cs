using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

/// <summary>Measures the real tray panel without activating it or initializing a receiver.</summary>
internal static class TrayLayoutCheck
{
    [StructLayout(LayoutKind.Sequential)] private struct ClientRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out ClientRect rect);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    private sealed class CheckFailure(string code, object? details = null) : Exception { public string Code { get; } = code; public object? Details { get; } = details; }
    private sealed record Box(double X, double Y, double Width, double Height)
    {
        public double Right => X + Width;
        public double Bottom => Y + Height;
    }
    private sealed record Sample(string Language, int FontSize, bool TwoLines, bool VolumeExpanded,
        Box Cover, Box Image, Box TrackColumn, Box Title, Box Artist, Box Controls, Box PreviousIcon,
        Box VolumeViewport, Box VolumeSlider, double RootWidth, double RootHeight, double ClientWidth, double ClientHeight);
    private const double Tolerance = 1;

    public static async Task Run(string outputFile)
    {
        var queue = DispatcherQueue.GetForCurrentThread();
        nint foreground = GetForegroundWindow(), hwnd = 0;
        bool hidden = true, sameForeground = true;
        string status = "failed", step = "create_hidden_panel", code = "", type = "", hresult = "";
        object? details = null;
        ReceiverController? controller = null;
        TrayWindow? panel = null;
        FrameworkElement? content = null;
        string originalLanguage = L.Language;
        var samples = new List<Sample>();
        var defaultFonts = new List<(TextBlock Element, double Size)>();
        var singleLineHeights = new Dictionary<(string Language, int Font), double>();
        void Require(bool condition, string failure, object? context = null)
        { if (!condition) throw new CheckFailure(failure, context); }
        void Background()
        {
            hidden &= hwnd == 0 || !IsWindowVisible(hwnd);
            sameForeground &= foreground == GetForegroundWindow();
            Require(hidden, "panel_became_visible"); Require(sameForeground, "foreground_changed");
        }
        try
        {
            Require(queue != null, "dispatcher_unavailable");
            await OnUi(queue!, () =>
            {
                Background(); controller = new ReceiverController(queue!);
                panel = new TrayWindow(controller, () => { }, () => { }, () => { }, () => null);
                hwnd = WinRT.Interop.WindowNative.GetWindowHandle(panel);
                Background(); panel.AppWindow.IsShownInSwitchers = false;
                content = panel.Content as FrameworkElement;
                Require(content != null, "panel_content_missing");
                // Keep one hidden window alive throughout the asynchronous check.
                // Closing the last WinUI window would stop the dispatcher before
                // the next fixture or the final report could be written.
                panel.SetVolumeExpanded(true, animate: false); Arrange();
                foreach (var text in Descendants(content!).OfType<TextBlock>()) defaultFonts.Add((text, text.FontSize));
                Background();
            });
            await Settle(queue!);
            foreach (string language in new[] { "zh-Hans", "en" })
            foreach (int font in new[] { 0, 16 })
            foreach (bool twoLines in new[] { false, true })
            {
                step = "apply_hidden_fixture";
                await OnUi(queue!, () =>
                {
                    Background(); L.Language = language;
                    // A small, deterministic metadata fixture tests actual TextBlock
                    // wrapping without invoking private state reducers or native I/O.
                    Find<TextBlock>("TrackTitle").Text = language == "zh-Hans"
                        ? twoLines ? "这是一段需要在紧凑托盘面板中自然换成两行的长歌曲标题" : "歌曲"
                        : twoLines ? "A deliberately long track title that naturally wraps onto a second line in this tray panel" : "Song";
                    Find<TextBlock>("TrackArtist").Text = language == "zh-Hans" ? "歌手 · 专辑" : "Artist · Album";
                    foreach (var (text, size) in defaultFonts) text.FontSize = font > 0 ? font : size;
                    Background();
                });
                await Settle(queue!);
                foreach (bool expanded in new[] { false, true })
                {
                    step = "measure_hidden_layout";
                    await OnUi(queue!, () => { Background(); panel!.SetVolumeExpanded(expanded, animate: false); Arrange(); Background(); });
                    await Settle(queue!);
                    step = "inspect_hidden_layout";
                    await OnUi(queue!, () => { Arrange(); samples.Add(Inspect(language, font, twoLines, expanded)); });
                }
            }
            status = "passed";
        }
        catch (Exception error)
        {
            code = error is CheckFailure failure ? failure.Code : "layout_api_failed";
            details = (error as CheckFailure)?.Details; type = error.GetType().Name; hresult = error.HResult.ToString("X8");
        }
        finally
        {
            try
            {
                if (controller != null) await controller.DisposeAsync();
            }
            catch (Exception error)
            {
                status = "failed"; step = "cleanup_hidden_panel"; code = error is CheckFailure failure ? failure.Code : "cleanup_failed";
                details = (error as CheckFailure)?.Details; type = error.GetType().Name; hresult = error.HResult.ToString("X8");
            }
            void WriteReport()
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputFile))!);
                File.WriteAllText(outputFile, JsonSerializer.Serialize(new
                {
                    status, step, failure_code = code, exception_type = type, hresult, failure_details = details,
                    panel_remained_hidden = hidden, foreground_unchanged = sameForeground,
                    receiver_initialized = false, native_audio_started = false, system_media_session_created = false,
                    tolerance_dips = Tolerance, samples,
                    scope = "real_tray_hidden_xaml_measurement; native_corner_radius_and_physical_interaction_not_tested"
                }, new JsonSerializerOptions { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals }));
            }
            try
            {
                if (queue != null) await OnUi(queue, () =>
                {
                    try { Background(); L.Language = originalLanguage; }
                    catch (Exception error)
                    {
                        status = "failed"; step = "final_background_assertion";
                        code = error is CheckFailure failure ? failure.Code : "final_assertion_failed";
                        details = (error as CheckFailure)?.Details; type = error.GetType().Name; hresult = error.HResult.ToString("X8");
                    }
                    try { WriteReport(); }
                    finally { panel?.Close(); panel = null; hwnd = 0; }
                });
                else WriteReport();
            }
            catch { }
        }

        T Find<T>(string name) where T : FrameworkElement
            => Descendants(content!).OfType<T>().FirstOrDefault(element => element.Name == name)
                ?? throw new CheckFailure("named_element_missing", new { element = name });
        void Arrange()
        {
            Require(content != null && panel != null, "panel_unavailable");
            // Multiple bounded passes let the cover follow the right column's
            // natural measured height without relying on a visible Loaded event.
            for (int pass = 0; pass < 3; pass++)
            {
                content!.Measure(new Size(340, double.PositiveInfinity));
                double height = Math.Ceiling(content.DesiredSize.Height);
                Require(double.IsFinite(height) && height > 0, "panel_desired_height_invalid");
                content.Arrange(new Rect(0, 0, 340, height)); content.UpdateLayout();
                panel!.RefreshLayout();
            }
        }
        Box Bounds(FrameworkElement element)
        {
            var bounds = element.TransformToVisual(content!).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            return new(bounds.X, bounds.Y, bounds.Width, bounds.Height);
        }
        Sample Inspect(string language, int font, bool twoLines, bool expanded)
        {
            Background();
            var artwork = Find<Button>("ArtworkButton"); var image = Find<Image>("AlbumCover");
            var column = Find<FrameworkElement>("TrackColumn"); var title = Find<TextBlock>("TrackTitle"); var artist = Find<TextBlock>("TrackArtist");
            var controls = Find<FrameworkElement>("TransportControls"); var previous = Find<Button>("PreviousButton");
            var viewport = Find<FrameworkElement>("VolumeViewport"); var slider = Find<Slider>("VolumeSlider");
            var icon = previous.Content as FrameworkElement;
            Require(icon != null, "previous_icon_missing");
            var a = Bounds(artwork); var i = Bounds(image); var c = Bounds(column); var t = Bounds(title); var ar = Bounds(artist); var tr = Bounds(controls); var pi = Bounds(icon!); var v = Bounds(viewport); var s = Bounds(slider);
            var geometry = new { cover = a, image = i, column = c, title = t, artist = ar, controls = tr, previous_icon = pi, volume_viewport = v, volume_slider = s };
            Require(a.Width > 0 && Math.Abs(a.Width - a.Height) <= Tolerance, "cover_not_square", geometry);
            Require(Math.Abs(i.Width - i.Height) <= Tolerance && Math.Abs(i.Width - a.Width) <= Tolerance && Math.Abs(i.Height - a.Height) <= Tolerance, "cover_image_not_filling_square", geometry);
            Require(Math.Abs(a.Height - c.Height) <= Tolerance && Math.Abs(a.Y - c.Y) <= Tolerance && Math.Abs(a.Bottom - c.Bottom) <= Tolerance, "cover_column_height_or_edges_mismatch", geometry);
            Require(Math.Abs(t.X - ar.X) <= Tolerance && Math.Abs(t.X - tr.X) <= Tolerance && Math.Abs(t.X - pi.X) <= Tolerance, "track_controls_not_left_aligned", geometry);
            Require(a.X > 0 && Math.Abs(a.X - a.Y) <= Tolerance && Math.Abs(content!.ActualWidth - c.Right - a.X) <= Tolerance, "header_insets_not_symmetric", geometry);
            Require(viewport.IsHitTestVisible == expanded, "volume_hit_testing_mismatch", geometry);
            if (expanded)
            {
                Require(Math.Abs(v.Width - 104) <= Tolerance, "expanded_volume_width_mismatch", geometry);
                Require(s.Width > 0 && s.X >= v.X - Tolerance && s.Right <= v.Right + Tolerance && s.Y >= v.Y - Tolerance && s.Bottom <= v.Bottom + Tolerance, "expanded_volume_is_clipped", geometry);
            }
            else Require(v.Width <= Tolerance, "collapsed_volume_has_width", geometry);
            if (twoLines)
                Require(singleLineHeights.TryGetValue((language, font), out double shortHeight) && t.Height > shortHeight + Tolerance, "long_title_did_not_wrap", geometry);
            else singleLineHeights[(language, font)] = t.Height;
            foreach (var element in new[] { (FrameworkElement)artwork, column, Find<FrameworkElement>("VolumeButton"), Find<Button>("SettingsButton"), Find<Button>("QuitButton") })
            {
                var box = Bounds(element);
                Require(box.X >= -Tolerance && box.Y >= -Tolerance && box.Right <= content!.ActualWidth + Tolerance && box.Bottom <= content.ActualHeight + Tolerance, "visible_control_overflows_content", new { element = element.Name, bounds = box, content = new[] { content!.ActualWidth, content.ActualHeight } });
            }
            Require(GetClientRect(hwnd, out var client), "client_bounds_unavailable");
            double scale = content!.XamlRoot?.RasterizationScale ?? Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
            double clientWidth = (client.Right - client.Left) / scale, clientHeight = (client.Bottom - client.Top) / scale;
            Require(content.ActualWidth <= clientWidth + Tolerance && content.ActualHeight <= clientHeight + Tolerance, "content_overflows_window_client", new { content = new[] { content.ActualWidth, content.ActualHeight }, client = new[] { clientWidth, clientHeight } });
            Background();
            return new(language, font, twoLines, expanded, a, i, c, t, ar, tr, pi, v, s, content.ActualWidth, content.ActualHeight, clientWidth, clientHeight);
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
        if (!queue.TryEnqueue(() => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } })) completion.SetException(new CheckFailure("dispatcher_enqueue_failed"));
        return completion.Task;
    }
    private static async Task Settle(DispatcherQueue queue)
    {
        await OnUi(queue, () => { }); await Task.Delay(60); await OnUi(queue, () => { });
    }
}
