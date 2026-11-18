using System.Reflection;
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
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    private sealed class CheckFailure(string code) : Exception(code);
    private sealed record Box(double X, double Y, double Width, double Height);

    public static async Task Run(string directory)
    {
        Directory.CreateDirectory(directory);
        var queue = DispatcherQueue.GetForCurrentThread();
        nint foreground = GetForegroundWindow(), mainHwnd = 0;
        var handles = new List<nint>();
        var cases = new List<string>(); var layouts = new List<object>(); var captures = new List<object>(); var cleanupErrors = new List<string>();
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
                if (compact) Require(Math.Abs(coverBox.Width - width) <= 2 && Math.Abs(coverBox.Height - width) <= 2 && hostBox.Y >= coverBox.Y + coverBox.Height, "mini_lyric_cover_not_square_or_overlaps");
                else
                {
                    Require(hostBox.X >= coverBox.X + coverBox.Width, "expanded_lyrics_not_on_right");
                    var details = Bounds(Find<Grid>("ExpandedDetails"));
                    var layout = Bounds(Find<Grid>("PlayerLayout"));
                    double topSpace = coverBox.Y - layout.Y, bottomSpace = layout.Y + layout.Height - details.Y - details.Height;
                    Require(details.Y >= coverBox.Y + coverBox.Height + 13, "expanded_metadata_has_no_cover_gap");
                    Require(Math.Abs(topSpace - bottomSpace) < 2, "expanded_cover_and_controls_not_centered_as_group");
                    Require(Math.Abs(details.X - (layout.X + (Math.Min(330, width * .38) - details.Width) / 2)) < 2, "expanded_metadata_not_aligned_to_column");
                }
                var viewport = Descendants(host).OfType<ScrollViewer>().FirstOrDefault() ?? throw new CheckFailure("lyrics_native_scroll_viewport_missing");
                var box = Bounds(viewport); double scale = Root().XamlRoot!.RasterizationScale;
                int left = (int)Math.Floor(Math.Max(box.X, hostBox.X) * scale), top = (int)Math.Floor(Math.Max(box.Y, hostBox.Y) * scale);
                int right = (int)Math.Ceiling(Math.Min(box.X + box.Width, hostBox.X + hostBox.Width) * scale), bottom = (int)Math.Ceiling(Math.Min(box.Y + box.Height, hostBox.Y + hostBox.Height) * scale);
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
                if (!passthrough.Any(rect => Contains(rect, viewportRect)))
                    layouts.Add(new { kind = "viewport_input_mismatch", name, frame, original = originalViewport, usable = viewportRect, host = hostBox, passthrough, innerLeft, innerTop, innerRight, innerBottom });
                Require(viewportRect.Width > 0 && viewportRect.Height > 0 && passthrough.Any(rect => Contains(rect, viewportRect)), "lyrics_viewport_not_native_passthrough");
                Require(!input.GetRegionRects(NonClientRegionKind.Caption).Any(rect => Overlaps(rect, viewportRect)), "lyrics_viewport_overlaps_caption");
            }
            else if (compact) Require(Math.Abs(size.Width - size.Height) <= 2, "cover_only_mini_not_square");
            layouts.Add(new { name, frame, width = size.Width, height = size.Height, lyrics, compact, cover = coverBox, host = hostBox, native_viewport = viewportRect, passthrough_count = passthroughCount });
            Background();
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
            await Task.Delay(400);
            step = "real_player_layouts";
            foreach (var size in new[] { (320, 456), (420, 640), (840, 600), (840, 340), (840, 760) })
            {
                File.AppendAllText(Path.Combine(directory, "capture-steps.txt"), $"resize:{size.Item1}x{size.Item2}\n");
                await OnUi(queue!, () => WindowSizing.ResizeContent(main!, size.Item1, size.Item2)); await Task.Delay(500);
                for (int frame = 0; frame < 4; frame++) { int sample = frame; await OnUi(queue!, () => Frame("timed", sample, size.Item1, size.Item2, true, size.Item1 < 600)); await Task.Delay(25); }
                await Capture($"lyrics-{size.Item1}x{size.Item2}");
            }
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
            cases.Add("twenty_four_real_layout_and_sdk_region_frames");
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
                Require(Field(component, "browsing") is true && ((DispatcherQueueTimer)Field(component, "browsingTimer")!).Interval == TimeSpan.FromSeconds(6), "manual_browse_policy_not_six_seconds");
            });
            await Task.Delay(6_150);
            await OnUi(queue!, () => Pass("manual_browse_expires_and_return_button_uses_native_invoke", () =>
            {
                Require(Field(component!, "browsing") is false, "manual_browse_did_not_expire");
                typeof(LyricsView).GetMethod("BeginBrowsing", Private)!.Invoke(component, null);
                var button = Descendants(component!).OfType<Button>().Single(item => item.Name == "LyricsReturnToCurrent");
                ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
                Require(Field(component!, "browsing") is false && requested.Count == 1, "return_to_current_changed_seek_or_did_not_return");
            }));
            await OnUi(queue!, () => Pass("lyric_viewport_helpers_keep_center_and_reduced_effects_policy", () =>
            {
                Require(Math.Abs(LyricsViewport.FollowOffset(50, 200, 100, 500, 1_000) - 122) < .001, "lyric_follow_anchor_changed");
                Require(LyricsViewport.EdgeBlur(0, 1_000, false, true) == 4 && LyricsViewport.EdgeBlur(1_000, 1_000, false, true) == 12
                    && LyricsViewport.EdgeBlur(320, 1_000, false, true) == 0 && LyricsViewport.EdgeBlur(0, 1_000, false, false) == 0, "lyric_edge_effect_policy_changed");
            }));
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
                        status, step, failure_code = failure, exception_type = exception, hresult, exception_detail = exceptionDetail, cases, layout_samples = layouts, captures,
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
