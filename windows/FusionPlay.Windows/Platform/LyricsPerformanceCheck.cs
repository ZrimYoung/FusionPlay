using System.Collections;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using FusionPlay.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace FusionPlay.Windows.Platform;

/// <summary>Repeatable hidden workload, also compatible with the preview14/15587ef player.</summary>
internal static class LyricsPerformanceCheck
{
    internal static List<string> UnhandledErrors { get; } = [];
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private const int CadenceMs = 16, MaximumPending = 4;
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] private static extern nint SendMessage(nint window, uint message, nuint argument, nint data);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] private static extern nint SendSizing(nint window, uint message, nuint argument, ref NativeRect rect);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    private readonly record struct TickSample(int Index, double ProducerLatenessMs, double QueueDelayMs, double ActionMs, double Width, double Height);
    private sealed class CheckFailure(string code) : Exception(code);

    public static async Task Run(string directory)
    {
        Directory.CreateDirectory(directory);
        var queue = DispatcherQueue.GetForCurrentThread();
        var windows = new List<nint>(); var phases = new List<object>(); var cleanupErrors = new List<string>();
        Window? anchor = null; MainWindow? main = null; ReceiverController? controller = null;
        nint mainHwnd = 0, initialForeground = GetForegroundWindow();
        string status = "failed", step = "resources_and_anchor", failure = "", detail = "", originalLanguage = L.Language;
        bool hidden = true, foregroundNotTaken = true, foregroundUnchanged = true, preferencesCaptured = false, preferencesRestored = false;
        var store = new PortableStore(AppContext.BaseDirectory); string preferenceFile = Path.Combine(store.Data, "ui-preferences.json");
        string fixtureDirectory = Path.Combine(directory, "temporary-preferences-" + Guid.NewGuid().ToString("N"));
        string fixturePreferenceFile = Path.Combine(fixtureDirectory, "ui-preferences.json");
        byte[]? originalPreferenceBytes = null;
        long rootLayouts = 0, rootSizes = 0, lyricSizes = 0, scrollChanges = 0;
        ulong revision = 0;
        FrameworkElement? root = null;
        var hookedViews = new List<LyricsView>(); var hookedScrollers = new List<ScrollViewer>();
        using var process = Process.GetCurrentProcess();
        var accept = typeof(ReceiverController).GetMethod("Accept", Private);
        var synthetic = new ReceiverSnapshot
        {
            ControlsAvailable = true, Phase = ReceiverPhase.Playing, TrackId = "performance-fixture",
            Title = "Synthetic performance fixture", Artist = "Generated media", DurationMs = 180_000, PositionMs = 0,
            ArtworkUrl = "fixture:performance-cover",
            LyricsText = string.Join('\n', Enumerable.Range(0, 300).Select(index =>
                $"[{index / 120:00}:{index % 120 / 2:00}.{index % 2 * 500:000}]Synthetic lyric line {index:000} for scrolling and resize\n"
                + $"[{index / 120:00}:{index % 120 / 2:00}.{index % 2 * 500:000}]合成双语歌词 · 第 {index:000} 行，仅供本地性能检查"))
        };

        object? Field(object? instance, string name) => instance?.GetType().GetField(name, Private)?.GetValue(instance);
        void Require(bool value, string code) { if (!value) throw new CheckFailure(code); }
        void Background()
        {
            nint current = GetForegroundWindow();
            hidden &= windows.All(window => !IsWindowVisible(window)); foregroundNotTaken &= !windows.Contains(current); foregroundUnchanged &= current == initialForeground;
            Require(hidden, "performance_window_became_visible"); Require(foregroundNotTaken, "performance_window_took_foreground");
            if (controller != null) Require(Field(controller, "native") == null && Field(controller, "polling") == null, "performance_started_receiver");
        }
        void Track(Window window) { window.AppWindow.IsShownInSwitchers = false; windows.Add(WinRT.Interop.WindowNative.GetWindowHandle(window)); Background(); }
        void RootLayout(object? sender, object args) => rootLayouts++;
        void RootSize(object sender, SizeChangedEventArgs args) => rootSizes++;
        void LyricSize(object sender, SizeChangedEventArgs args) => lyricSizes++;
        void ScrollChange(object? sender, ScrollViewerViewChangedEventArgs args) => scrollChanges++;
        LyricsView View(bool compact) => Descendants(root!).OfType<LyricsView>().FirstOrDefault(view =>
            ReferenceEquals(view, Field(main, compact ? "miniLyrics" : "expandedLyrics")))
            ?? (root!.FindName(compact ? "MiniLyricsHost" : "ExpandedLyricsHost") as Panel)?.Children.OfType<LyricsView>().FirstOrDefault()
            ?? throw new CheckFailure("performance_lyrics_view_missing");
        ScrollViewer? Scroller(LyricsView view) => Field(view, "scroller") as ScrollViewer ?? Descendants(view).OfType<ScrollViewer>().FirstOrDefault();
        void Hook()
        {
            foreach (var view in Descendants(root!).OfType<LyricsView>())
            {
                if (!hookedViews.Contains(view)) { view.SizeChanged += LyricSize; hookedViews.Add(view); }
                if (Scroller(view) is { } scroll && !hookedScrollers.Contains(scroll)) { scroll.ViewChanged += ScrollChange; hookedScrollers.Add(scroll); }
            }
        }
        object Observe(LyricsView view)
        {
            object[]? rows = Field(view, "realized") is IEnumerable realizedRows ? realizedRows.Cast<object>().ToArray() : null;
            int realized = rows?.Length ?? -1;
            var counters = new Dictionary<string, double>();
            foreach (var instance in new object[] { main!, view })
            foreach (var member in instance.GetType().GetFields(Private))
            {
                string name = member.Name;
                if (!name.Contains("count", StringComparison.OrdinalIgnoreCase) && !name.Contains("total", StringComparison.OrdinalIgnoreCase)) continue;
                object? value = member.GetValue(instance);
                if (value is int or long or uint or ulong or double or float)
                {
                    double number = Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture);
                    if (double.IsFinite(number)) counters[instance.GetType().Name + "." + name] = number;
                }
            }
            int? compositionRows = null, faultedRows = null;
            if (rows?.FirstOrDefault()?.GetType().GetProperty("UsesCompositionSurface", Private) != null)
            {
                compositionRows = rows.Count(row => row.GetType().GetProperty("UsesCompositionSurface", Private)?.GetValue(row) is true);
                faultedRows = rows.Count(row => Field(row, "faulted") is true);
                foreach (string name in new[] { "GlyphRasterizations", "SurfaceCreations", "EdgeUpdates" })
                    counters["LyricsRows." + name] = rows.Sum(row => Convert.ToDouble(row.GetType().GetProperty(name, Private)?.GetValue(row) ?? 0));
            }
            return new
            {
                presentation_loaded = Field(view, "loaded") as bool?, realized_rows = realized,
                composition_rows = compositionRows, faulted_rows = faultedRows,
                scroll_viewer_available = Scroller(view) != null, scrollable_height = Scroller(view)?.ScrollableHeight ?? 0,
                actual_width = view.ActualWidth, actual_height = view.ActualHeight, optional_numeric_counters = counters
            };
        }
        void Materialize()
        {
            Require(GetClientRect(mainHwnd, out var client), "performance_client_missing");
            double scale = root!.XamlRoot?.RasterizationScale ?? Math.Max(96, GetDpiForWindow(mainHwnd)) / 96.0;
            double width = (client.Right - client.Left) / scale, height = (client.Bottom - client.Top) / scale;
            for (int pass = 0; pass < 3; pass++)
            {
                foreach (var control in Descendants(root).OfType<Control>().ToArray()) control.ApplyTemplate();
                root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
            }
            Hook(); Background();
        }
        void Publish(ulong position)
        {
            Require(accept!.Invoke(controller, [new PollResult(++revision, synthetic with { PositionMs = position })]) is true, "performance_source_not_accepted");
        }
        async Task Prepare(int width, int height)
        {
            await OnUi(queue!, () => { Background(); WindowSizing.ResizeContent(main!, width, height); });
            await Task.Delay(600);
            await OnUi(queue!, Materialize); await Task.Delay(200); await OnUi(queue!, () => { Hook(); Background(); });
        }
        async Task Measure(string name, int requested, LyricsView view, Action<int> action)
        {
            var samples = new TickSample[requested]; int used = 0, pending = 0, skipped = 0, stopped = 0;
            bool producerDone = false; Exception? phaseError = null;
            var drained = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            object? before = null, after = null;
            long initialLayouts = 0, initialSizes = 0, initialLyricSizes = 0, initialScrollChanges = 0;
            await OnUi(queue!, () =>
            {
                Background(); Hook(); before = Observe(view);
                initialLayouts = rootLayouts; initialSizes = rootSizes; initialLyricSizes = lyricSizes; initialScrollChanges = scrollChanges;
            });
            process.Refresh(); var cpu = process.TotalProcessorTime; long allocated = GC.GetTotalAllocatedBytes(precise: false);
            long privateBytes = process.PrivateMemorySize64;
            int gen0 = GC.CollectionCount(0), gen1 = GC.CollectionCount(1), gen2 = GC.CollectionCount(2);
            long started = Stopwatch.GetTimestamp();
            try
            {
                await Task.Run(async () =>
                {
                    try
                    {
                        for (int index = 0; index < requested && Volatile.Read(ref stopped) == 0; index++)
                        {
                            long due = started + (long)(index * CadenceMs / 1_000d * Stopwatch.Frequency);
                            double wait = Milliseconds(due - Stopwatch.GetTimestamp());
                            if (wait > 0) await Task.Delay(TimeSpan.FromMilliseconds(wait));
                            if (Volatile.Read(ref pending) >= MaximumPending) { skipped++; continue; }
                            long enqueued = Stopwatch.GetTimestamp(); int frame = index;
                            Interlocked.Increment(ref pending);
                            if (!queue!.TryEnqueue(() =>
                            {
                                long entered = Stopwatch.GetTimestamp();
                                try
                                {
                                    if (Volatile.Read(ref stopped) == 0)
                                    {
                                        Background(); action(frame);
                                        long ended = Stopwatch.GetTimestamp();
                                        samples[used++] = new(frame, Math.Max(0, Milliseconds(enqueued - due)), Milliseconds(entered - enqueued), Milliseconds(ended - entered), root!.ActualWidth, root.ActualHeight);
                                    }
                                }
                                catch (Exception error) { phaseError = error; Interlocked.Exchange(ref stopped, 1); }
                                finally { if (Interlocked.Decrement(ref pending) == 0 && Volatile.Read(ref producerDone)) drained.TrySetResult(); }
                            }))
                            { Interlocked.Decrement(ref pending); throw new CheckFailure("performance_dispatcher_rejected_sample"); }
                        }
                    }
                    finally { Volatile.Write(ref producerDone, true); if (Volatile.Read(ref pending) == 0) drained.TrySetResult(); }
                });
                await drained.Task.WaitAsync(TimeSpan.FromSeconds(15));
                await OnUi(queue!, () => { Background(); }, DispatcherQueuePriority.Low);
                await OnUi(queue!, () => { Background(); after = Observe(view); }, DispatcherQueuePriority.Low);
                if (phaseError != null) throw phaseError;
            }
            finally { Interlocked.Exchange(ref stopped, 1); }
            long finished = Stopwatch.GetTimestamp(); process.Refresh();
            long allocatedDelta = GC.GetTotalAllocatedBytes(precise: false) - allocated;
            long privateDelta = process.PrivateMemorySize64 - privateBytes;
            int gen0Delta = GC.CollectionCount(0) - gen0, gen1Delta = GC.CollectionCount(1) - gen1, gen2Delta = GC.CollectionCount(2) - gen2;
            var taken = samples.Take(used).ToArray(); double elapsed = Milliseconds(finished - started);
            double cpuMs = (process.TotalProcessorTime - cpu).TotalMilliseconds;
            phases.Add(new
            {
                name, requested_samples = requested, completed_samples = used, skipped_pending_limit = skipped, maximum_pending = MaximumPending,
                target_cadence_ms = CadenceMs, elapsed_ms = elapsed, completed_samples_per_second = elapsed > 0 ? used * 1_000d / elapsed : 0,
                queue_delay_ms = Distribution(taken.Select(sample => sample.QueueDelayMs)), ui_action_ms = Distribution(taken.Select(sample => sample.ActionMs)),
                producer_lateness_ms = Distribution(taken.Select(sample => sample.ProducerLatenessMs)),
                cpu_ms = cpuMs, cpu_percent_one_core = elapsed > 0 ? cpuMs / elapsed * 100 : 0,
                cpu_percent_machine = elapsed > 0 ? cpuMs / elapsed / Environment.ProcessorCount * 100 : 0,
                managed_allocated_bytes = allocatedDelta, private_bytes_delta = privateDelta,
                gen0_collections = gen0Delta, gen1_collections = gen1Delta, gen2_collections = gen2Delta,
                root_layout_updated = rootLayouts - initialLayouts, root_size_changed = rootSizes - initialSizes,
                lyric_size_changed = lyricSizes - initialLyricSizes, native_scroll_view_changed = scrollChanges - initialScrollChanges,
                before, after, samples = taken
            });
            Require(used > 0, "performance_no_ui_samples_completed");
            // This pause separates scenarios and is intentionally outside their metrics.
            await Task.Delay(180);
        }
        async Task MeasureResize(string name, LyricsView view, Action<int> resize)
        {
            await OnUi(queue!, () =>
            {
                Background();
                Require(GetWindowRect(mainHwnd, out var bounds), "performance_native_resize_bounds_missing");
                // Enter the native border-resize path on this hidden HWND before
                // delivering the same stream of size changes on every build.
                _ = SendMessage(mainHwnd, 0x0231, 0, 0); // WM_ENTERSIZEMOVE
                _ = SendSizing(mainHwnd, 0x0214, 8, ref bounds); // WM_SIZING, WMSZ_BOTTOMRIGHT
            });
            try { await Measure(name, 150, view, resize); }
            finally { await OnUi(queue!, () => { _ = SendMessage(mainHwnd, 0x0232, 0, 0); }); }
        }

        try
        {
            Require(queue != null && accept != null, "performance_required_api_missing");
            await OnUi(queue!, () =>
            {
                Require(Application.Current.Resources != null, "performance_resources_unavailable");
                anchor = new Window { Title = "FusionPlay Hidden Performance Anchor", Content = new Grid() }; Track(anchor);
                originalPreferenceBytes = File.Exists(preferenceFile) ? File.ReadAllBytes(preferenceFile) : null; preferencesCaptured = true;
                // Seed before constructing the controller: never parse a user's presentation
                // configuration in this fixture. Restore the exact prior bytes in finally.
                var fixture = new UiPreferencesStore(fixtureDirectory);
                var value = new UiPreferences { AlwaysShowControls = true, ShowTransport = true, ShowProgress = true, LyricsDisplayMode = "automatic" };
                fixture.Update(value);
                Directory.CreateDirectory(store.Data); File.Copy(fixturePreferenceFile, preferenceFile, overwrite: true);
            });
            byte[] coverBytes = await CreateCoverAsync();
            BitmapImage cover;
            using (var stream = new InMemoryRandomAccessStream())
            {
                using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(coverBytes); await writer.StoreAsync(); }
                stream.Seek(0); cover = new BitmapImage(); await cover.SetSourceAsync(stream);
            }
            Require(queue != null && accept != null && anchor != null && preferencesCaptured, "performance_initialization_incomplete");
            await OnUi(queue!, () =>
            {
                step = "create_controller_and_hidden_player";
                controller = new ReceiverController(queue!);
                main = new MainWindow(controller, () => { }); Track(main); mainHwnd = WinRT.Interop.WindowNative.GetWindowHandle(main);
                root = (FrameworkElement)main.Content; root.LayoutUpdated += RootLayout; root.SizeChanged += RootSize;
                typeof(ReceiverController).GetProperty(nameof(ReceiverController.Initialized))!.SetValue(controller, true);
                typeof(ReceiverController).GetProperty(nameof(ReceiverController.Artwork))!.SetValue(controller, cover);
                typeof(ReceiverController).GetProperty(nameof(ReceiverController.ArtworkBytes))!.SetValue(controller, coverBytes);
                typeof(ReceiverController).GetField("artworkKey", Private)!.SetValue(controller, synthetic.TrackId + "|" + synthetic.ArtworkUrl);
                Publish(0);
            });
            step = "parse_and_warmup";
            for (int attempt = 0; attempt < 150; attempt++)
            {
                bool ready = false; await OnUi(queue!, () => { Background(); ready = !controller!.LyricsLoading && controller.Lyrics.HasLyrics; });
                if (ready) break; await Task.Delay(20);
            }
            await OnUi(queue!, () => Require(controller!.Lyrics.Lines.Count == 300, "performance_synthetic_document_not_ready"));
            await Prepare(420, 640);
            step = "mini_continuous_resize";
            await MeasureResize(step, View(true), frame =>
            {
                int width = 390 + (int)Math.Round(Math.Sin(frame * Math.PI / 36) * 60);
                WindowSizing.ResizeContent(main!, width, width + 180);
            });
            await Prepare(840, 600);
            step = "expanded_continuous_resize";
            await MeasureResize(step, View(false), frame =>
            {
                int width = 840 + (int)Math.Round(Math.Sin(frame * Math.PI / 40) * 100), height = 550 + (int)Math.Round(Math.Cos(frame * Math.PI / 40) * 70);
                WindowSizing.ResizeContent(main!, width, height);
            });
            await OnUi(queue!, () => controller!.Preferences.Update(controller.Preferences.Value with { LyricsDisplayMode = "never" }));
            await Prepare(840, 600);
            step = "cover_only_continuous_resize";
            await MeasureResize(step, View(false), frame =>
            {
                int width = 840 + (int)Math.Round(Math.Sin(frame * Math.PI / 40) * 100);
                int height = 550 + (int)Math.Round(Math.Cos(frame * Math.PI / 40) * 70);
                WindowSizing.ResizeContent(main!, width, height);
            });
            await OnUi(queue!, () => controller!.Preferences.Update(controller.Preferences.Value with { LyricsDisplayMode = "automatic" }));
            await Prepare(840, 600);
            step = "source_position_and_automatic_follow";
            await Measure(step, 180, View(false), frame => Publish((ulong)frame * 100));
            await Prepare(840, 600);
            step = "native_manual_scroll";
            var scrollingView = View(false); var scroller = Scroller(scrollingView);
            Require(scroller != null && scroller.ScrollableHeight > 0, "performance_scroll_viewport_unavailable");
            await OnUi(queue!, () => typeof(LyricsView).GetMethod("BeginBrowsing", Private)?.Invoke(scrollingView, null));
            await Measure(step, 180, scrollingView, frame =>
            {
                double target = scroller!.ScrollableHeight * (.5 + .45 * Math.Sin(frame * Math.PI / 80));
                scroller.ChangeView(null, target, null, disableAnimation: false);
            });
            await OnUi(queue!, () => typeof(LyricsView).GetMethod("ReturnToCurrent", Private)?.Invoke(scrollingView, [scrollingView, new RoutedEventArgs()]));
            Background(); Require(UnhandledErrors.Count == 0, "performance_unhandled_errors"); status = "passed"; step = "complete";
        }
        catch (Exception error) { status = "failed"; failure = error is CheckFailure ? error.Message : error.GetType().Name; detail = error.ToString(); }
        finally
        {
            try
            {
                if (queue != null) await OnUi(queue, () =>
                {
                    foreach (var view in hookedViews) view.SizeChanged -= LyricSize;
                    foreach (var scroll in hookedScrollers) scroll.ViewChanged -= ScrollChange;
                    if (root != null) { root.LayoutUpdated -= RootLayout; root.SizeChanged -= RootSize; }
                    if (main != null) { main.AllowClose = true; main.Close(); main = null; } Background();
                });
            }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            try { if (controller != null) { await controller.DisposeAsync(); controller = null; } }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            try
            {
                if (preferencesCaptured)
                {
                    if (originalPreferenceBytes != null) File.WriteAllBytes(preferenceFile, originalPreferenceBytes);
                    else if (File.Exists(preferenceFile)) File.Delete(preferenceFile);
                    preferencesRestored = originalPreferenceBytes == null ? !File.Exists(preferenceFile) : File.ReadAllBytes(preferenceFile).AsSpan().SequenceEqual(originalPreferenceBytes);
                }
                else preferencesRestored = true;
                if (File.Exists(fixturePreferenceFile)) File.Delete(fixturePreferenceFile);
                if (Directory.Exists(fixtureDirectory) && !Directory.EnumerateFileSystemEntries(fixtureDirectory).Any()) Directory.Delete(fixtureDirectory);
                L.Language = originalLanguage;
            }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            void Finish()
            {
                try { Background(); Require(preferencesRestored && UnhandledErrors.Count == 0 && cleanupErrors.Count == 0, "performance_cleanup_or_unhandled_errors"); }
                catch (Exception error) { status = "failed"; failure = error.Message; }
                try
                {
                    File.WriteAllText(Path.Combine(directory, "lyrics-performance-check.json"), JsonSerializer.Serialize(new
                    {
                        status, step, failure_code = failure, exception_detail = detail, phases, target_cadence_ms = CadenceMs,
                        hidden_windows = hidden, no_test_window_became_foreground = foregroundNotTaken, foreground_unchanged_observed = foregroundUnchanged,
                        preferences_restored = preferencesRestored, native_receiver_created = false, receiver_polling_started = false,
                        shell_media_session_created = false, single_instance_notification_sent = false, initialized_flag_is_fixture = true,
                        synthetic_document_lines = 300, private_source_text_recorded = false, processor_count = Environment.ProcessorCount,
                        synthetic_cover_only = true, performance_threshold_asserted = false, manual_browse_expiry_waited = false,
                        stopwatch_frequency = Stopwatch.Frequency, runtime = Environment.Version.ToString(), unhandled_errors = UnhandledErrors, cleanup_errors = cleanupErrors,
                        scope = "hidden_UI_queue_latency_layout_events_process_CPU_managed_allocations; excludes_setup_warmup_and_interphase_pause; does_not_measure_visible_DWM_GPU_presentation_or_replace_functional_checks"
                    }, new JsonSerializerOptions { WriteIndented = true }));
                }
                finally { anchor?.Close(); }
            }
            if (queue == null || queue.HasThreadAccess) Finish(); else await OnUi(queue, Finish);
        }
    }

    private static object Distribution(IEnumerable<double> values)
    {
        var sorted = values.Order().ToArray();
        double Percentile(double percentile) => sorted.Length == 0 ? 0 : sorted[(int)Math.Ceiling((sorted.Length - 1) * percentile)];
        return new { count = sorted.Length, mean = sorted.Length == 0 ? 0 : sorted.Average(), p50 = Percentile(.5), p95 = Percentile(.95), p99 = Percentile(.99), max = sorted.Length == 0 ? 0 : sorted[^1] };
    }
    private static async Task<byte[]> CreateCoverAsync()
    {
        const uint side = 192; var pixels = new byte[side * side * 4];
        for (int y = 0; y < side; y++) for (int x = 0; x < side; x++)
        {
            int offset = (y * (int)side + x) * 4;
            pixels[offset] = (byte)(60 + x / 2); pixels[offset + 1] = (byte)(70 + y / 2); pixels[offset + 2] = (byte)(210 - x / 2); pixels[offset + 3] = 255;
        }
        using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, side, side, 96, 96, pixels); await encoder.FlushAsync();
        var bytes = new byte[checked((int)stream.Size)]; using var reader = new DataReader(stream.GetInputStreamAt(0)); await reader.LoadAsync((uint)bytes.Length); reader.ReadBytes(bytes); return bytes;
    }
    private static double Milliseconds(long ticks) => ticks * 1_000d / Stopwatch.Frequency;
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++) foreach (var child in Descendants(VisualTreeHelper.GetChild(root, index))) yield return child;
    }
    private static Task OnUi(DispatcherQueue queue, Action action, DispatcherQueuePriority priority = DispatcherQueuePriority.Normal)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(priority, () => { try { action(); completion.SetResult(); } catch (Exception error) { completion.SetException(error); } })) completion.TrySetException(new CheckFailure("performance_dispatcher_unavailable"));
        return completion.Task;
    }
}
