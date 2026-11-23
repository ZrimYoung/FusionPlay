using System.Reflection;
using System.Runtime.InteropServices;
using System.Diagnostics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using System.Text.Json;
using FusionPlay.Core;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace FusionPlay.Windows.Platform;

/// <summary>Opt-in hidden production-player checks with synthetic, memory-only media.</summary>
internal static class LyricsPlayerCheck
{
    internal static List<string> UnhandledErrors { get; } = [];
    private const BindingFlags Private = BindingFlags.NonPublic | BindingFlags.Instance;
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetClientRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] private static extern nint SendMessage(nint window, uint message, nuint argument, nint data);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] private static extern nint SendSizing(nint window, uint message, nuint argument, ref NativeRect rect);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    private sealed class CheckFailure(string code) : Exception(code);
    private sealed record Box(double X, double Y, double Width, double Height);
    private sealed record PixelBox(int X, int Y, int Width, int Height);
    private static PixelBox Pixels(RectInt32 rectangle) => new(rectangle.X, rectangle.Y, rectangle.Width, rectangle.Height);

    public static async Task Run(string directory)
    {
        Directory.CreateDirectory(directory);
        var queue = DispatcherQueue.GetForCurrentThread();
        nint foreground = GetForegroundWindow(), mainHwnd = 0;
        var handles = new List<nint>();
        var cases = new List<string>(); var layouts = new List<object>(); var captures = new List<object>(); var animationSamples = new List<object>(); var cleanupErrors = new List<string>();
        var cachedBackdrops = new Dictionary<string, (object Instance, object? Current, object? Layer)>();
        Window? anchor = null, componentWindow = null, policyWindow = null;
        MainWindow? main = null; SettingsWindow? settings = null;
        ReceiverController? model = null; LyricsView? component = null; ISquareWindow? policy = null;
        bool hidden = true, focus = true, foregroundNotTaken = true, preferencesCaptured = false, preferencesRestored = false;
        bool presenterObjectCreated = false, componentRowWasRealized = false, initializedFixture = false;
        string status = "failed", step = "create_hidden_anchor", failure = "", exception = "", hresult = "", exceptionDetail = "";
        string originalLanguage = L.Language;
        var store = new PortableStore(AppContext.BaseDirectory); string preferencesPath = Path.Combine(store.Data, "ui-preferences.json");
        byte[]? originalPreferences = null; HashSet<string> originalInvalid = [];
        byte[] coverBytes = []; BitmapImage? cover = null;
        ulong revision = 0;
        string timed = "[ti:Synthetic fixture]\n[00:00.000]A quiet beginning\n[00:00.000]合成歌词 · 开始\n[00:02.000]Blue turns into gold\n[00:02.000]蓝色渐渐变成金色\n[00:04.000]A line for this moment\n[00:06.000]Music connects the room\n[00:08.000]合成的下一句\n[00:10.000]The final fixture line";
        var source = new ReceiverSnapshot { ControlsAvailable = true, Phase = ReceiverPhase.Playing, TrackId = "lyrics-fixture", Title = "Synthetic fixture", Artist = "Generated test media", DurationMs = 30_000, PositionMs = 2_000, LyricsText = "", ArtworkUrl = "fixture:color-blocks" };

        void Require(bool value, string code) { if (!value) throw new CheckFailure(code); }
        object? Field(object instance, string name) => instance.GetType().GetField(name, Private)?.GetValue(instance);
        void SetProperty(object instance, string name, object value) => instance.GetType().GetProperty(name)!.SetValue(instance, value);
        void Background()
        {
            nint current = GetForegroundWindow();
            hidden &= handles.All(handle => !IsWindowVisible(handle)); focus &= current == foreground;
            foregroundNotTaken &= !handles.Contains(current);
            Require(hidden, "lyrics_check_window_became_visible"); Require(foregroundNotTaken, "lyrics_check_took_foreground");
            if (model != null) Require(Field(model, "native") == null && Field(model, "polling") == null, "lyrics_check_created_receiver_or_polling");
        }
        void Track(Window window) { window.AppWindow.IsShownInSwitchers = false; handles.Add(WinRT.Interop.WindowNative.GetWindowHandle(window)); Background(); }
        void Pass(string name, Action action) { Background(); action(); Background(); cases.Add(name); }
        FrameworkElement Root() => (FrameworkElement)main!.Content;
        T Find<T>(string name) where T : FrameworkElement => Root().FindName(name) as T ?? Descendants(Root()).OfType<T>().FirstOrDefault(element => element.Name == name) ?? throw new CheckFailure("lyrics_named_element_missing_" + name);
        void Accept(ReceiverSnapshot snapshot)
        {
            if (snapshot.ControlsAvailable && cover != null)
            {
                SetProperty(model!, nameof(ReceiverController.Artwork), cover); SetProperty(model!, nameof(ReceiverController.ArtworkBytes), coverBytes);
                typeof(ReceiverController).GetField("artworkKey", Private)!.SetValue(model, snapshot.TrackId + "|" + snapshot.ArtworkUrl);
            }
            Require(typeof(ReceiverController).GetMethod("Accept", Private)!.Invoke(model, [new PollResult(++revision, snapshot)]) is true, "lyrics_fixture_observation_rejected");
        }
        void Notify() => typeof(ReceiverController).GetMethod("Notify", Private)!.Invoke(model, null);
        void Arrange(FrameworkElement root, double width, double height)
        {
            for (int pass = 0; pass < 3; pass++)
            {
                foreach (var control in Descendants(root).OfType<Control>().ToArray()) control.ApplyTemplate();
                root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
            }
        }
        (double Width, double Height) MainSize()
        {
            Require(GetClientRect(mainHwnd, out var rect), "lyrics_native_client_missing");
            double scale = Root().XamlRoot?.RasterizationScale ?? Math.Max(96, GetDpiForWindow(mainHwnd)) / 96.0;
            return ((rect.Right - rect.Left) / scale, (rect.Bottom - rect.Top) / scale);
        }
        Box Bounds(FrameworkElement element)
        {
            var box = element.TransformToVisual(Root()).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));
            return new(box.X, box.Y, box.Width, box.Height);
        }
        bool LyricsVisible() => Field(main!, "lyricsVisible") is true;
        string MetadataTypography() => string.Join("|", new[] { "MiniTitle", "MiniArtist", "TitleText", "ArtistText" }
            .Select(name => Find<PlayerText>(name)).Select(text => $"{text.FontFamily.Source}:{text.FontWeight.Weight}:{text.FontSize}"));
        async Task WaitLyrics()
        {
            for (int attempt = 0; attempt < 100; attempt++)
            {
                bool done = false; await OnUi(queue!, () => { Background(); done = !model!.LyricsLoading; });
                if (done) { await OnUi(queue!, () => { }); return; }
                await Task.Delay(20);
            }
            throw new CheckFailure("lyrics_parse_did_not_settle");
        }
        async Task Mode(string mode)
        {
            await OnUi(queue!, () =>
            {
                var root = (FrameworkElement)settings!.Content;
                var navigation = Descendants(root).OfType<NavigationView>().Single(view => view.Name == "SettingsNavigation");
                navigation.SelectedItem = navigation.MenuItems.OfType<NavigationViewItem>().Single(item => item.Tag as string == "player");
            });
            await Task.Delay(700);
            await OnUi(queue!, () =>
            {
                var root = (FrameworkElement)settings!.Content; Arrange(root, 960, 740);
                var selector = Descendants(root).OfType<SelectorBar>().Single(bar => bar.Name == "LyricsDisplayMode");
                selector.SelectedItem = selector.Items.Single(item => item.Tag as string == mode);
                Require(model!.Preferences.Value.LyricsDisplayMode == mode && new UiPreferencesStore(store.Data).Value.LyricsDisplayMode == mode, "lyrics_display_mode_not_persisted_" + mode);
            });
            await Task.Delay(180);
        }
        async Task Capture(string name)
        {
            if (Environment.GetCommandLineArgs().Contains("--lyrics-no-capture")) return;
            string file = Path.Combine(directory, name + ".png");
            var captureLeases = new List<IDisposable>();
            try
            {
                File.AppendAllText(Path.Combine(directory, "capture-steps.txt"), name + ":begin\n");
                var rows = Descendants(Root()).OfType<LyricsRowPresenter>().Where(row => row.UsesCompositionSurface).ToArray();
                Require(rows.Length > 0, "lyrics_composition_surfaces_missing");
                foreach (var row in rows) captureLeases.Add(row.BeginCaptureForCheck());
                File.AppendAllText(Path.Combine(directory, "capture-steps.txt"), name + ":leases\n");
                Background(); var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(Root());
                Require(bitmap.PixelWidth > 0 && bitmap.PixelHeight > 0, "lyrics_capture_empty");
                int pixelWidth = bitmap.PixelWidth, pixelHeight = bitmap.PixelHeight;
                var buffer = await bitmap.GetPixelsAsync(); byte[] pixels = new byte[checked((int)buffer.Length)];
                Require(buffer.Length == checked((uint)pixelWidth * (uint)pixelHeight * 4), "lyrics_capture_pixel_buffer_mismatch");
                using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
                int visible = 0; for (int index = 3; index < pixels.Length; index += 4) if (pixels[index] > 0) visible++;
                Require(visible > 0, "lyrics_capture_transparent");
                var folder = await StorageFolder.GetFolderFromPathAsync(directory); var target = await folder.CreateFileAsync(Path.GetFileName(file), CreationCollisionOption.ReplaceExisting);
                using var stream = await target.OpenAsync(FileAccessMode.ReadWrite); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)pixelWidth, (uint)pixelHeight, 96, 96, pixels); await encoder.FlushAsync();
                captures.Add(new { name, path = file, status = "captured", width = bitmap.PixelWidth, height = bitmap.PixelHeight, visible_pixels = visible, composition_rows = rows.Length, glyph_snapshot_for_capture = true, composition_materials_verified = false });
                File.AppendAllText(Path.Combine(directory, "capture-steps.txt"), name + ":encoded\n");
                Background();
            }
            catch (Exception error) { captures.Add(new { name, path = file, status = "unavailable", exception_type = error.GetType().Name, hresult = error.HResult.ToString("X8") }); }
            finally
            {
                foreach (var lease in captureLeases) lease.Dispose();
                File.AppendAllText(Path.Combine(directory, "capture-steps.txt"), name + ":released\n");
            }
        }
        void Frame(string name, int frame, int width, int height, bool lyrics, bool compact)
        {
            Background(); var size = MainSize();
            if (Math.Abs(size.Width - width) > 2 || Math.Abs(size.Height - height) > 2)
                layouts.Add(new { name, frame, requested_width = width, requested_height = height, actual_width = size.Width, actual_height = size.Height, kind = "native_resize_mismatch" });
            Require(Math.Abs(size.Width - width) <= 2 && Math.Abs(size.Height - height) <= 2, "lyrics_native_resize_not_settled");
            Arrange(Root(), size.Width, size.Height); main!.RefreshAppearance(); Root().UpdateLayout();
            Require(LyricsVisible() == lyrics, "lyrics_visibility_policy_mismatch");
            Require((Find<Grid>("MiniRoot").Visibility == Visibility.Visible) == compact, "lyrics_responsive_mode_mismatch");
            var coverBox = compact ? Bounds(Find<Grid>("MiniCoverPanel")) : Bounds(Find<Border>("CoverFrame"));
            var host = Find<Grid>(compact ? "MiniLyricsHost" : "ExpandedLyricsHost"); var hostBox = Bounds(host);
            RectInt32 viewportRect = default; int passthroughCount = 0;
            if (lyrics)
            {
                Require(host.Visibility == Visibility.Visible && hostBox.Height >= 128 - 2, "lyrics_host_too_short");
                if (compact)
                {
                    Require(Math.Abs(coverBox.Width - width) <= 2 && Math.Abs(coverBox.Height - width) <= 2 && hostBox.Y >= coverBox.Y + coverBox.Height, "mini_lyric_cover_not_square_or_overlaps");
                    Require(!Descendants(Root()).OfType<FrameworkElement>().Any(element => element.Name == "MiniLyricsDivider"),
                        "mini_lyric_extra_divider_retained");
                    Require(Root().FindName("MiniLyricsGapRow") is RowDefinition gap && Math.Abs(gap.Height.Value - 8) <= .01,
                        "mini_lyric_transparent_gap_changed");
                }
                else
                {
                    Require(hostBox.X >= coverBox.X + coverBox.Width, "expanded_lyrics_not_on_right");
                    var details = Bounds(Find<Grid>("ExpandedDetails"));
                    var playerLayout = Find<Grid>("PlayerLayout"); var layout = Bounds(playerLayout);
                    double column = playerLayout.ColumnDefinitions[0].ActualWidth;
                    double topSpace = coverBox.Y - layout.Y, bottomSpace = layout.Y + layout.Height - details.Y - details.Height;
                    Require(details.Y >= coverBox.Y + coverBox.Height + 13, "expanded_metadata_has_no_cover_gap");
                    Require(Math.Abs(topSpace - bottomSpace) < 2, "expanded_cover_and_controls_not_centered_as_group");
                    Require(column > 0 && Math.Abs(details.X + details.Width / 2 - (layout.X + column / 2)) < 2
                        && Math.Abs(coverBox.X + coverBox.Width / 2 - (layout.X + column / 2)) < 2
                        && details.X >= layout.X - 2 && details.X + details.Width <= layout.X + column + 2,
                        "expanded_cover_and_metadata_not_aligned_to_actual_column");
                    double coverCenterRatio = (coverBox.X + coverBox.Width / 2) / width, lyricsStartRatio = hostBox.X / width;
                    Require(Math.Abs(coverCenterRatio - .23825) <= .015 && Math.Abs(lyricsStartRatio - .4565) <= .015, "expanded_proportional_columns_changed");
                    layouts.Add(new { kind = "expanded_column_geometry", width, height, column_width = column, cover_center_ratio = coverCenterRatio, lyrics_start_ratio = lyricsStartRatio, details, layout });
                }
                var viewport = Descendants(host).OfType<ScrollViewer>().FirstOrDefault() ?? throw new CheckFailure("lyrics_native_scroll_viewport_missing");
                var box = Bounds(viewport); double scale = Root().XamlRoot!.RasterizationScale;
                var hostRect = host.TransformToVisual(Root()).TransformBounds(new Rect(0, 0, host.ActualWidth, host.ActualHeight));
                var scrollRect = viewport.TransformToVisual(Root()).TransformBounds(new Rect(0, 0, viewport.ActualWidth, viewport.ActualHeight));
                // WinRT Rect edges preserve the native layout rounding. Adding
                // the separately projected log Box doubles can invent an extra
                // pixel at a fractional-DIP lower/right edge.
                int left = (int)Math.Floor(Math.Max(scrollRect.Left, hostRect.Left) * scale), top = (int)Math.Floor(Math.Max(scrollRect.Top, hostRect.Top) * scale);
                int right = (int)Math.Ceiling(Math.Min(scrollRect.Right, hostRect.Right) * scale), bottom = (int)Math.Ceiling(Math.Min(scrollRect.Bottom, hostRect.Bottom) * scale);
                viewportRect = new(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
                typeof(MainWindow).GetMethod("UpdateInputRegions", Private)!.Invoke(main, null);
                var input = InputNonClientPointerSource.GetForWindowId(main.AppWindow.Id);
                var passthrough = input.GetRegionRects(NonClientRegionKind.Passthrough); passthroughCount = passthrough.Length;
                // The blur bleed can enter the native resize border. Only the
                // usable client interior is supposed to receive scrolling.
                var originalViewport = viewportRect;
                Require(GetClientRect(mainHwnd, out var client), "lyrics_input_client_missing");
                int innerLeft = input.GetRegionRects(NonClientRegionKind.LeftBorder).Select(rect => rect.X + rect.Width).DefaultIfEmpty(0).Max();
                int innerTop = input.GetRegionRects(NonClientRegionKind.TopBorder).Select(rect => rect.Y + rect.Height).DefaultIfEmpty(0).Max();
                int innerRight = input.GetRegionRects(NonClientRegionKind.RightBorder).Select(rect => rect.X).DefaultIfEmpty(client.Right).Min();
                int innerBottom = input.GetRegionRects(NonClientRegionKind.BottomBorder).Select(rect => rect.Y).DefaultIfEmpty(client.Bottom).Min();
                int usableLeft = Math.Max(viewportRect.X, innerLeft), usableTop = Math.Max(viewportRect.Y, innerTop);
                viewportRect = new(usableLeft, usableTop, Math.Max(0, Math.Min(viewportRect.X + viewportRect.Width, innerRight) - usableLeft), Math.Max(0, Math.Min(viewportRect.Y + viewportRect.Height, innerBottom) - usableTop));
                int reconstructedRight = (int)Math.Ceiling(Math.Min(box.X + box.Width, hostBox.X + hostBox.Width) * scale);
                int reconstructedBottom = (int)Math.Ceiling(Math.Min(box.Y + box.Height, hostBox.Y + hostBox.Height) * scale);
                if (reconstructedRight != right || reconstructedBottom != bottom)
                    layouts.Add(new
                    {
                        kind = "viewport_native_edge_rounding", name, frame, scale,
                        host_winrt_edges = new { hostRect.Left, hostRect.Top, hostRect.Right, hostRect.Bottom },
                        viewport_winrt_edges = new { scrollRect.Left, scrollRect.Top, scrollRect.Right, scrollRect.Bottom },
                        reconstructed_pixel_edges = new { right = (hostBox.X + hostBox.Width) * scale, bottom = (hostBox.Y + hostBox.Height) * scale, reconstructedRight, reconstructedBottom },
                        native_original = Pixels(originalViewport), usable = Pixels(viewportRect), passthrough = passthrough.Select(Pixels).ToArray(),
                        exact_contains = passthrough.Any(rect => Contains(rect, viewportRect))
                    });
                if (!passthrough.Any(rect => Contains(rect, viewportRect)))
                {
                    int hostLeft = (int)Math.Floor(hostRect.Left * scale), hostTop = (int)Math.Floor(hostRect.Top * scale);
                    layouts.Add(new
                    {
                        kind = "viewport_input_mismatch", name, frame, scale,
                        original = Pixels(originalViewport), usable = Pixels(viewportRect), host = hostBox, viewport = box,
                        passthrough = passthrough.Select(Pixels).ToArray(), innerLeft, innerTop, innerRight, innerBottom,
                        host_winrt_edges = new { hostRect.Left, hostRect.Top, hostRect.Right, hostRect.Bottom },
                        viewport_winrt_edges = new { scrollRect.Left, scrollRect.Top, scrollRect.Right, scrollRect.Bottom },
                        host_native_rounding = Pixels(new RectInt32(hostLeft, hostTop, (int)Math.Ceiling(hostRect.Right * scale) - hostLeft, (int)Math.Ceiling(hostRect.Bottom * scale) - hostTop)),
                        reconstructed_pixel_edges = new { left = hostBox.X * scale, top = hostBox.Y * scale, right = (hostBox.X + hostBox.Width) * scale, bottom = (hostBox.Y + hostBox.Height) * scale },
                        caption = input.GetRegionRects(NonClientRegionKind.Caption).Select(Pixels).ToArray()
                    });
                }
                Require(viewportRect.Width > 0 && viewportRect.Height > 0 && passthrough.Any(rect => Contains(rect, viewportRect)), "lyrics_viewport_not_native_passthrough");
                Require(!input.GetRegionRects(NonClientRegionKind.Caption).Any(rect => Overlaps(rect, viewportRect)), "lyrics_viewport_overlaps_caption");
            }
            else if (compact) Require(Math.Abs(size.Width - size.Height) <= 2, "cover_only_mini_not_square");
            layouts.Add(new { name, frame, width = size.Width, height = size.Height, lyrics, compact, cover = coverBox, host = hostBox, native_viewport = Pixels(viewportRect), passthrough_count = passthroughCount });
            Background();
        }
        void MainTransitionFrame(string label, List<double>? heights = null)
        {
            Background(); var size = MainSize(); heights?.Add(size.Height);
            var content = (PlayerLayoutTransition)Field(main!, "layoutTransition")!;
            var native = (WindowResizeTransition)Field(main!, "resizeTransition")!;
            animationSamples.Add(new
            {
                stage = "main_" + label, native_width = size.Width, native_height = size.Height,
                content_width = Root().ActualWidth, content_height = Root().ActualHeight,
                cover = Bounds(Find<Grid>("MiniCoverPanel")), lyrics_visible = LyricsVisible(),
                requested_mode = model!.Preferences.Value.LyricsDisplayMode,
                transitioning = Field(main!, "lyricsLayoutTransitioning"), native_running = native.IsRunning, content_running = content.IsRunning,
                native_done = Field(main!, "nativeTransitionDone"), content_done = Field(main!, "contentTransitionDone"),
                native.HeightUpdates, content.AnimationFailures,
                seek_enabled = Find<ProgressSeekButton>("MiniProgressSeek").IsEnabled,
                controls_hit_test_visible = Find<Grid>("MiniControlsTransitionLayer").IsHitTestVisible,
                host_hit_test_visible = Find<Grid>("MiniLyricsHost").IsHitTestVisible
            });
        }
        double ShortExpandedSectionFrame(string label)
        {
            Background(); Root().UpdateLayout();
            var coverBox = Bounds(Find<Border>("CoverFrame")); var details = Bounds(Find<Grid>("ExpandedDetails"));
            var layout = Bounds(Find<Grid>("PlayerLayout")); var size = MainSize();
            var progress = Find<StackPanel>("ProgressPanel"); var transport = Find<StackPanel>("TransportPanel");
            layouts.Add(new
            {
                kind = "short_expanded_section_frame", label, native_width = size.Width, native_height = size.Height,
                cover = coverBox, details, layout, show_progress = model!.Preferences.Value.ShowProgress, show_transport = model.Preferences.Value.ShowTransport,
                progress_height = progress.ActualHeight, progress_visibility = progress.Visibility.ToString(), transport_height = transport.ActualHeight, transport_visibility = transport.Visibility.ToString()
            });
            const double rounding = 2.5;
            Require(Math.Abs(size.Width - 840) <= 2 && Math.Abs(size.Height - 340) <= 2 && LyricsVisible()
                && Find<Grid>("ExpandedRoot").Visibility == Visibility.Visible, "short_expanded_section_fixture_changed_mode");
            Require(Math.Abs(coverBox.Width - coverBox.Height) <= rounding && coverBox.Width > 0
                && coverBox.Y >= layout.Y - rounding && details.Y >= coverBox.Y + coverBox.Height - rounding
                && details.Y + details.Height <= layout.Y + layout.Height + rounding,
                "short_expanded_section_animation_overflowed_content_height");
            return coverBox.Width;
        }
        async Task TraceMainTransition(string label, int milliseconds, List<double>? heights = null)
        {
            var clock = Stopwatch.StartNew();
            while (clock.ElapsedMilliseconds < milliseconds)
            {
                await Task.Delay(16); await OnUi(queue!, () => MainTransitionFrame(label, heights));
            }
        }
        void RequireMainInteraction()
        {
            var pager = (CompactLyricsPager)Field(main!, "miniPager")!;
            bool lyricPage = pager.Active && pager.ShowingLyrics;
            Require(Find<Grid>("MiniControlsTransitionLayer").IsHitTestVisible == !lyricPage
                && Find<Grid>("MiniLyricsHost").IsHitTestVisible == (!pager.Active || lyricPage)
                && Find<Grid>("ExpandedDetails").IsHitTestVisible && Find<Grid>("ExpandedLyricsHost").IsHitTestVisible
                && Find<ProgressSeekButton>("MiniProgressSeek").IsEnabled && Find<ProgressSeekButton>("ProgressSeek").IsEnabled,
                "main_lyrics_transition_left_interaction_disabled");
        }
        void RequireMainSettled(bool lyrics, bool completedNormally)
        {
            Background(); var content = (PlayerLayoutTransition)Field(main!, "layoutTransition")!;
            var native = (WindowResizeTransition)Field(main!, "resizeTransition")!;
            Require(Field(main!, "lyricsLayoutTransitioning") is false && !content.IsRunning && !native.IsRunning
                && content.AnimationFailures == 0 && LyricsVisible() == lyrics, "main_lyrics_transition_failed_or_did_not_settle");
            if (completedNormally && Backdrop.AnimationsEnabled)
                Require(Field(main!, "nativeTransitionDone") is true && Field(main!, "contentTransitionDone") is true, "main_lyrics_transition_missing_completion");
            RequireMainInteraction();
            var size = MainSize(); var coverBox = Bounds(Find<Grid>("MiniCoverPanel"));
            Require(Math.Abs(size.Width - 420) <= 2 && Math.Abs(Root().ActualHeight - size.Height) <= 2
                && Math.Abs(coverBox.Width - 420) <= 2 && Math.Abs(coverBox.Height - 420) <= 2,
                "main_lyrics_transition_cover_or_host_not_settled");
            Require(lyrics ? size.Height >= 556 : Math.Abs(size.Height - 420) <= 2, "main_lyrics_transition_final_native_height_wrong");
        }
        void ResponsiveTransitionFrame(string label, List<bool> activeFrames)
        {
            Background();
            var transition = (PlayerLayoutTransition)Field(main!, "layoutTransition")!;
            bool miniVisible = Find<Grid>("MiniRoot").Visibility == Visibility.Visible;
            bool expandedVisible = Find<Grid>("ExpandedRoot").Visibility == Visibility.Visible;
            bool active = Field(main!, "lyricsLayoutTransitioning") is true;
            activeFrames.Add(active);
            Require(miniVisible || expandedVisible, "responsive_transition_collapsed_both_player_scenes");
            int cacheChecks = VerifyBackdropCache();
            var backing = Find<Grid>("SceneBacking");
            if (active)
            {
                Require(backing.Visibility == Visibility.Visible && Opaque(backing.Background), "responsive_transition_missing_opaque_scene_backing");
                Require(!Find<ProgressSeekButton>("MiniProgressSeek").IsEnabled && !Find<ProgressSeekButton>("ProgressSeek").IsEnabled
                    && !Find<Grid>("MiniControlsTransitionLayer").IsHitTestVisible && !Find<Grid>("ExpandedDetails").IsHitTestVisible,
                    "responsive_transition_did_not_suspend_stale_layout_input");
                if (transition.RetainedScene != null)
                    Require(miniVisible && expandedVisible, "responsive_overlap_did_not_keep_outgoing_scene");
            }
            var size = MainSize();
            animationSamples.Add(new
            {
                stage = "responsive_" + label, native_width = size.Width, native_height = size.Height,
                content_width = Root().ActualWidth, content_height = Root().ActualHeight, mini_visible = miniVisible, expanded_visible = expandedVisible,
                transitioning = active, content_running = transition.IsRunning, retained_scene = transition.RetainedScene?.Name,
                transition.AnimationFailures, seek_enabled = Find<ProgressSeekButton>("MiniProgressSeek").IsEnabled,
                backdrop_cache_references_checked = cacheChecks, scene_backing_visible = backing.Visibility == Visibility.Visible,
                mini_reading_row = ReadingRowFrame("MiniLyricsHost", miniVisible),
                expanded_reading_row = ReadingRowFrame("ExpandedLyricsHost", expandedVisible),
                visible_presentation_verified = false
            });
        }
        object? ReadingRowFrame(string hostName, bool sceneVisible)
        {
            var host = Find<Grid>(hostName);
            if (!sceneVisible || host.Children.OfType<LyricsView>().SingleOrDefault() is not { ActiveIndex: >= 0 } view)
                return null;
            var list = Descendants(view).OfType<ListView>().SingleOrDefault();
            if (list?.ContainerFromIndex(view.ActiveIndex) is not FrameworkElement row || row.ActualHeight <= 0) return null;
            double top = row.TransformToVisual(view).TransformPoint(new Point()).Y;
            return new { index = view.ActiveIndex, top, row_height = row.ActualHeight, viewport_height = view.ActualHeight,
                host_base_opacity = ElementCompositionPreview.GetElementVisual(host).Opacity };
        }
        async Task TraceResponsiveTransition(string label, int milliseconds, List<bool> activeFrames, bool requireInteractive = false)
        {
            var clock = Stopwatch.StartNew();
            while (clock.ElapsedMilliseconds < milliseconds)
            {
                await Task.Delay(16); await OnUi(queue!, () =>
                {
                    ResponsiveTransitionFrame(label, activeFrames);
                    if (requireInteractive)
                    {
                        Require(Field(main!, "lyricsLayoutTransitioning") is false,
                            "explicit_mini_request_disabled_input_again_during_native_resize");
                        RequireMainInteraction();
                    }
                });
            }
        }
        void RequireResponsiveSettled(bool compact)
        {
            Background(); var transition = (PlayerLayoutTransition)Field(main!, "layoutTransition")!;
            var size = MainSize();
            animationSamples.Add(new
            {
                stage = "responsive_settled_assert", expected_compact = compact, native_width = size.Width, native_height = size.Height,
                transitioning = Field(main!, "lyricsLayoutTransitioning") is true, content_running = transition.IsRunning,
                retained_scene = transition.RetainedScene?.Name, transition.AnimationFailures, lyrics_visible = LyricsVisible(),
                actual_compact = Field(main!, "compact"), mini_request_pending = Field(main!, "revealMiniRequested")
            });
            Require(Field(main!, "lyricsLayoutTransitioning") is false && !transition.IsRunning && transition.RetainedScene == null
                && transition.AnimationFailures == 0 && LyricsVisible(), "responsive_transition_did_not_finish_cleanly");
            Require((Find<Grid>("MiniRoot").Visibility == Visibility.Visible) == compact
                && (Find<Grid>("ExpandedRoot").Visibility == Visibility.Visible) == !compact, "responsive_transition_kept_wrong_scene");
            RequireMainInteraction();
            Require(Find<Grid>("SceneBacking").Visibility == Visibility.Collapsed, "responsive_transition_left_scene_backing_visible"); VerifyBackdropCache();
            var cover = compact ? Bounds(Find<Grid>("MiniCoverPanel")) : Bounds(Find<Border>("CoverFrame"));
            Require(cover.Width > 0 && Math.Abs(cover.Width - cover.Height) <= 2.5, "responsive_transition_stretched_cover");
        }
        bool Opaque(Brush? brush) => brush != null && brush.Opacity >= .999 && (brush is SolidColorBrush solid && solid.Color.A == 255
            || brush is LinearGradientBrush gradient && gradient.GradientStops.Count > 0 && gradient.GradientStops.All(stop => stop.Color.A == 255));
        void CaptureBackdropCache()
        {
            cachedBackdrops.Clear();
            foreach (string name in new[] { "backdrop", "miniBackdrop", "loadingBackdrop", "lyricsBackdrop", "expandedLyricsBackdrop", "sceneBackdrop" })
            {
                object instance = Field(main!, name)!;
                cachedBackdrops.Add(name, (instance, Field(instance, "current"), Field(instance, "layer")));
            }
        }
        int VerifyBackdropCache()
        {
            var appearance = (global::Windows.UI.ViewManagement.UISettings)Field(main!, "appearance")!;
            if (!appearance.AdvancedEffectsEnabled || new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast) return 0;
            int checkedLayers = 0;
            foreach (var (name, expected) in cachedBackdrops)
            {
                if (expected.Layer == null || expected.Current == null) continue;
                Require(ReferenceEquals(Field(main!, name), expected.Instance) && ReferenceEquals(Field(expected.Instance, "current"), expected.Current)
                    && ReferenceEquals(Field(expected.Instance, "layer"), expected.Layer), "responsive_transition_rebuilt_fixed_artwork_backdrop_" + name);
                checkedLayers++;
            }
            return checkedLayers;
        }
        bool Transparent(Brush? brush) => brush == null || brush.Opacity <= .001 || brush is SolidColorBrush solid && solid.Color.A == 0;
        async Task CheckLyricsBackground(int width, int height, bool compact)
        {
            LyricsDocument? document = null; ulong? position = null; ReceiverSnapshot? seekIdentity = null;
            (double Width, double Height) before = default; Box? hostBefore = null;
            object? miniBlurLayer = null;
            await OnUi(queue!, () =>
            {
                Require(!main!.AnimateHiddenLayoutForCheck && model!.Lyrics.HasLyrics && LyricsVisible(), "background_fixture_not_ready");
                document = model!.Lyrics; position = model.LyricsPositionMs; before = MainSize();
                seekIdentity = Find<ProgressSeekButton>(compact ? "MiniProgressSeek" : "ProgressSeek").Snapshot!();
                hostBefore = Bounds(Find<Grid>(compact ? "MiniLyricsHost" : "ExpandedLyricsHost"));
                miniBlurLayer = Field(Field(main, "miniBackdrop")!, "layer");
            });
            foreach (string mode in new[] { "album", "acrylic", "album" })
            {
                await OnUi(queue!, () => model!.Preferences.Update(model.Preferences.Value with { LyricsBackgroundMode = mode }));
                await Task.Delay(50);
                await OnUi(queue!, () =>
                {
                    Background(); Root().UpdateLayout();
                    var material = (PlayerAcrylic)Field(main!, "acrylic")!;
                    var size = MainSize(); var host = Find<Grid>(compact ? "MiniLyricsHost" : "ExpandedLyricsHost"); var hostBox = Bounds(host);
                    var identity = Find<ProgressSeekButton>(compact ? "MiniProgressSeek" : "ProgressSeek").Snapshot!();
                    Require(ReferenceEquals(model!.Lyrics, document) && model.LyricsPositionMs == position && LyricsVisible()
                        && identity.TrackId == seekIdentity!.TrackId && identity.Title == seekIdentity.Title && identity.DurationMs == seekIdentity.DurationMs && identity.PositionMs == seekIdentity.PositionMs,
                        "background_switch_changed_lyrics_or_seek_identity");
                    Require(size == before && (Find<Grid>("MiniRoot").Visibility == Visibility.Visible) == compact
                        && Field(main!, "lyricsLayoutTransitioning") is false && Math.Abs(hostBox.X - hostBefore!.X) <= 1 && Math.Abs(hostBox.Y - hostBefore.Y) <= 1
                        && Math.Abs(hostBox.Width - hostBefore.Width) <= 1 && Math.Abs(hostBox.Height - hostBefore.Height) <= 1,
                        "background_switch_changed_native_size_or_player_layout");
                    if (mode == "acrylic")
                    {
                        Require(material.IsRequested && (material.IsActive && main!.SystemBackdrop is DesktopAcrylicBackdrop
                            || material.UsesSolidFallback && main!.SystemBackdrop == null), "acrylic_did_not_attach_native_material_or_use_solid_fallback");
                        Require(material.IsActive ? Transparent(Find<Grid>("RootGrid").Background) : Opaque(Find<Grid>("RootGrid").Background), "acrylic_root_obscured_native_material_or_missing_solid_fallback");
                        Require(Find<Grid>("SceneBackingLayer").Visibility == Visibility.Collapsed && Find<Border>("SceneBackingShade").Visibility == Visibility.Collapsed,
                            "acrylic_scene_backing_retained_album_layers");
                        if (compact)
                        {
                            var backing = Find<Grid>("MiniLyricsBackground");
                            Require(Grid.GetRowSpan(backing) == 1 && Opaque(backing.Background) && Grid.GetRowSpan(Find<Border>("MiniLyricsGlobalShade")) == 1
                                && Transparent(host.Background) && ReferenceEquals(Find<Image>("MiniCover").Source, model.Artwork), "mini_acrylic_changed_opaque_cover_or_obscured_lyric_area");
                            var coverBox = Bounds(Find<Grid>("MiniCoverPanel"));
                            Require(Math.Abs(coverBox.Width - width) <= 2 && Math.Abs(coverBox.Height - width) <= 2, "mini_acrylic_cover_not_square");
                            if (miniBlurLayer != null) Require(ReferenceEquals(Field(Field(main!, "miniBackdrop")!, "layer"), miniBlurLayer), "mini_acrylic_rebuilt_upper_artwork_blur");
                        }
                        else
                            Require(Find<Grid>("BackdropLayer").Visibility == Visibility.Collapsed && Find<Grid>("ExpandedLyricsBackground").Visibility == Visibility.Collapsed
                                && Find<Border>("BackdropShade").Visibility == Visibility.Collapsed
                                && (material.IsActive ? Transparent(Find<Grid>("ExpandedRoot").Background) : Opaque(Find<Grid>("ExpandedRoot").Background)),
                                "expanded_acrylic_obscured_native_material_with_album_layers");
                        if (compact)
                        {
                            material.Update(true, true);
                            Require(material.IsRequested && !material.IsActive && material.UsesSolidFallback && main!.SystemBackdrop == null, "acrylic_high_contrast_policy_did_not_detach_material");
                            animationSamples.Add(new { stage = "acrylic_high_contrast_policy", high_contrast_argument_simulated = true, operating_system_setting_changed = false, uses_solid_fallback = material.UsesSolidFallback });
                            main!.RefreshAppearance();
                        }
                    }
                    else Require(!material.IsRequested && !material.IsActive && main!.SystemBackdrop == null
                        && Grid.GetRowSpan(Find<Grid>("MiniLyricsBackground")) == 3, "album_background_did_not_restore_default_layers");
                    layouts.Add(new { kind = "lyrics_background_switch", width, height, compact, mode, native_material = main!.SystemBackdrop?.GetType().Name,
                        material.IsRequested, material.IsActive, material.UsesSolidFallback, host = hostBox, native_width = size.Width, native_height = size.Height,
                        document_and_seek_identity_preserved = true, visible_material_pixels_verified = false });
                });
            }
            cases.Add("actual_hidden_background_switch_preserves_cover_lyrics_and_layout_" + (compact ? "compact" : "expanded"));
        }

        async Task CheckNativeResizeTypography()
        {
            const string mixed = "오늘의 테스트 글꼴을 확인해요 · A mixed Hangul line keeps its reading position through each width change";
            const int activeLine = 5;
            const uint enterSizeMove = 0x0231, sizing = 0x0214, exitSizeMove = 0x0232;
            const int startingWidth = 520, startingHeight = 780;
            int[] widths = [488, 388, 466, 378, 450, 354, 396, 340];
            await OnUi(queue!, () =>
            {
                model!.Preferences.Update(model.Preferences.Value with
                {
                    LyricsDisplayMode = "always", CoverLyricsPane = "automatic", PlayerTextRendering = "enhanced", AlwaysShowControls = true
                });
                Accept(source with
                {
                    TrackId = "native-resize-typography", Phase = ReceiverPhase.Paused, Title = "표시 글꼴 · Mixed title", PositionMs = activeLine * 1_000,
                    LyricsText = string.Join('\n', Enumerable.Range(0, 17).Select(index =>
                        $"[00:{index:00}.000]{(index == activeLine ? mixed : $"두 번째 줄 · Synthetic lyric {index} remains available while the viewport changes")}"))
                });
                WindowSizing.ResizeContent(main!, startingWidth, startingHeight);
            });
            await WaitLyrics();
            LyricsRowPresenter? row = null;
            LyricsView? view = null;
            PlayerText? title = null;
            bool HasBlur(LyricsView value) => Descendants(value).OfType<LyricsRowPresenter>().Any(candidate =>
                candidate.UsesCompositionSurface && Field(candidate, "appliedEdgeRadius") is double radius && radius > .05);
            for (int attempt = 0; attempt < 25; attempt++)
            {
                bool ready = false;
                await OnUi(queue!, () =>
                {
                    Background(); var size = MainSize(); Arrange(Root(), size.Width, size.Height);
                    var currentView = Find<Grid>("MiniLyricsHost").Children.OfType<LyricsView>().Single();
                    view = currentView;
                    title = Find<PlayerText>("MiniTitle");
                    var rows = Descendants(currentView).OfType<LyricsRowPresenter>().ToArray();
                    row = rows.FirstOrDefault(item => item.Item?.Line.Text == mixed);
                    ready = row != null && (currentView.HighContrast || row.UsesCompositionSurface && title.UsesEnhancedSurface)
                        && (!currentView.EffectsEnabled || HasBlur(currentView));
                });
                if (ready) break;
                await Task.Delay(40);
            }
            (string Family, ushort Weight, double Size, string Language) StyleOf(TextBlock text) =>
                (text.FontFamily.Source, text.FontWeight.Weight, text.FontSize, text.Language);

            (string Family, ushort Weight, double Size, string Language) originalStyle = default;
            bool composition = false, enhancedMetadata = false, nativeGesture = false, trackAnchor = false, expectWrapMotion = false;
            object? metadataSurface = null;
            LyricsRowItem? anchorItem = null;
            long glyphs = 0, glyphsDuringHold = 0, transitionsBeforeRelease = 0;
            double initialTextHeight = 0, anchorTop = 0, maximumAnchorDrift = 0;
            double? initialGlyphHeight = null;
            int liveSamples = 0, blurSamples = 0;
            int paddedBlurRows = 0, leftFeatherPixels = 0, rightFeatherPixels = 0;
            NativeRect originalWindow = default;
            double rasterScale = 1, windowAspect = 1;
            int frameWidth = 0, frameHeight = 0;
            double RowTop() => row!.TransformToVisual(view!).TransformPoint(new Point()).Y;
            double? GlyphHeight() => Field(row!, "plane") is { } plane && Field(plane, "ContentHeight") is double height ? height : null;

            void SampleAnchor()
            {
                if (!trackAnchor) return;
                Require(ReferenceEquals(row!.Item, anchorItem), "native_resize_replaced_reading_anchor");
                maximumAnchorDrift = Math.Max(maximumAnchorDrift, Math.Abs(RowTop() - anchorTop));
                liveSamples++;
            }

            void ApplyNativeWidth(int width)
            {
                var proposed = originalWindow;
                proposed.Right = proposed.Left + frameWidth + (int)Math.Round(width * rasterScale);
                proposed.Bottom = proposed.Top + frameHeight + (int)Math.Round(width * windowAspect * rasterScale);
                _ = SendSizing(mainHwnd, sizing, 8, ref proposed); // WMSZ_BOTTOMRIGHT
                WindowSizing.ResizeContent(main!, (proposed.Right - proposed.Left - frameWidth) / rasterScale,
                    (proposed.Bottom - proposed.Top - frameHeight) / rasterScale);
            }

            void CheckVisualsDuringResize()
            {
                Require(ReferenceEquals(row, Descendants(view!).OfType<LyricsRowPresenter>().FirstOrDefault(item => item.Item?.Line.Text == mixed))
                    && row!.UsesCompositionSurface == composition, "resize_font_mixed_lyric_rendering_changed_during_hold");
                Require(title!.UsesEnhancedSurface == enhancedMetadata && ReferenceEquals(Field(title, "surface"), metadataSurface),
                    "resize_font_metadata_surface_changed_during_hold");
                Require(row!.CachedPlaneCount <= 2, "native_resize_exceeded_two_glyph_planes");
                if (HasBlur(view!)) blurSamples++;
            }

            void CheckBlurFeather()
            {
                var activeView = view!;
                if (!activeView.EffectsEnabled) return;
                double bleed = activeView.Bleed;
                foreach (var candidate in Descendants(activeView).OfType<LyricsRowPresenter>())
                {
                    if (!candidate.UsesCompositionSurface || Field(candidate, "appliedEdgeRadius") is not double radius || radius <= .5
                        || Field(candidate, "resizeClip") is not InsetClip clip
                        || Field(candidate, "overlay") is not FrameworkElement overlay
                        || Field(candidate, "appliedSurfaceTop") is not double surfaceTop
                        || Field(candidate, "appliedViewportHeight") is not double viewportHeight) continue;

                    Require(Math.Abs(clip.LeftInset + bleed) <= .1 && Math.Abs(clip.RightInset + bleed) <= .1
                        && Math.Abs(clip.TopInset + bleed) <= .1 && clip.BottomInset <= 0 && clip.BottomInset >= -bleed,
                        "native_resize_blur_soft_edges_hard_clipped");
                    var origin = overlay.TransformToVisual(Root()).TransformPoint(new Point());
                    Require(origin.X + clip.LeftInset >= -1 && origin.X + overlay.ActualWidth - clip.RightInset <= Root().ActualWidth + 1,
                        "native_resize_blur_guard_exceeds_window");
                    paddedBlurRows++;

                    using var capture = candidate.CaptureForCheck();
                    if (capture == null) continue;
                    int width = checked((int)capture.SizeInPixels.Width), height = checked((int)capture.SizeInPixels.Height);
                    double scale = width / capture.Size.Width;
                    byte[] pixels = capture.GetPixelBytes();
                    for (int y = 0; y < height; y++)
                    {
                        double viewY = surfaceTop + (y + .5) / scale;
                        int index = (y * width * 4) + 3;
                        for (int x = 0; x < width; x++, index += 4)
                        {
                            if (pixels[index] <= 2) continue;
                            Require(viewY >= -1 && viewY <= viewportHeight + 1, "native_resize_blur_escaped_vertical_viewport_mask");
                            double localX = (x + .5) / scale - bleed;
                            if (localX >= clip.LeftInset && localX < 0) leftFeatherPixels++;
                            if (localX > overlay.ActualWidth && localX <= overlay.ActualWidth - clip.RightInset) rightFeatherPixels++;
                        }
                    }
                }
                Require(paddedBlurRows > 0 && leftFeatherPixels + rightFeatherPixels > 0, "native_resize_blur_no_pixels_in_feather_allowance");
            }
            try
            {
                await OnUi(queue!, () =>
                {
                    Require(row != null && view != null && title != null, "resize_font_mixed_lyric_not_realized");
                    var active = row!;
                    var activeView = view!;
                    var metadata = title!;
                    var original = (TextBlock)Field(active, "original")!;
                    originalStyle = StyleOf(original); initialTextHeight = original.ActualHeight; composition = active.UsesCompositionSurface;
                    enhancedMetadata = metadata.UsesEnhancedSurface;
                    Require(activeView.HighContrast || composition && enhancedMetadata, "resize_font_enhanced_rendering_not_ready");
                    Require(!activeView.EffectsEnabled || HasBlur(activeView), "resize_font_edge_blur_not_ready");
                    trackAnchor = !WindowSizing.ScreenReaderActive;
                    expectWrapMotion = trackAnchor && activeView.MotionEnabled && composition;
                    anchorTop = RowTop(); anchorItem = active.Item;
                    metadataSurface = Field(metadata, "surface");
                    glyphs = active.GlyphRasterizations; initialGlyphHeight = GlyphHeight();
                    Require(GetWindowRect(mainHwnd, out originalWindow), "resize_font_window_bounds_missing");
                    Require(GetClientRect(mainHwnd, out var client), "resize_font_client_bounds_missing");
                    rasterScale = Math.Max(96, GetDpiForWindow(mainHwnd)) / 96.0;
                    frameWidth = originalWindow.Right - originalWindow.Left - client.Right + client.Left;
                    frameHeight = originalWindow.Bottom - originalWindow.Top - client.Bottom + client.Top;
                    windowAspect = (client.Bottom - client.Top) / (double)(client.Right - client.Left);
                    _ = SendMessage(mainHwnd, enterSizeMove, 0, 0);
                    nativeGesture = true;
                    ApplyNativeWidth(startingWidth);
                    Require(activeView.InteractiveResize, "resize_font_native_gesture_not_started");
                    CheckVisualsDuringResize();
                });
                foreach (int width in widths)
                {
                    await OnUi(queue!, () => ApplyNativeWidth(width));
                    await Task.Delay(72);
                    await OnUi(queue!, () =>
                    {
                        Background(); var size = MainSize(); Arrange(Root(), size.Width, size.Height);
                        Require(Math.Abs(size.Width - width) <= 2 && view!.InteractiveResize, "resize_font_native_geometry_not_applied");
                        CheckVisualsDuringResize();
                        var active = row!;
                        Require(StyleOf((TextBlock)Field(active, "original")!) == originalStyle, "resize_font_mixed_lyric_style_changed_during_hold");
                        SampleAnchor();
                    });
                }
                // Give the last narrow stop a bounded opportunity to repaint
                // using its real wrap while the native gesture is still open.
                var repaintDeadline = Stopwatch.StartNew();
                bool measuredNarrowGlyphs = false;
                while (composition && !measuredNarrowGlyphs && repaintDeadline.ElapsedMilliseconds < 900)
                {
                    await Task.Delay(45);
                    await OnUi(queue!, () =>
                    {
                        glyphsDuringHold = row!.GlyphRasterizations - glyphs;
                        measuredNarrowGlyphs = glyphsDuringHold > 0 && GlyphHeight() - initialGlyphHeight is > 2;
                    });
                }
                await OnUi(queue!, () =>
                {
                    Require(((TextBlock)Field(row!, "original")!).ActualHeight > initialTextHeight + 2, "native_resize_narrower_measurement_did_not_wrap");
                    Require(!composition || measuredNarrowGlyphs, "native_resize_froze_the_old_glyphs_until_release");
                    Require(!view!.EffectsEnabled || blurSamples > 1, "resize_font_edge_blur_disappeared_during_hold");
                    CheckBlurFeather();
                    transitionsBeforeRelease = row!.WrapTransitionsStarted;
                    // Change to a differently wrapped width and release in one
                    // UI turn, before the scheduled live redraw can run.
                    ApplyNativeWidth(startingWidth);
                    _ = SendMessage(mainHwnd, exitSizeMove, 0, 0);
                    nativeGesture = false;
                });
            }
            finally
            {
                if (nativeGesture) await OnUi(queue!, () => { _ = SendMessage(mainHwnd, exitSizeMove, 0, 0); });
            }
            bool observedFinalWrap = false;
            for (int attempt = 0; expectWrapMotion && attempt < 25 && !observedFinalWrap; attempt++)
            {
                await Task.Delay(18);
                await OnUi(queue!, () => observedFinalWrap = row!.WrapTransitionsStarted > transitionsBeforeRelease);
            }
            await Task.Delay(550);
            await OnUi(queue!, () => Pass("live_native_resize_wraps_without_changing_fonts_blur_or_reading_anchor", () =>
            {
                var active = row!;
                var settled = StyleOf((TextBlock)Field(active, "original")!);
                Require(!view!.InteractiveResize && active.Item?.Line.Text == mixed && active.UsesCompositionSurface == composition,
                    "resize_font_mixed_lyric_rendering_not_restored_after_release");
                Require(title!.UsesEnhancedSurface == enhancedMetadata, "resize_font_metadata_rendering_not_restored_after_release");
                Require(settled.Family == originalStyle.Family && settled.Weight == originalStyle.Weight && settled.Language == originalStyle.Language,
                    "resize_font_mixed_lyric_face_changed_after_release");
                Require(!expectWrapMotion || observedFinalWrap, "native_resize_final_wrap_did_not_animate");
                Require(!active.WrapTransitionActive && active.CachedPlaneCount <= 2,
                    "native_resize_wrap_did_not_release_its_outgoing_plane");
                SampleAnchor();
                animationSamples.Add(new { stage = "native_resize_typography", composition, enhanced_metadata = enhancedMetadata,
                    edge_blur_maintained = blurSamples > 1, checked_widths = widths, maximum_anchor_drift = maximumAnchorDrift,
                    padded_blur_rows = paddedBlurRows, left_feather_pixels = leftFeatherPixels, right_feather_pixels = rightFeatherPixels,
                    reading_anchor_samples = liveSamples, final_wrap_motion_expected = expectWrapMotion, observed_final_wrap = observedFinalWrap,
                    originalStyle.Family, originalStyle.Weight, size_during_hold = originalStyle.Size, size_after_release = settled.Size,
                    rasterizations_during_hold = glyphsDuringHold, added_rasterizations_after_release = active.GlyphRasterizations - glyphs - glyphsDuringHold });
                Require(!trackAnchor || liveSamples == widths.Length + 1 && maximumAnchorDrift <= 2,
                    "native_resize_reading_anchor_jittered");
            }));
        }

        try
        {
            Require(queue != null, "lyrics_dispatcher_unavailable");
            await OnUi(queue!, () =>
            {
                step = "create_hidden_anchor";
                anchor = new Window { Title = "FusionPlay Hidden Lyrics Anchor", Content = new Grid() }; Track(anchor);
                step = "capture_original_preferences";
                originalPreferences = File.Exists(preferencesPath) ? File.ReadAllBytes(preferencesPath) : null;
                originalInvalid = Directory.Exists(store.Data) ? Directory.GetFiles(store.Data, "ui-preferences.json.invalid-*").ToHashSet(StringComparer.OrdinalIgnoreCase) : [];
                preferencesCaptured = true;
                step = "create_fixture_controller";
                model = new ReceiverController(queue!);
                step = "seed_fixture_preferences";
                model.Preferences.Update(new UiPreferences { AlwaysShowControls = true, ShowProgress = true, LyricsDisplayMode = "automatic" });
                step = "create_real_hidden_player";
                main = new MainWindow(model, () => { }); Track(main); mainHwnd = WinRT.Interop.WindowNative.GetWindowHandle(main);
                step = "create_real_hidden_settings";
                settings = new SettingsWindow(model); Track(settings);
                step = "enable_fixture_initialized_flag";
                SetProperty(model, nameof(ReceiverController.Initialized), true); initializedFixture = true;
            });
            step = "create_synthetic_cover_png";
            coverBytes = await MakeCoverAsync();
            step = "decode_synthetic_cover_png";
            using (var stream = new InMemoryRandomAccessStream())
            {
                using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(coverBytes); await writer.StoreAsync(); }
                stream.Seek(0); cover = new BitmapImage(); await cover.SetSourceAsync(stream);
            }
            await OnUi(queue!, () => Accept(source)); await WaitLyrics();
            await OnUi(queue!, () => Pass("automatic_empty_and_metadata_only_do_not_expand", () =>
            {
                Require(!LyricsVisible() && !model!.Lyrics.HasLyrics, "empty_lyrics_expanded");
                Accept(source with { TrackId = "metadata-only", LyricsText = "[ti:Fixture]\n[ar:Generated]" });
            }));
            await WaitLyrics(); await OnUi(queue!, () => Require(!LyricsVisible() && !model!.Lyrics.HasLyrics, "metadata_only_lyrics_expanded"));
            step = "settings_display_modes";
            string metadataTypography = "";
            await OnUi(queue!, () => metadataTypography = MetadataTypography());
            await Mode("always"); await OnUi(queue!, () => Pass("always_shows_empty_state_without_changing_metadata_typography", () =>
            {
                Require(LyricsVisible() && !model!.Lyrics.HasLyrics, "always_mode_did_not_show_empty_state");
                Require(MetadataTypography() == metadataTypography, "enabling_lyrics_changed_metadata_typography");
            }));
            await Mode("never"); await OnUi(queue!, () => Pass("never_hides_lyric_panel_without_changing_metadata_typography", () =>
            {
                Require(!LyricsVisible(), "never_mode_kept_lyrics_panel");
                Require(MetadataTypography() == metadataTypography, "disabling_lyrics_changed_metadata_typography");
            }));
            await OnUi(queue!, () => { settings!.Close(); SetProperty(model!, nameof(ReceiverController.Initialized), false); settings = new SettingsWindow(model!); Track(settings); SetProperty(model!, nameof(ReceiverController.Initialized), true); });
            await Mode("never"); cases.Add("display_mode_reopens_from_persisted_value"); await Mode("automatic");
            await OnUi(queue!, () => { settings!.Close(); settings = null; });
            step = "controller_lyric_publication_and_position";
            await OnUi(queue!, () =>
            {
                Accept(source with { TrackId = "late-old", LyricsText = string.Join('\n', Enumerable.Range(0, 3_000).Select(index => $"[{index / 60:00}:{index % 60:00}]Old synthetic line")) });
                source = source with { TrackId = "lyrics-fixture", LyricsText = timed }; Accept(source);
            });
            await WaitLyrics();
            await OnUi(queue!, () => Pass("late_parse_cannot_replace_new_track_and_caption_does_not_clear_it", () =>
            {
                Require(model!.Lyrics.HasLyrics && model.Lyrics.IsTimed && model.Lyrics.Lines[0].Text == "A quiet beginning" && model.Lyrics.Lines[0].Translation != null && LyricsVisible(), "current_lyric_parse_missing_or_stale");
                var document = model.Lyrics;
                Accept(source with { Title = "Blue turns into gold", PositionMs = null });
                Require(ReferenceEquals(document, model.Lyrics) && model.LyricsPositionMs == 2_000, "caption_or_missing_position_reset_lyrics");
                Accept(source with { PositionMs = 0 }); Require(model.LyricsPositionMs == 0, "explicit_zero_position_ignored");
                var timeline = (PlaybackTimeline)Field(model, "timeline")!;
                Require(timeline.Begin(new(8_000, source.TrackId, source.Title)) != 0, "lyric_seek_preview_rejected"); Notify();
                Require(model.LyricsPositionMs == 8_000, "lyrics_do_not_follow_seek_preview"); timeline.Cancel(); Notify();
                var seek = Find<ProgressSeekButton>("MiniProgressSeek");
                Require(Seeking.AtFraction(seek.Snapshot!(), .5)?.ExpectedTrackId == source.TrackId, "player_seek_guard_lost_track_identity");
            }));
            step = "current_track_lyrics_toggle";
            await OnUi(queue!, () => WindowSizing.ResizeContent(main!, 840, 640));
            await Task.Delay(220);
            void ToggleLyrics() => Require(typeof(MainWindow).GetMethod("ToggleCurrentLyrics", Private)!.Invoke(main, null) is true,
                "current_track_lyrics_toggle_unavailable");
            var nextSource = source with { TrackId = "lyrics-toggle-next-track" };
            await OnUi(queue!, () => Pass("current_track_lyric_override_keeps_preferences_and_survives_caption_updates", () =>
            {
                var saved = File.ReadAllBytes(preferencesPath);
                Require(Find<Button>("LyricsToggleButton").Visibility == Visibility.Visible && LyricsVisible(), "lyrics_toggle_fixture_not_ready");
                ToggleLyrics();
                Require(!LyricsVisible(), "lyrics_toggle_did_not_hide_current_track");
                Accept(source with { Title = "A new caption for the same track" });
                Require(!LyricsVisible() && File.ReadAllBytes(preferencesPath).AsSpan().SequenceEqual(saved), "lyrics_toggle_changed_global_mode_or_was_reset_by_caption");
                Accept(nextSource);
            }));
            await WaitLyrics();
            await OnUi(queue!, () => Pass("current_track_lyric_override_resets_on_track_mode_change_and_disconnect", () =>
            {
                Require(LyricsVisible(), "lyrics_override_leaked_into_next_track");
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" });
                ToggleLyrics();
                Require(LyricsVisible() && model.Preferences.Value.LyricsDisplayMode == "never", "lyrics_toggle_did_not_temporarily_show_lyrics");
                model.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "always" });
                model.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" });
                Require(!LyricsVisible(), "changing_global_mode_kept_lyrics_override");
                ToggleLyrics();
                Accept(new ReceiverSnapshot { Phase = ReceiverPhase.Ready });
                Require(!LyricsVisible() && Find<Button>("MiniLyricsToggleButton").Visibility == Visibility.Collapsed, "lyrics_shortcut_retained_when_disconnected");
                Accept(nextSource);
                Require(!LyricsVisible(), "lyrics_override_survived_disconnect_and_reconnect");
                model.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "automatic" });
                Accept(source);
            }));
            await WaitLyrics();
            await Task.Delay(400);
            step = "real_player_layouts";
            var playerSizes = new List<(int Width, int Height)> { (320, 456), (420, 640), (840, 600), (840, 340), (840, 760) };
            await OnUi(queue!, () =>
            {
                var area = DisplayArea.GetFromWindowId(main!.AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
                double scale = Root().XamlRoot?.RasterizationScale ?? GetDpiForWindow(mainHwnd) / 96.0;
                double availableWidth = area.Width / scale, availableHeight = area.Height / scale;
                foreach (var candidate in new[] { (Width: 1280, Height: 720), (Width: 1600, Height: 900) })
                {
                    bool fits = candidate.Width + 32 <= availableWidth && candidate.Height + 32 <= availableHeight;
                    layouts.Add(new { kind = "large_native_sample_availability", width = candidate.Width, height = candidate.Height, available_width = availableWidth, available_height = availableHeight, included = fits, reason = fits ? "fits_work_area_with_frame_margin" : "native_work_area_too_small" });
                    if (fits) playerSizes.Add(candidate);
                }
            });
            foreach (var size in playerSizes)
            {
                File.AppendAllText(Path.Combine(directory, "capture-steps.txt"), $"resize:{size.Width}x{size.Height}\n");
                await OnUi(queue!, () => WindowSizing.ResizeContent(main!, size.Width, size.Height)); await Task.Delay(500);
                for (int frame = 0; frame < 4; frame++) { int sample = frame; await OnUi(queue!, () => Frame("timed", sample, size.Width, size.Height, true, size.Width < 600)); await Task.Delay(25); }
                await Capture($"lyrics-{size.Width}x{size.Height}");
                if (size is (420, 640) or (840, 600)) await CheckLyricsBackground(size.Width, size.Height, size.Width < 600);
            }
            step = "actual_hidden_main_responsive_overlap";
            var responsiveActiveFrames = new List<bool>(); bool responsiveMotion = false;
            await OnUi(queue!, () => { main!.AnimateHiddenLayoutForCheck = false; WindowSizing.ResizeContent(main, 599, 760); });
            await Task.Delay(350);
            await OnUi(queue!, () =>
            {
                RequireResponsiveSettled(compact: true); CaptureBackdropCache(); main!.AnimateHiddenLayoutForCheck = true; responsiveMotion = Backdrop.AnimationsEnabled;
                WindowSizing.ResizeContent(main, 601, 760);
            });
            await TraceResponsiveTransition("cross_600_to_expanded", 450, responsiveActiveFrames);
            await OnUi(queue!, () => Pass("actual_hidden_main_crosses_600_with_retained_scene_and_guarded_input", () =>
            {
                RequireResponsiveSettled(compact: false);
                if (responsiveMotion) Require(responsiveActiveFrames.Any(active => active), "responsive_transition_did_not_start_with_motion_enabled");
                else Require(responsiveActiveFrames.All(active => !active), "responsive_transition_ignored_reduced_motion");
                WindowSizing.ResizeContent(main!, 599, 760);
            }));
            await Task.Delay(45);
            await OnUi(queue!, () => { ResponsiveTransitionFrame("reverse_to_compact_at_45ms", responsiveActiveFrames); WindowSizing.ResizeContent(main!, 601, 760); });
            await Task.Delay(70);
            await OnUi(queue!, () => { ResponsiveTransitionFrame("reverse_to_expanded_after_70ms", responsiveActiveFrames); WindowSizing.ResizeContent(main!, 599, 760); });
            await TraceResponsiveTransition("rapid_reverse_to_compact", 450, responsiveActiveFrames);
            await OnUi(queue!, () => Pass("actual_hidden_main_responsive_rapid_reverse_keeps_latest_scene", () =>
            {
                RequireResponsiveSettled(compact: true); WindowSizing.ResizeContent(main!, 601, 760);
            }));
            await Task.Delay(70);
            await OnUi(queue!, () => Pass("actual_main_mini_request_cancels_responsive_overlap_and_restores_input", () =>
            {
                ResponsiveTransitionFrame("before_real_mini_request", responsiveActiveFrames);
                if (responsiveMotion) Require(Field(main!, "lyricsLayoutTransitioning") is true, "responsive_cancel_fixture_was_not_active");
                main!.RequestMiniPlayer();
                Require(Field(main, "lyricsLayoutTransitioning") is false && !((PlayerLayoutTransition)Field(main, "layoutTransition")!).IsRunning,
                    "mini_request_did_not_cancel_responsive_overlap");
                RequireMainInteraction();
            }));
            var miniRequestFrames = new List<bool>();
            await TraceResponsiveTransition("after_real_mini_request", 350, miniRequestFrames, requireInteractive: true);
            await OnUi(queue!, () =>
            {
                Require(miniRequestFrames.All(active => !active) && Field(main!, "revealMiniRequested") is false,
                    "explicit_mini_request_restarted_responsive_transition_or_left_pending_flag");
                RequireResponsiveSettled(compact: true); main!.AnimateHiddenLayoutForCheck = false;
                animationSamples.Add(new { stage = "responsive_overlap_scope", system_animations_enabled = responsiveMotion, active_frames = responsiveActiveFrames.Count(active => active), actual_main_state_machine = true, fullscreen_presenter_attached = false, visible_presentation_verified = false });
            });
            step = "short_expanded_sections_keep_cover_inside_content";
            double initialSectionCover = 0, hiddenSectionCover = 0;
            await OnUi(queue!, () =>
            {
                model!.Preferences.Update(model.Preferences.Value with { ShowProgress = true, ShowTransport = true });
                WindowSizing.ResizeContent(main!, 840, 340);
            });
            await Task.Delay(350);
            await OnUi(queue!, () =>
            {
                initialSectionCover = ShortExpandedSectionFrame("sections_visible_stable");
                model!.Preferences.Update(model.Preferences.Value with { ShowProgress = false, ShowTransport = false });
                ShortExpandedSectionFrame("sections_hide_requested");
            });
            for (int frame = 0; frame < 12; frame++)
            {
                await Task.Delay(20); int sample = frame;
                await OnUi(queue!, () => ShortExpandedSectionFrame("sections_hiding_" + sample));
            }
            await Task.Delay(80);
            await OnUi(queue!, () =>
            {
                hiddenSectionCover = ShortExpandedSectionFrame("sections_hidden_stable");
                Require(hiddenSectionCover > initialSectionCover + 10
                    && Find<StackPanel>("ProgressPanel").Visibility == Visibility.Collapsed && Find<StackPanel>("TransportPanel").Visibility == Visibility.Collapsed,
                    "short_expanded_cover_did_not_use_released_section_height");
                model!.Preferences.Update(model.Preferences.Value with { ShowProgress = true, ShowTransport = true });
                ShortExpandedSectionFrame("sections_reverse_show");
            });
            await Task.Delay(60);
            await OnUi(queue!, () =>
            {
                ShortExpandedSectionFrame("sections_reverse_before_hide");
                model!.Preferences.Update(model.Preferences.Value with { ShowProgress = false, ShowTransport = false });
                ShortExpandedSectionFrame("sections_reverse_hide");
            });
            await Task.Delay(50);
            await OnUi(queue!, () =>
            {
                ShortExpandedSectionFrame("sections_reverse_before_show");
                model!.Preferences.Update(model.Preferences.Value with { ShowProgress = true, ShowTransport = true });
            });
            for (int frame = 0; frame < 12; frame++)
            {
                await Task.Delay(20); int sample = frame;
                await OnUi(queue!, () => ShortExpandedSectionFrame("sections_reversing_" + sample));
            }
            await Task.Delay(80);
            await OnUi(queue!, () => Pass("short_expanded_section_collapse_and_rapid_reverse_keep_square_cover_within_content", () =>
            {
                double restored = ShortExpandedSectionFrame("sections_restored_stable");
                Require(Math.Abs(restored - initialSectionCover) <= 2.5 && model!.Preferences.Value.ShowProgress && model.Preferences.Value.ShowTransport,
                    "short_expanded_section_reverse_did_not_restore_latest_request");
                animationSamples.Add(new { stage = "short_expanded_section_scope", system_animations_enabled = Backdrop.AnimationsEnabled, initial_cover = initialSectionCover, hidden_cover = hiddenSectionCover, restored_cover = restored, visible_presentation_verified = false });
            }));
            step = "short_expanded_lyrics_closure_keeps_expanded_mode";
            await OnUi(queue!, () =>
            {
                main!.AnimateHiddenLayoutForCheck = true;
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" });
            });
            var shortClosureClock = Stopwatch.StartNew();
            while (shortClosureClock.ElapsedMilliseconds < 550)
            {
                await Task.Delay(16);
                await OnUi(queue!, () =>
                {
                    Background(); var size = MainSize();
                    Require(Field(main!, "compact") is false && Find<Grid>("MiniRoot").Visibility == Visibility.Collapsed
                        && Find<Grid>("ExpandedRoot").Visibility == Visibility.Visible, "short_expanded_lyrics_closure_fell_into_mini_mid_transition");
                    animationSamples.Add(new { stage = "short_expanded_lyrics_closing", native_width = size.Width, native_height = size.Height, compact = false, transitioning = Field(main!, "lyricsLayoutTransitioning") });
                });
            }
            await OnUi(queue!, () => Pass("short_expanded_lyrics_closure_grows_340_to_360_without_mini_flash", () =>
            {
                var size = MainSize(); var transition = (PlayerLayoutTransition)Field(main!, "layoutTransition")!;
                Require(Math.Abs(size.Width - 840) <= 2 && Math.Abs(size.Height - 360) <= 2 && !LyricsVisible()
                    && Field(main!, "lyricsLayoutTransitioning") is false && !transition.IsRunning && transition.AnimationFailures == 0,
                    "short_expanded_lyrics_closure_did_not_finish_at_840_by_360");
                RequireMainInteraction(); main!.AnimateHiddenLayoutForCheck = false;
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "automatic" });
            }));
            step = "actual_hidden_main_lyrics_transition";
            bool mainMotionEnabled = false; var expansionHeights = new List<double>();
            await OnUi(queue!, () =>
            {
                main!.AnimateHiddenLayoutForCheck = false;
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" });
                WindowSizing.ResizeContent(main, 420, 420);
            });
            await Task.Delay(300);
            await OnUi(queue!, () =>
            {
                Require(Root().IsLoaded && model!.Lyrics.HasLyrics && !LyricsVisible(), "main_transition_start_fixture_not_ready");
                model!.Preferences.Update(model.Preferences.Value with { LyricsBackgroundMode = "acrylic" });
                var material = (PlayerAcrylic)Field(main!, "acrylic")!;
                Require(!material.IsRequested && !material.IsActive && main!.SystemBackdrop == null, "never_lyrics_mode_enabled_lyric_acrylic");
                cases.Add("never_lyrics_mode_does_not_enable_lyric_acrylic");
                model.Preferences.Update(model.Preferences.Value with { LyricsBackgroundMode = "album" });
                main!.AnimateHiddenLayoutForCheck = true; mainMotionEnabled = Backdrop.AnimationsEnabled;
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "always" });
                if (mainMotionEnabled)
                    Require(Field(main, "lyricsLayoutTransitioning") is true && !Find<ProgressSeekButton>("MiniProgressSeek").IsEnabled
                        && !Find<Grid>("MiniControlsTransitionLayer").IsHitTestVisible, "main_transition_did_not_immediately_suspend_seek");
                else Require(Field(main, "lyricsLayoutTransitioning") is false, "main_transition_ignored_system_reduced_motion");
                MainTransitionFrame("expand_requested", expansionHeights);
            });
            await TraceMainTransition("expanding", 600, expansionHeights);
            await OnUi(queue!, () =>
            {
                RequireMainSettled(true, completedNormally: true);
                if (mainMotionEnabled) Require(expansionHeights.Any(height => height > 422 && height < 691), "main_native_lyrics_height_skipped_intermediate_frames");
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" });
                MainTransitionFrame("collapse_requested");
            });
            await TraceMainTransition("collapsing", 600);
            await OnUi(queue!, () => Pass("actual_hidden_main_expands_and_collapses_with_native_and_content_completion", () =>
            {
                RequireMainSettled(false, completedNormally: true);
                animationSamples.Add(new { stage = "main_motion_scope", system_animations_enabled = mainMotionEnabled, production_state_machine_exercised = true, native_height_intermediate_frames = expansionHeights.Count(height => height > 422 && height < 691), visible_presentation_verified = false });
            }));
            await OnUi(queue!, () => model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "always" }));
            await Task.Delay(45);
            await OnUi(queue!, () => { model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" }); MainTransitionFrame("reverse_to_never_at_45ms"); });
            await Task.Delay(70);
            await OnUi(queue!, () => { model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "always" }); MainTransitionFrame("reverse_to_always_after_70ms"); });
            await TraceMainTransition("rapid_reverse_settling", 700);
            await OnUi(queue!, () => Pass("actual_hidden_main_rapid_reversal_keeps_latest_lyrics_request", () =>
            {
                RequireMainSettled(true, completedNormally: true);
                Require(model!.Preferences.Value.LyricsDisplayMode == "always", "main_rapid_reverse_lost_latest_mode");
            }));
            await OnUi(queue!, () => model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" }));
            await Task.Delay(70);
            await OnUi(queue!, () => Pass("actual_main_mini_request_cancels_transition_and_restores_interaction_without_poll", () =>
            {
                if (mainMotionEnabled) Require(Field(main!, "lyricsLayoutTransitioning") is true, "main_cancel_fixture_was_not_mid_transition");
                main!.RequestMiniPlayer();
                Require(Field(main, "lyricsLayoutTransitioning") is false && !LyricsVisible()
                    && !((PlayerLayoutTransition)Field(main, "layoutTransition")!).IsRunning
                    && !((WindowResizeTransition)Field(main, "resizeTransition")!).IsRunning, "real_mini_request_did_not_cancel_layout_transition");
                RequireMainInteraction();
                MainTransitionFrame("cancelled_by_real_mini_request");
            }));
            await TraceMainTransition("cancelled_old_callbacks", 350);
            await OnUi(queue!, () =>
            {
                RequireMainSettled(false, completedNormally: false); main!.AnimateHiddenLayoutForCheck = false;
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "automatic" });
            });
            await OnUi(queue!, () => WindowSizing.ResizeContent(main!, 420, 640)); await Task.Delay(350);
            await OnUi(queue!, () => Accept(source with { ControlsAvailable = false, Phase = ReceiverPhase.Ready, TrackId = "", Title = "", LyricsText = "", PositionMs = null }));
            await WaitLyrics(); await Task.Delay(400);
            await OnUi(queue!, () => Pass("media_end_clears_lyrics_and_restores_square", () =>
            {
                Require(!model!.Lyrics.HasLyrics && !model.LyricsLoading && !model.LyricsAvailable && model.LyricsPositionMs == null && !LyricsVisible(), "media_end_retained_lyrics");
                var size = MainSize(); Require(Math.Abs(size.Width - size.Height) <= 2, "lyric_end_did_not_restore_square");
            }));
            foreach (int side in new[] { 320, 420 })
            {
                await OnUi(queue!, () => WindowSizing.ResizeContent(main!, side, side)); await Task.Delay(300);
                for (int frame = 0; frame < 4; frame++) { int sample = frame; await OnUi(queue!, () => Frame("empty", sample, side, side, false, true)); await Task.Delay(25); }
            }
            cases.Add("real_layout_and_sdk_region_frames_including_available_large_sizes");
            step = "controller_new_track_missing_lyrics_grace";
            LyricsDocument? replacementLyrics = null;
            var graceSource = source with { TrackId = "lyrics-grace-old", Phase = ReceiverPhase.Playing, ControlsAvailable = true, LyricsText = timed, PositionMs = 2_000 };
            await OnUi(queue!, () => Accept(graceSource)); await WaitLyrics();
            await OnUi(queue!, () =>
            {
                Require(model!.Lyrics.HasLyrics && LyricsVisible(), "lyrics_grace_previous_track_fixture_not_ready");
                graceSource = graceSource with { TrackId = "lyrics-grace-replacement", LyricsText = "", PositionMs = null, DurationMs = null, Phase = ReceiverPhase.Connected };
                Accept(graceSource);
                var state = (LyricsState)Field(model, "lyrics")!;
                Require(!model.Lyrics.HasLyrics && model.LyricsLoading && model.LyricsAvailable && model.LyricsPositionMs == null
                    && state.WaitingForLyrics && state.MissingLyricsWaitToken.HasValue && LyricsVisible(), "new_track_missing_lyrics_kept_old_document_or_collapsed_layout");
            });
            await Task.Delay(160);
            await OnUi(queue!, () =>
            {
                Require(model!.LyricsLoading && model.LyricsAvailable && !model.Lyrics.HasLyrics && LyricsVisible(), "new_track_missing_lyrics_did_not_keep_bounded_wait");
                graceSource = graceSource with { LyricsText = "[00:01.000]A new synthetic lyric arrives\n[00:01.000]新曲合成歌词已到达\n[00:03.000]Another new fixture line", PositionMs = 1_000, DurationMs = 30_000, Phase = ReceiverPhase.Playing };
                Accept(graceSource);
            });
            await WaitLyrics();
            await OnUi(queue!, () => replacementLyrics = model!.Lyrics);
            await Task.Delay(LyricsState.MissingLyricsGracePeriod + TimeSpan.FromMilliseconds(150));
            await OnUi(queue!, () => Pass("new_track_late_lyrics_replace_empty_wait_and_survive_old_timer", () =>
            {
                var state = (LyricsState)Field(model!, "lyrics")!;
                Require(ReferenceEquals(model!.Lyrics, replacementLyrics) && model.Lyrics.HasLyrics
                    && model.Lyrics.Lines[0].Text == "A new synthetic lyric arrives" && model.LyricsPositionMs == 1_000
                    && !model.LyricsLoading && model.LyricsAvailable && !state.WaitingForLyrics && state.MissingLyricsWaitToken == null && LyricsVisible(),
                    "old_missing_lyrics_timer_cleared_new_track_document");
                graceSource = graceSource with { TrackId = "lyrics-grace-empty", LyricsText = "", PositionMs = null, DurationMs = null, Phase = ReceiverPhase.Connected };
                Accept(graceSource);
                Require(model.LyricsLoading && model.LyricsAvailable && !model.Lyrics.HasLyrics && LyricsVisible(), "genuinely_empty_track_skipped_lyrics_wait");
            }));
            await Task.Delay(120);
            await OnUi(queue!, () => Require(model!.LyricsLoading && model.LyricsAvailable && LyricsVisible(), "genuinely_empty_track_collapsed_before_grace"));
            await Task.Delay(LyricsState.MissingLyricsGracePeriod);
            await OnUi(queue!, () => Pass("genuinely_empty_new_track_collapses_only_after_bounded_lyrics_wait", () =>
            {
                var state = (LyricsState)Field(model!, "lyrics")!;
                Require(!model!.Lyrics.HasLyrics && !model.LyricsLoading && !model.LyricsAvailable && model.LyricsPositionMs == null
                    && !state.WaitingForLyrics && state.MissingLyricsWaitToken == null && !LyricsVisible(), "missing_lyrics_grace_did_not_expire_and_collapse");
                graceSource = source with { TrackId = "lyrics-grace-disconnect-ready", LyricsText = timed, PositionMs = 2_000, Phase = ReceiverPhase.Playing, ControlsAvailable = true };
                Accept(graceSource);
            }));
            await WaitLyrics();
            await OnUi(queue!, () => Pass("disconnect_immediately_clears_missing_lyrics_wait_and_layout", () =>
            {
                Accept(graceSource with { TrackId = "lyrics-grace-disconnect-wait", LyricsText = "", PositionMs = null });
                Require(model!.LyricsLoading && model.LyricsAvailable && LyricsVisible(), "disconnect_lyrics_wait_fixture_not_ready");
                Accept(graceSource with { ControlsAvailable = false, Phase = ReceiverPhase.Ready, TrackId = "", Title = "", LyricsText = "", PositionMs = null });
                var state = (LyricsState)Field(model, "lyrics")!;
                Require(!model.Lyrics.HasLyrics && !model.LyricsLoading && !model.LyricsAvailable && model.LyricsPositionMs == null
                    && !state.WaitingForLyrics && state.MissingLyricsWaitToken == null && !LyricsVisible(), "disconnect_retained_missing_lyrics_wait");
            }));
            step = "native_component_row_and_browsing";
            var requested = new List<ulong>(); LyricsRowPresenter? row = null; object[]? originalItems = null;
            await OnUi(queue!, () =>
            {
                component = new LyricsView(); component.SeekRequested += requested.Add; component.Update(LyricsDocument.Parse(timed), 2_000, true, preferences: new UiPreferences());
                var content = new Grid { Width = 400, Height = 340 }; content.Children.Add(component); componentWindow = new Window { Content = content, Title = "FusionPlay Hidden Lyric Component" }; Track(componentWindow);
                WindowSizing.Apply(componentWindow, 400, 340); Arrange(content, 400, 340);
                originalItems = ((Array)Field(component, "items")!).Cast<object>().ToArray();
                row = Descendants(component).OfType<LyricsRowPresenter>().FirstOrDefault(item => item.Item?.Line.TimeMs == 0); componentRowWasRealized = row != null;
                if (row == null) { row = new LyricsRowPresenter { DataContext = originalItems[0], Style = (Style)component.Resources["LyricsRowButtonStyle"] }; content.Children.Add(row); component.Register(row); }
                var peer = new ButtonAutomationPeer(row); Require(row.IsEnabled && peer.GetPattern(PatternInterface.Invoke) is IInvokeProvider, "lyric_row_native_invoke_missing");
                ((IInvokeProvider)peer.GetPattern(PatternInterface.Invoke)).Invoke();
                Require(requested.SequenceEqual(new ulong[] { 0 }), "lyric_row_did_not_publish_timestamp");
                component.Update((LyricsDocument)Field(component, "document")!, 4_000, false); row.ApplyState(style: false);
                Require(!row.IsEnabled && ((Array)Field(component, "items")!).Cast<object>().SequenceEqual(originalItems, ReferenceEqualityComparer.Instance), "disabled_control_replaced_lyric_items");
                try { ((IInvokeProvider)new ButtonAutomationPeer(row).GetPattern(PatternInterface.Invoke)).Invoke(); }
                catch (Exception error) when (error is COMException || error.GetType().Name == "ElementNotEnabledException") { }
                Require(requested.Count == 1, "disabled_lyric_row_dispatched_seek");
                cases.Add("native_row_invoke_and_disabled_item_identity");
                typeof(LyricsView).GetMethod("BeginBrowsing", Private)!.Invoke(component, null);
                Require(Field(component, "browsing") is true && ((DispatcherQueueTimer)Field(component, "browsingTimer")!).Interval == TimeSpan.FromSeconds(5), "manual_browse_policy_not_five_seconds");
            });
            await Task.Delay(5_150);
            await OnUi(queue!, () => Pass("manual_browse_expires_without_return_button_or_seek", () =>
            {
                Require(Field(component!, "browsing") is false, "manual_browse_did_not_expire");
                Require(!Descendants(component!).OfType<FrameworkElement>().Any(item => item.Name == "LyricsReturnToCurrent")
                    && requested.Count == 1, "return_button_retained_or_automatic_follow_dispatched_seek");
            }));
            step = "native_lyric_reading_anchor_and_stagger";
            if (!WindowSizing.ScreenReaderActive)
            {
                var followFixture = LyricsDocument.Parse(string.Join("\n", Enumerable.Range(0, 18)
                    .Select(index => $"[00:{index:00}.000]A repeating synthetic line changes its height as the narrow lyric column wraps its words {index}")));
                const int active = 7;
                double anchorTop = 0;
                double maximumLiveDrift = 0;
                int liveSamples = 0;
                LyricsRowItem? anchorItem = null;
                ListView FollowList() => Descendants(component!).OfType<ListView>().Single(view => view.Name == "LyricsLines");
                FrameworkElement FollowContainer(int index)
                {
                    return FollowList().ContainerFromIndex(index) as FrameworkElement ?? throw new CheckFailure("native_reading_anchor_not_realized");
                }
                double FollowTop(int index) => FollowContainer(index).TransformToVisual(component).TransformPoint(new Point()).Y;
                void CaptureReadingRow(string phase)
                {
                    var current = FollowList().ContainerFromIndex(active) as FrameworkElement;
                    double? top = current is { ActualHeight: > 0 }
                        ? current.TransformToVisual(component).TransformPoint(new Point()).Y
                        : null;
                    if (top is { } placed)
                    {
                        maximumLiveDrift = Math.Max(maximumLiveDrift, Math.Abs(placed - anchorTop));
                        liveSamples++;
                    }
                    animationSamples.Add(new
                    {
                        stage = "reading_anchor_live_" + phase,
                        width = component!.ActualWidth, before = anchorTop, top
                    });
                }
                void SizeComponent(double width)
                {
                    var content = (Grid)componentWindow!.Content;
                    content.Width = width;
                    WindowSizing.ResizeContent(componentWindow, width, 340);
                    Arrange(content, width, 340);
                }
                await OnUi(queue!, () =>
                {
                    var content = (Grid)componentWindow!.Content;
                    if (row != null && content.Children.Contains(row)) content.Children.Remove(row);
                    SizeComponent(400);
                    component!.Update(followFixture, active * 1_000, true);
                });
                bool anchorReady = false;
                double? previousTop = null;
                var readiness = Stopwatch.StartNew();
                while (!anchorReady && readiness.ElapsedMilliseconds < 2_000)
                {
                    await Task.Delay(45);
                    await OnUi(queue!, () =>
                    {
                        if (FollowList().ContainerFromIndex(active) is not FrameworkElement current || current.ActualHeight <= 0)
                            return;
                        double top = current.TransformToVisual(component).TransformPoint(new Point()).Y;
                        bool overlaps = LyricsViewport.IntersectsViewport(top, current.ActualHeight, component!.ActualHeight, bleed: 0);
                        anchorReady = overlaps && previousTop.HasValue && Math.Abs(top - previousTop.Value) <= .5;
                        previousTop = overlaps ? top : null;
                    });
                }
                await OnUi(queue!, () =>
                {
                    Require(anchorReady, "native_reading_anchor_not_in_viewport");
                    anchorTop = FollowTop(active);
                    anchorItem = ((LyricsRowItem[])Field(component!, "items")!)[active];
                    component!.BeginViewportResize();
                    SizeComponent(599);
                    CaptureReadingRow("599_immediate");
                });
                foreach (double width in new[] { 601d, 599d, 280d, 420d, 280d })
                {
                    await Task.Delay(16);
                    await OnUi(queue!, () =>
                    {
                        CaptureReadingRow("before_" + width);
                        SizeComponent(width);
                        CaptureReadingRow("after_" + width);
                    });
                }
                await Task.Delay(120);
                await OnUi(queue!, () =>
                {
                    double during = FollowTop(active);
                    animationSamples.Add(new { stage = "reading_anchor_narrow_during_resize", before = anchorTop, during });
                    Require(Math.Abs(during - anchorTop) <= 2, "reading_anchor_drifted_during_width_reflow");
                    SizeComponent(420);
                    component!.EndViewportResize();
                });
                await Task.Delay(250);
                await OnUi(queue!, () => Pass("native_reading_anchor_pins_same_row_during_and_after_width_reflow", () =>
                {
                    double settled = FollowTop(active);
                    animationSamples.Add(new { stage = "reading_anchor_wide_released", before = anchorTop, settled, maximumLiveDrift, liveSamples });
                    Require(liveSamples == 11 && maximumLiveDrift <= 2, "reading_anchor_jumped_in_live_layout_turn");
                    Require(Math.Abs(settled - anchorTop) <= 2 && ReferenceEquals(anchorItem, ((LyricsRowItem[])Field(component!, "items")!)[active]),
                        "reading_anchor_jumped_on_release_or_replaced_items");
                    component!.Update(followFixture, (active + 1) * 1_000, true);
                }));
                await Task.Delay(120);
                await OnUi(queue!, () => Pass("native_adjacent_follow_motion_respects_preferences_and_cancellation", () =>
                {
                    if (component!.MotionEnabled)
                    {
                        Require(Field(component, "followMotion") is LyricsFollowMotion, "adjacent_follow_did_not_start");
                        component.CancelFollowAnimation();
                    }
                    Require(Field(component, "followMotion") == null
                        && Descendants(component).OfType<LyricsRowPresenter>().All(presenter => presenter.Translation.Y == 0),
                        "cancelled_follow_left_row_translations");
                }));
            }
            step = "coalesced_gpu_wrap_and_rapid_reverse";
            LyricsRowPresenter? wrapRow = null; long transitionsBefore = 0; bool canCheckWrap = false, observedWrap = false;
            await OnUi(queue!, () =>
            {
                var synthetic = LyricsDocument.Parse("[00:00.000]A synthetic line changes its wrapping when this hidden test narrows and widens the lyric column again\n[00:00.000]这是一句仅用于隐藏检查的合成双语歌词，改变列宽以后检查换行和缓存动画，不包含真实歌曲。\n[00:04.000]Another synthetic line");
                component!.Update(synthetic, 0, false);
                var content = (Grid)componentWindow!.Content;
                if (row != null && content.Children.Contains(row)) content.Children.Remove(row);
                var firstItem = ((Array)Field(component, "items")!).GetValue(0);
                wrapRow = new LyricsRowPresenter { DataContext = firstItem, Width = 400, VerticalAlignment = VerticalAlignment.Top, Style = (Style)component.Resources["LyricsRowButtonStyle"] };
                content.Children.Add(wrapRow); Arrange(content, 400, 340);
            });
            await Task.Delay(400);
            await OnUi(queue!, () =>
            {
                canCheckWrap = component!.MotionEnabled && wrapRow!.UsesCompositionSurface;
                transitionsBefore = wrapRow!.WrapTransitionsStarted;
                animationSamples.Add(new { stage = "wrap_warmup", motion_enabled = component.MotionEnabled, composition = wrapRow.UsesCompositionSurface, wrapRow.GlyphRasterizations, wrapRow.SurfaceCreations, wrapRow.CachedPlaneCount });
                var list = Descendants(component).OfType<ListView>().Single(view => view.Name == "LyricsLines");
                Require((list.ItemContainerTransitions?.Count > 0) == component.MotionEnabled, "lyric_reposition_transition_does_not_respect_motion");
                wrapRow.Width = 260; Arrange((Grid)componentWindow!.Content, 400, 340);
            });
            if (canCheckWrap)
            {
                for (int attempt = 0; attempt < 25 && !observedWrap; attempt++)
                {
                    await Task.Delay(20);
                    await OnUi(queue!, () =>
                    {
                        Background(); observedWrap = wrapRow!.WrapTransitionsStarted > transitionsBefore && wrapRow.WrapTransitionActive;
                        if (!observedWrap) return;
                        Require(wrapRow.WrapTransitionDurationMs is >= 160 and <= 220 && wrapRow.CachedPlaneCount == 2, "lyric_wrap_duration_or_plane_bound_changed");
                        long uploads = wrapRow.GlyphRasterizations, allocations = wrapRow.SurfaceCreations;
                        wrapRow.Width = 390; Arrange((Grid)componentWindow!.Content, 400, 340);
                        wrapRow.Width = 400; Arrange((Grid)componentWindow.Content, 400, 340);
                        Require(!wrapRow.GlyphUploadReady && wrapRow.GlyphRasterizations == uploads && wrapRow.SurfaceCreations == allocations,
                            "rapid_reverse_overwrote_fading_plane_or_bypassed_coalescing");
                        animationSamples.Add(new { stage = "wrap_active_and_reverse_deferred", wrapRow.WrapTransitionsStarted, wrapRow.WrapTransitionActive, wrapRow.WrapTransitionDurationMs, wrapRow.CachedPlaneCount, uploads, allocations });
                    });
                }
                Require(observedWrap, "real_glyph_reflow_did_not_start_compositor_crossfade");
                await Task.Delay(650);
                await OnUi(queue!, () => Pass("coalesced_gpu_wrap_and_reverse_retain_two_planes_and_settle", () =>
                {
                    Require(!wrapRow!.WrapTransitionActive && wrapRow.UsesCompositionSurface && wrapRow.CachedPlaneCount <= 2
                        && wrapRow.WrapTransitionsStarted >= transitionsBefore + 2 && requested.Count == 1,
                        "lyric_wrap_reverse_did_not_settle_or_changed_seek");
                    animationSamples.Add(new { stage = "wrap_settled", wrapRow.WrapTransitionsStarted, wrapRow.WrapTransitionActive, wrapRow.GlyphRasterizations, wrapRow.SurfaceCreations, wrapRow.CachedPlaneCount, native_compositor_animation_created = true, visible_presentation_verified = false });
                }));
            }
            else
            {
                cases.Add("wrap_animation_not_exercised_reduced_motion_or_native_fallback");
                animationSamples.Add(new { stage = "wrap_scope", reason = component!.MotionEnabled ? "composition_unavailable_native_fallback" : "system_motion_disabled", visible_presentation_verified = false });
            }
            step = "shaped_clusters_reflow_within_existing_plane_budget";
            Border? shapedHost = null;
            LyricsRowPresenter? shapedRow = null;
            if (canCheckWrap && !WindowSizing.ScreenReaderActive)
            {
                await OnUi(queue!, () =>
                {
                    var content = (Grid)componentWindow!.Content;
                    content.Children.Remove(wrapRow!);
                    component!.Update(LyricsDocument.Parse("[00:00.000]MOVE 字形 WRAP"), 0, false);
                    shapedRow = new LyricsRowPresenter
                    {
                        DataContext = ((Array)Field(component, "items")!).GetValue(0),
                        Width = 400, Style = (Style)component.Resources["LyricsRowButtonStyle"]
                    };
                    shapedHost = new Border { Child = shapedRow, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 95, 0, 0) };
                    content.Children.Add(shapedHost); Arrange(content, 400, 340);
                });
                await Task.Delay(330);
                await OnUi(queue!, () =>
                {
                    Require(shapedRow!.UsesCompositionSurface, "shaped_reflow_fixture_did_not_realize_glyphs");
                    shapedRow.Width = 220; Arrange((Grid)componentWindow!.Content, 400, 340);
                });
                bool observedClusters = false;
                for (int attempt = 0; attempt < 28 && !observedClusters; attempt++)
                {
                    await Task.Delay(18);
                    await OnUi(queue!, () =>
                    {
                        observedClusters = shapedRow!.GlyphReflowTransitionsStarted > 0 && shapedRow.GlyphReflowClusterCount > 1;
                        if (!observedClusters) return;
                        Require(shapedRow.CachedPlaneCount == 2 && shapedRow.WrapTransitionDurationMs is >= 190 and <= 480,
                            "shaped_reflow_exceeded_plane_or_duration_budget");
                        animationSamples.Add(new { stage = "directwrite_cluster_reflow", shapedRow.GlyphReflowClusterCount,
                            shapedRow.CachedPlaneCount, shapedRow.WrapTransitionDurationMs });
                        var content = (Grid)componentWindow!.Content;
                        shapedRow.Width = 260; Arrange(content, 400, 340);
                        shapedRow.Width = 400; Arrange(content, 400, 340);
                    });
                }
                if (!observedClusters) await OnUi(queue!, () => animationSamples.Add(new
                {
                    stage = "directwrite_cluster_reflow_unavailable", shapedRow!.GlyphReflowStatus, shapedRow.GlyphRasterizations,
                    shapedRow.WrapTransitionsStarted, shapedRow.ActualHeight, shapedRow.ActualWidth, shapedRow.GlyphBounds,
                    surface_top = Field(shapedRow, "surfaceTop"), edge_radius = Field(shapedRow, "edgeRadius"),
                    viewport_height = Field(shapedRow, "viewportHeight")
                }));
                Require(observedClusters, "directwrite_cluster_reflow_did_not_engage");
                await Task.Delay(720);
                await OnUi(queue!, () => Pass(step, () =>
                {
                    Require(shapedRow!.GlyphReflowClusterCount == 0 && !shapedRow.WrapTransitionActive
                        && shapedRow.CachedPlaneCount <= 2 && shapedRow.UsesCompositionSurface && requested.Count == 1,
                        "shaped_reflow_did_not_retire_with_current_glyphs_or_changed_seek");
                    ((Grid)componentWindow!.Content).Children.Remove(shapedHost!);
                }));
            }
            step = "interval_marker_narrow_single_line_fonts";
            var markerDocument = LyricsDocument.Parse("[00:00.000]A synthetic phrase\n[00:02.000]\n[00:04.000]The fixture continues");
            string secondMarkerFont = (NativeTypography.FindFamily("Microsoft YaHei UI")
                ?? NativeTypography.GetFamilies().First(family => family.Name != NativeTypography.SystemFamily.Name)).Name;
            LyricsRowPresenter? markerRow = null;
            foreach (string font in new[] { "", secondMarkerFont })
            {
                object? markerItem = null; long markerTransitions = 0;
                await OnUi(queue!, () =>
                {
                    var content = (Grid)componentWindow!.Content;
                    if (wrapRow != null && content.Children.Contains(wrapRow)) content.Children.Remove(wrapRow);
                    if (markerRow != null && content.Children.Contains(markerRow)) content.Children.Remove(markerRow);
                    component!.Update(markerDocument, 2_000, true, preferences: new UiPreferences { UiFontFamily = font });
                    markerItem = ((Array)Field(component, "items")!).Cast<LyricsRowItem>().Single(item => item.Line.Text.Length == 0);
                    markerRow = new LyricsRowPresenter { DataContext = markerItem, Width = 80, VerticalAlignment = VerticalAlignment.Top, Style = (Style)component.Resources["LyricsRowButtonStyle"] };
                    content.Children.Add(markerRow); Arrange(content, 400, 340);
                });
                await Task.Delay(180);
                await OnUi(queue!, () =>
                {
                    var text = (TextBlock)Field(markerRow!, "original")!;
                    Require(text.Text == "…" && text.TextWrapping == TextWrapping.NoWrap && text.MaxLines == 1 && text.CharacterSpacing == 0,
                        "interval_marker_native_text_can_wrap");
                    using var layout = (CanvasTextLayout)typeof(LyricsRowPresenter).GetMethod("CreateTextLayout", BindingFlags.NonPublic | BindingFlags.Static)!
                        .Invoke(null, [CanvasDevice.GetSharedDevice(), text, component!.TextScale])!;
                    Require(layout.LineMetrics.Length == 1 && text.ActualHeight > 0 && text.ActualHeight <= layout.LineMetrics[0].Height * 1.5,
                        "interval_marker_narrow_layout_has_multiple_lines");
                    var peer = new ButtonAutomationPeer(markerRow!); int before = requested.Count;
                    Require(peer.GetName() == L.Text("歌词间隔", "Instrumental break") && markerRow!.Item?.Line.TimeMs == 2_000
                        && ReferenceEquals(markerRow.Item, markerItem) && peer.GetPattern(PatternInterface.Invoke) is IInvokeProvider,
                        "interval_marker_lost_accessibility_or_timestamp_identity");
                    ((IInvokeProvider)peer.GetPattern(PatternInterface.Invoke)).Invoke();
                    Require(requested.Count == before + 1 && requested[^1] == 2_000, "interval_marker_seek_timestamp_changed");
                    markerTransitions = markerRow!.WrapTransitionsStarted; markerRow.Width = 96; Arrange((Grid)componentWindow!.Content, 400, 340);
                    layouts.Add(new { kind = "interval_marker_font", requested_font = font, actual_font = text.FontFamily.Source, narrow_width = 80, text_height = text.ActualHeight, glyph_line_count = layout.LineMetrics.Length, time_ms = 2_000 });
                });
                await Task.Delay(250);
                await OnUi(queue!, () => Require(markerRow!.WrapTransitionsStarted == markerTransitions && !markerRow.WrapTransitionActive,
                    "interval_marker_width_change_started_unnecessary_wrap_transition"));
            }
            cases.Add("interval_marker_is_single_line_at_narrow_width_in_two_fonts_and_keeps_seek_identity");
            await OnUi(queue!, () => Pass("lyric_viewport_helpers_keep_center_and_reduced_effects_policy", () =>
            {
                Require(Math.Abs(LyricsViewport.FollowOffset(50, 200, 100, 500, 1_000) - 122) < .001, "lyric_follow_anchor_changed");
                Require(LyricsViewport.EdgeBlur(0, 1_000, false, true) == 4 && LyricsViewport.EdgeBlur(1_000, 1_000, false, true) == 12
                    && LyricsViewport.EdgeBlur(320, 1_000, false, true) == 0 && LyricsViewport.EdgeBlur(0, 1_000, false, false) == 0, "lyric_edge_effect_policy_changed");
            }));
            await OnUi(queue!, () => Pass("follow_wave_rolls_forward_continuously_and_keeps_bounded_offsets", () =>
            {
                const long start = 10_000_000;
                long At(double milliseconds) => start + (long)(milliseconds * Stopwatch.Frequency / 1_000);
                const double viewport = 320;
                var forward = new LyricsFollowMotion(start, 50, 120, 420, 140);
                Require(LyricsViewport.AnchorOffset(140, 210, 90, 1_000) == 260
                    && LyricsViewport.AnchorOffset(10, 5, 30, 500) == 0
                    && LyricsViewport.AnchorOffset(490, 100, 20, 500) == 500, "reading_anchor_offset_outside_scroll_extent");
                Require(forward.ScrollOffset(start) == 50 && forward.ScrollOffset(At(421)) == 120
                    && !forward.IsComplete(At(559)) && forward.IsComplete(At(561)), "follow_scroll_does_not_settle_within_configured_timing");
                long reverseAt = At(250);
                float bottom = forward.RowOffset(reverseAt, 32, viewport, viewport);
                Require(forward.RowOffset(reverseAt, 0, 0, viewport) == 0 && bottom > 0
                    && forward.RowOffset(At(561), 32, viewport, viewport) == 0, "follow_lag_does_not_respect_row_rank");
                Require(forward.RowOffset(reverseAt, 32, 0, viewport) == bottom
                    && forward.RowOffset(reverseAt, 0, viewport, viewport) == 0, "follow_lag_changed_rank_as_rows_scrolled");
                var reverse = new LyricsFollowMotion(reverseAt, forward.ScrollOffset(reverseAt), 50, 420, 1_000);
                for (int rank = 0; rank <= 32; rank++)
                {
                    double before = rank * 10, after = viewport - before;
                    float shown = forward.RowOffset(reverseAt, rank, before, viewport);
                    reverse.CaptureRank(rank, after, viewport, shown);
                    Require(reverse.RowOffset(reverseAt, rank, before, viewport) == shown,
                        "follow_lag_is_discontinuous_at_reverse");
                    for (int t = 250; t <= 1_700; t += 25)
                        Require(Math.Abs(reverse.RowOffset(At(t), rank, after, viewport)) <= 36.001, "follow_lag_exceeded_bound");
                }
                Require(reverse.IsComplete(At(1_671)) && reverse.RowOffset(At(1_671), 32, 0, viewport) == 0,
                    "follow_lag_did_not_finish");
                for (int index = 33; index < LyricsFollowMotion.MaximumTrackedRows; index++)
                    forward.CaptureRank(index, viewport, viewport, 0);
                Require(forward.RowOffset(reverseAt, LyricsFollowMotion.MaximumTrackedRows, viewport, viewport) == 0
                    && forward.RowOffset(reverseAt, 32, 0, viewport) == bottom, "follow_lag_did_not_bound_its_virtualized_rows");
            }));
            step = "native_resize_typography";
            await CheckNativeResizeTypography();
            step = "native_cover_bottom_paging";
            await OnUi(queue!, () =>
            {
                model!.Preferences.Update(model.Preferences.Value with { NarrowPlayerLayout = "cover", CoverLyricsPane = "collapsed", LyricsDisplayMode = "never" });
                Accept(source with { Phase = ReceiverPhase.Paused });
                WindowSizing.ResizeContent(main!, 360, 360);
            });
            await WaitLyrics();
            await Task.Delay(180);
            await OnUi(queue!, () => Pass("collapsed_cover_opens_lyrics_page_even_with_global_visibility_off", () =>
            {
                var pager = (CompactLyricsPager)Field(main!, "miniPager")!;
                Require(pager.Active && pager.Navigate(true), "collapsed_cover_lyrics_page_unreachable");
                Require(!LyricsVisible(), "cover_paging_changed_lyric_visibility_preference");
                Require(pager.Navigate(false), "cover_bottom_preview_requires_the_playback_page");
            }));
            async Task DragCoverPane(int height, bool expanded)
            {
                await OnUi(queue!, () =>
                {
                    var size = MainSize();
                    double scale = GetDpiForWindow(mainHwnd) / 96d;
                    Require(Math.Abs(size.Width - 360) <= 2 && GetWindowRect(mainHwnd, out _), "native_cover_fixture_not_square_width");
                    _ = GetWindowRect(mainHwnd, out var bounds);
                    bounds.Bottom += (int)Math.Round((height - size.Height) * scale);
                    _ = SendMessage(mainHwnd, 0x0231, 0, 0);
                    _ = SendSizing(mainHwnd, 0x0214, 6, ref bounds);
                    WindowSizing.ResizeContent(main!, size.Width, height);
                });
                try
                {
                    await Task.Delay(130);
                    await OnUi(queue!, () =>
                    {
                        Require(Field(main!, "coverLyricsResizing") is true && Field(main!, "miniPager") is CompactLyricsPager { Active: false }
                            && Grid.GetRow(Find<Grid>("MiniLyricsHost")) == 2 && Find<Grid>("MiniLyricsHost").Visibility == Visibility.Visible,
                            "native_cover_drag_enabled_paging_or_lost_preview");
                    });
                }
                finally { await OnUi(queue!, () => { _ = SendMessage(mainHwnd, 0x0232, 0, 0); }); }
                await Task.Delay(180);
                await OnUi(queue!, () => Pass(expanded ? "native_bottom_expands_and_persists_cover_pane" : "native_bottom_collapses_then_restores_horizontal_paging", () =>
                {
                    var size = MainSize();
                    var pager = (CompactLyricsPager)Field(main!, "miniPager")!;
                    string pane = expanded ? "expanded" : "collapsed";
                    Require(!pager.ShowingLyrics && pager.Active != expanded && Math.Abs(size.Height - (expanded ? 496 : 360)) <= 2,
                        "native_cover_settle_height_or_paging_wrong");
                    Require(model!.Preferences.Value.LyricsDisplayMode == "never" && new UiPreferencesStore(store.Data).Value.CoverLyricsPane == pane,
                        "native_cover_gesture_lost_pane_or_changed_global_lyrics_mode");
                }));
            }
            await DragCoverPane(440, expanded: true);
            await DragCoverPane(388, expanded: false);
            step = "fullscreen_policy_without_presenter_attachment";
            await OnUi(queue!, () => Pass(step, () =>
            {
                var accelerators = Root().KeyboardAccelerators;
                Require(accelerators.Any(key => key.Key == VirtualKey.F11) && accelerators.Any(key => key.Key == VirtualKey.Escape)
                    && accelerators.Any(key => key.Key == VirtualKey.F && key.Modifiers == (VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift)), "fullscreen_keyboard_routes_missing");
                Require(Find<Button>("MiniFullScreenButton") != null && Find<Button>("ExpandedFullScreenButton") != null && Root().ContextFlyout is MenuFlyout flyout && flyout.Items.OfType<MenuFlyoutItem>().Any(item => item.Name == "FullScreenMenuItem"), "fullscreen_menu_or_buttons_missing");
                var presenter = FullScreenPresenter.Create(); presenterObjectCreated = presenter.Kind == AppWindowPresenterKind.FullScreen;
                policyWindow = new Window { Content = new Grid(), Title = "FusionPlay Hidden Fullscreen Policy" }; Track(policyWindow);
                policy = WindowSizing.FixedSquare(policyWindow, _ => { }); policy.SetPlayerLayout(true, true); WindowSizing.ResizeContent(policyWindow, 640, 360);
                Require(!main!.IsFullScreen && main.AppWindow.Presenter.Kind == AppWindowPresenterKind.Overlapped && policyWindow.AppWindow.Presenter.Kind == AppWindowPresenterKind.Overlapped, "fullscreen_presenter_was_attached");
            }));
            await Task.Delay(200);
            await OnUi(queue!, () => Pass("fullscreen_sizing_policy_routes_whole_hidden_client_without_caption", () =>
            {
                var input = InputNonClientPointerSource.GetForWindowId(policyWindow!.AppWindow.Id);
                Require(input.GetRegionRects(NonClientRegionKind.Caption).Length == 0 && input.GetRegionRects(NonClientRegionKind.TopBorder).Length == 0, "fullscreen_policy_retained_nonclient_drag_regions");
                Require(GetClientRect(WinRT.Interop.WindowNative.GetWindowHandle(policyWindow), out var rect), "fullscreen_policy_client_missing");
                Require(input.GetRegionRects(NonClientRegionKind.Passthrough).Any(region => Contains(region, new(0, 0, rect.Right - rect.Left, rect.Bottom - rect.Top))), "fullscreen_policy_client_not_passthrough");
            }));
            Background(); Require(UnhandledErrors.Count == 0, "lyrics_check_unhandled_errors"); status = "passed"; step = "complete";
        }
        catch (Exception error)
        {
            failure = error is CheckFailure ? error.Message : "lyrics_check_exception"; exception = error.GetType().Name; hresult = error.HResult.ToString("X8"); exceptionDetail = error.ToString();
            File.AppendAllText(Path.Combine(directory, "capture-steps.txt"), "failure:" + step + ":" + failure + "\n");
        }
        finally
        {
            try { if (queue != null) await OnUi(queue, () => { settings?.Close(); settings = null; if (main != null) { main.AllowClose = true; main.Close(); main = null; } component?.Dispose(); componentWindow?.Close(); componentWindow = null; policy?.Dispose(); policyWindow?.Close(); policyWindow = null; Background(); }); }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            try { if (model != null) { await model.DisposeAsync(); model = null; } }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            try
            {
                if (preferencesCaptured)
                {
                    if (originalPreferences != null) { Directory.CreateDirectory(store.Data); File.WriteAllBytes(preferencesPath, originalPreferences); }
                    else if (File.Exists(preferencesPath)) File.Delete(preferencesPath);
                    if (Directory.Exists(store.Data)) foreach (var file in Directory.GetFiles(store.Data, "ui-preferences.json.invalid-*")) if (!originalInvalid.Contains(file)) File.Delete(file);
                    preferencesRestored = originalPreferences == null ? !File.Exists(preferencesPath) : File.ReadAllBytes(preferencesPath).AsSpan().SequenceEqual(originalPreferences);
                }
                L.Language = originalLanguage;
            }
            catch (Exception error) { cleanupErrors.Add(error.GetType().Name); }
            void Finish()
            {
                try { Background(); Require(preferencesRestored && UnhandledErrors.Count == 0, "lyrics_final_cleanup_or_errors"); } catch (Exception error) { status = "failed"; failure = error.Message; }
                if (cleanupErrors.Count > 0) { status = "failed"; failure = "lyrics_cleanup_failed"; }
                try
                {
                    File.WriteAllText(Path.Combine(directory, "lyrics-player-check.json"), JsonSerializer.Serialize(new
                    {
                        status, step, failure_code = failure, exception_type = exception, hresult, exception_detail = exceptionDetail, cases, layout_samples = layouts, captures, animation_samples = animationSamples,
                        window_remained_hidden = hidden, foreground_unchanged = focus, foreground_not_taken = foregroundNotTaken, preferences_restored = preferencesRestored,
                        native_receiver_created = false, receiver_initialized = false, receiver_polling_started = false, shell_media_session_created = false,
                        single_instance_notification_sent = false, initialized_flag_is_fixture = initializedFixture, synthetic_cover_only = true,
                        fullscreen_presenter_object_created = presenterObjectCreated, fullscreen_presenter_attached = false, fullscreen_enter_exit_tested = false,
                        component_row_was_realized_by_list = componentRowWasRealized, unhandled_errors = UnhandledErrors, cleanup_errors = cleanupErrors,
                        scope = "hidden_real_controller_parser_player_geometry_sdk_input_and_component_invoke; no_phone_audio_or_visible_fullscreen_interaction; render_target_capture_does_not_prove_composition_materials"
                    }, new JsonSerializerOptions { WriteIndented = true }));
                }
                finally { anchor?.Close(); }
            }
            if (queue == null || queue.HasThreadAccess) Finish(); else await OnUi(queue, Finish);
        }
    }

    private static async Task<byte[]> MakeCoverAsync()
    {
        const uint side = 256; var pixels = new byte[side * side * 4];
        for (int y = 0; y < side; y++) for (int x = 0; x < side; x++)
        {
            int index = (y * (int)side + x) * 4; bool warm = x >= 128;
            pixels[index] = (byte)(warm ? 60 + y / 4 : 170 + x / 4); pixels[index + 1] = (byte)(warm ? 145 + y / 5 : 65 + y / 4);
            pixels[index + 2] = (byte)(warm ? 230 : 35 + x / 3); pixels[index + 3] = 255;
        }
        using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, side, side, 96, 96, pixels); await encoder.FlushAsync();
        var bytes = new byte[checked((int)stream.Size)]; using var reader = new DataReader(stream.GetInputStreamAt(0)); await reader.LoadAsync((uint)bytes.Length); reader.ReadBytes(bytes); return bytes;
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        yield return root;
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++) foreach (var child in Descendants(VisualTreeHelper.GetChild(root, index))) yield return child;
    }
    private static bool Contains(RectInt32 a, RectInt32 b) => a.X <= b.X && a.Y <= b.Y && a.X + a.Width >= b.X + b.Width && a.Y + a.Height >= b.Y + b.Height;
    private static bool Overlaps(RectInt32 a, RectInt32 b) => a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height;
    private static Task OnUi(DispatcherQueue queue, Action action)
    {
        var result = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() => { try { action(); result.SetResult(); } catch (Exception error) { result.SetException(error); } })) result.TrySetException(new CheckFailure("lyrics_dispatcher_enqueue_failed"));
        return result.Task;
    }
}
