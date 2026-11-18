using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using FusionPlay.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace FusionPlay.Windows.Platform;

/// <summary>Hidden production-view fixtures; never creates a receiver or media session.</summary>
internal static class PlayerRefinementCheck
{
    internal static List<string> UnhandledErrors { get; } = [];
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] private static extern bool GetClientRect(nint hwnd, out NativeRect rect);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern nint SendMessage(nint hwnd, uint message, nuint wparam, nint lparam);
    private sealed class CheckFailure(string code) : Exception(code);

    public static async Task Run(string directory)
    {
        Directory.CreateDirectory(directory);
        var queue = DispatcherQueue.GetForCurrentThread();
        Window? anchor = null; MainWindow? main = null; TrayWindow? tray = null; ReceiverController? model = null;
        var windows = new List<nint>(); var cases = new List<string>(); var samples = new List<object>(); var captures = new List<string>();
        var cleanup = new List<string>(); nint foreground = GetForegroundWindow(), hwnd = 0;
        bool hidden = true, foregroundNotTaken = true, restored = false, preferencesCaptured = false;
        string status = "failed", step = "create_fixture", failure = "", detail = "", originalLanguage = L.Language;
        var store = new PortableStore(AppContext.BaseDirectory); string preferencesPath = Path.Combine(store.Data, "ui-preferences.json");
        byte[]? originalPreferences = null; ulong revision = 0;
        void Require(bool condition, string code) { if (!condition) throw new CheckFailure(code); }
        object? Field(object instance, string name) => instance.GetType().GetField(name, Private)?.GetValue(instance);
        FrameworkElement Root() => (FrameworkElement)main!.Content;
        T Find<T>(string name) where T : FrameworkElement => Root().FindName(name) as T
            ?? Descendants(Root()).OfType<T>().FirstOrDefault(item => item.Name == name) ?? throw new CheckFailure("element_missing_" + name);
        void Background()
        {
            var handles = windows.ToArray();
            hidden &= handles.All(handle => !IsWindowVisible(handle)); foregroundNotTaken &= !handles.Contains(GetForegroundWindow());
            Require(hidden && foregroundNotTaken, "hidden_fixture_became_visible_or_took_focus");
            if (model != null) Require(Field(model, "native") == null && Field(model, "polling") == null, "fixture_started_receiver");
        }
        void Track(Window window) { window.AppWindow.IsShownInSwitchers = false; windows.Add(WinRT.Interop.WindowNative.GetWindowHandle(window)); Background(); }
        void Pass(string name, Action action) { Background(); action(); Background(); cases.Add(name); }
        void Accept(ReceiverSnapshot state)
        {
            // Synthetic fixtures deliberately skip artwork tasks and network loading.
            typeof(ReceiverController).GetField("artworkKey", Private)!.SetValue(model, state.ControlsAvailable ? state.TrackId + "|" + state.ArtworkUrl : "");
            Require(typeof(ReceiverController).GetMethod("Accept", Private)!.Invoke(model, [new PollResult(++revision, state)]) is true, "source_fixture_rejected");
        }
        (double Width, double Height) Size()
        {
            Require(GetClientRect(hwnd, out var rect), "native_client_unavailable");
            double scale = Math.Max(96, GetDpiForWindow(hwnd)) / 96.0;
            return ((rect.Right - rect.Left) / scale, (rect.Bottom - rect.Top) / scale);
        }
        void Arrange()
        {
            Background(); var size = Size();
            foreach (var control in Descendants(Root()).OfType<Control>().ToArray()) control.ApplyTemplate();
            Root().Measure(new Size(size.Width, size.Height)); Root().Arrange(new Rect(0, 0, size.Width, size.Height)); Root().UpdateLayout();
        }
        bool Visible(UIElement element)
        {
            for (DependencyObject? current = element; current != null; current = VisualTreeHelper.GetParent(current))
                if (current is UIElement { Visibility: Visibility.Collapsed }) return false;
            return true;
        }
        bool LyricsVisible() => Field(main!, "lyricsVisible") is true;
        async Task Settle(int milliseconds = 260) { await Task.Delay(milliseconds); await OnUi(queue!, Arrange); }
        async Task Parsed()
        {
            for (int attempt = 0; attempt < 100; attempt++)
            {
                bool ready = false; await OnUi(queue!, () => { Background(); ready = !model!.LyricsLoading; });
                if (ready) { await Settle(); return; } await Task.Delay(30);
            }
            throw new CheckFailure("synthetic_lyrics_parse_timeout");
        }
        async Task Capture(string name)
        {
            await OnUi(queue!, async () =>
            {
                Arrange(); var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(Root());
                var buffer = await bitmap.GetPixelsAsync(); var pixels = new byte[checked((int)buffer.Length)];
                using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
                Require(bitmap.PixelWidth > 0 && bitmap.PixelHeight > 0 && pixels.Length == bitmap.PixelWidth * bitmap.PixelHeight * 4, "snapshot_empty");
                using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels);
                await encoder.FlushAsync(); stream.Seek(0);
                using var output = File.Create(Path.Combine(directory, name + ".png"));
                using var data = new DataReader(stream); await data.LoadAsync((uint)stream.Size); var bytes = new byte[checked((int)stream.Size)]; data.ReadBytes(bytes);
                await output.WriteAsync(bytes); captures.Add(name + ".png"); Background();
            });
        }
        var song = new ReceiverSnapshot { ControlsAvailable = true, Phase = ReceiverPhase.Playing, TrackId = "refinement-song",
            Title = "touch her", Artist = "A Synthetic Question-Example Artist", Album = "Example Album", DurationMs = 180_000, PositionMs = 8_000,
            LyricsText = "[ti:A Synthetic Question]\n[ar:Example Artist]\n[al:Example Album]\n[00:00]Someone may touch her, just once.\n[00:04]Another synthetic line\n[00:08]One more fixture line" };
        try
        {
            Require(queue != null, "dispatcher_unavailable");
            await OnUi(queue!, () =>
            {
                anchor = new Window { Content = new Grid(), Title = "FusionPlay Hidden Refinement Anchor" }; Track(anchor);
                originalPreferences = File.Exists(preferencesPath) ? File.ReadAllBytes(preferencesPath) : null; preferencesCaptured = true;
                model = new ReceiverController(queue!);
                model.Preferences.Update(new UiPreferences { ShowProgress = true, ShowTransport = true, AlwaysShowControls = true, LyricsDisplayMode = "always" });
                main = new MainWindow(model, () => { }); Track(main); hwnd = WinRT.Interop.WindowNative.GetWindowHandle(main);
                tray = new TrayWindow(model, () => { }, () => { }, () => { }, () => null); Track(tray);
                typeof(ReceiverController).GetProperty(nameof(ReceiverController.Initialized))!.SetValue(model, true);
                Accept(new ReceiverSnapshot { Phase = ReceiverPhase.Ready }); WindowSizing.ResizeContent(main, 420, 420);
            });
            await Settle(); step = "idle_compact";
            await OnUi(queue!, () => Pass(step, () =>
            {
                Require(!model!.HasCurrentTrack && Field(main!, "idle") is true && Visible(Find<FontIcon>("IdlePlaceholder")), "idle_note_missing");
                Require(!LyricsVisible() && !Visible(Find<PlayerText>("MiniTitle")) && !Visible(Find<ProgressSeekButton>("MiniProgressSeek"))
                    && !Visible(Find<Button>("MiniPlayButton")), "idle_retained_track_content");
                Require(model.Preferences.Value is { ShowProgress: true, ShowTransport: true, LyricsDisplayMode: "always" }, "idle_modified_preferences");
                Require(!Find<ProgressSeekButton>("MiniProgressSeek").IsEnabled, "idle_seek_enabled");
                var caption = InputNonClientPointerSource.GetForWindowId(main!.AppWindow.Id).GetRegionRects(NonClientRegionKind.Caption);
                Require(caption.Length > 0, "idle_lost_native_drag_regions");
                samples.Add(new { mode = "idle_compact", requested_backdrop = main.SystemBackdrop?.GetType().Name, high_contrast = new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast,
                    transparent_root = Root() is Panel { Background: SolidColorBrush brush } && brush.Color.A == 0, visible_material_verified = false });
            }));
            await Capture("idle-420x420");
            await OnUi(queue!, () => WindowSizing.ResizeContent(main!, 840, 600)); await Settle();
            await OnUi(queue!, () => Pass("idle_expanded", () =>
            {
                Require(Visible(Find<FontIcon>("IdlePlaceholder")) && !Visible(Find<Grid>("PlayerLayout")) && !Visible(Find<Button>("PlayButton")), "expanded_idle_retained_player");
                Require(!Visible(Find<Button>("SettingsButton")) && !Visible(Find<Button>("PinButton")), "idle_retained_nonwindow_actions");
                Require(Math.Abs(Size().Width - 840) <= 2 && Math.Abs(Size().Height - 600) <= 2, "idle_changed_native_size");
                Accept(song); model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" });
            }));
            await Parsed(); step = "original_display";
            await OnUi(queue!, () => Pass(step, () =>
            {
                Require(!model!.Preferences.Value.CorrectLyricTitles && model.DisplayMetadata.Title == song.Title && model.State == song, "default_display_changed_source");
                Require(Find<PlayerText>("TitleText").Text == song.Title && Field(main!, "idle") is false, "normal_title_not_restored");
                model.Preferences.Update(model.Preferences.Value with { CorrectLyricTitles = true });
            }));
            await Settle();
            await OnUi(queue!, () => Pass("corrected_display_and_raw_controls", () =>
            {
                Require(model!.DisplayMetadata is { Title: "A Synthetic Question", Artist: "Example Artist", WasCorrected: true }, "verified_title_not_corrected");
                Require(Find<PlayerText>("TitleText").Text == "A Synthetic Question" && Find<PlayerText>("MiniTitle").Text == "A Synthetic Question", "player_displays_disagree");
                var trayTitle = Descendants((DependencyObject)tray!.Content).OfType<PlayerText>().First(item => item.Name == "TrackTitle");
                Require(trayTitle.Text == "A Synthetic Question", "tray_title_not_corrected");
                var display = SystemMedia.DisplaySnapshot(model.State, model.DisplayMetadata);
                Require(display.Title == "A Synthetic Question" && display.Artist == "Example Artist" && display.TrackId == song.TrackId && display.PositionMs == song.PositionMs, "system_metadata_selection_wrong");
                var request = Seeking.AtFraction(model.State, .5);
                Require(model.State == song && request != null && request.ExpectedTitle == song.Title && request.ExpectedTrackId == song.TrackId && request.PositionMs == 90_000, "display_correction_changed_control_source");
                Accept(song with { Phase = ReceiverPhase.Paused }); model.Preferences.Update(model.Preferences.Value with { CorrectLyricTitles = false });
                Require(Find<PlayerText>("TitleText").Text == song.Title, "paused_preference_did_not_restore_original_title");
                model.Preferences.Update(model.Preferences.Value with { CorrectLyricTitles = true });
                Require(Find<PlayerText>("TitleText").Text == "A Synthetic Question", "paused_preference_did_not_refresh_title");
            }));
            await Capture("corrected-title-840x600");
            await OnUi(queue!, () => Pass("transient_source_gaps_keep_controls", () =>
            {
                Accept(song with { Phase = ReceiverPhase.Connected, DurationMs = null, PositionMs = null }); Arrange();
                Require(model!.HasCurrentTrack && Field(main!, "idle") is false && Visible(Find<ProgressSeekButton>("ProgressSeek"))
                    && !Find<ProgressSeekButton>("ProgressSeek").IsEnabled && Visible(Find<Button>("PlayButton")), "metadata_gap_entered_idle");
                Accept(song with { ControlsAvailable = false, DurationMs = null, PositionMs = null }); Arrange();
                Require(model.HasCurrentTrack && Field(main!, "idle") is false && Visible(Find<ProgressSeekButton>("ProgressSeek"))
                    && !Find<Button>("PlayButton").IsEnabled, "control_gap_collapsed_content");
                Accept(song); model.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "always" });
                WindowSizing.ResizeContent(main!, 320, 600);
            }));
            await Parsed();
            double rememberedPane = 0, targetHeight = 0; const double initialWidth = 320;
            await OnUi(queue!, () =>
            {
                var area = DisplayArea.GetFromWindowId(main!.AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
                double maximumHeight = area.Height / (Math.Max(96, GetDpiForWindow(hwnd)) / 96.0) - 14;
                targetHeight = Math.Min(780, maximumHeight - 40); Require(targetHeight >= initialWidth + 180, "work_area_too_short_for_height_fixture");
                SendMessage(hwnd, 0x231, 0, 0); WindowSizing.ResizeContent(main, initialWidth, targetHeight); SendMessage(hwnd, 0x232, 0, 0);
            });
            await Settle();
            await OnUi(queue!, () => Pass("manual_lyrics_pane_height_remembered", () =>
            {
                var size = Size(); rememberedPane = size.Height - size.Width;
                Require(LyricsVisible() && Math.Abs(size.Width - initialWidth) <= 2 && Math.Abs(size.Height - targetHeight) <= 3, "manual_height_not_accepted");
                Require(Root().FindName("MiniLyricsDivider") == null && Root().FindName("MiniLyricsGapRow") is RowDefinition gap && gap.Height.Value == 8,
                    "transparent_album_lyrics_gap_wrong");
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" });
            }));
            await Settle();
            await OnUi(queue!, () => { Require(Math.Abs(Size().Height - initialWidth) <= 2, "hide_did_not_restore_square"); model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "always" }); });
            await Settle();
            await OnUi(queue!, () => Pass("lyrics_toggle_restores_custom_pane_height", () =>
            {
                var size = Size(); Require(Math.Abs(size.Height - (initialWidth + rememberedPane)) <= 3, "toggle_reset_custom_height");
                samples.Add(new { mode = "restored_height", width = size.Width, height = size.Height, remembered_pane = rememberedPane });
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "never" });
            }));
            await Settle(); await OnUi(queue!, () => WindowSizing.ResizeContent(main!, 360, 360)); await Settle();
            await OnUi(queue!, () => model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "always" })); await Settle();
            await OnUi(queue!, () => Pass("pane_height_is_independent_of_cover_width", () =>
            {
                Require(Math.Abs(Size().Height - (360 + rememberedPane)) <= 3, "cover_width_changed_saved_lyric_pane_height");
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "automatic" });
                Accept(song with { TrackId = "refinement-no-lyrics", LyricsText = "", PositionMs = null });
            }));
            await Settle(120);
            await OnUi(queue!, () => Require(model!.LyricsLoading && !model.Lyrics.HasLyrics && LyricsVisible(), "metadata_wait_did_not_keep_empty_pane"));
            await Settle(2_100);
            await OnUi(queue!, () =>
            {
                Require(!LyricsVisible() && Math.Abs(Size().Height - 360) <= 2, "no_lyrics_timeout_did_not_collapse");
                Accept(song with { TrackId = "refinement-next-lyrics" });
            });
            await Parsed();
            await OnUi(queue!, () => Pass("no_lyrics_track_keeps_custom_height_for_next_song", () =>
            {
                Require(LyricsVisible() && Math.Abs(Size().Height - (360 + rememberedPane)) <= 3, "next_song_lost_custom_pane_height");
                Accept(new ReceiverSnapshot { Phase = ReceiverPhase.Ready });
            }));
            await Settle();
            await OnUi(queue!, () => Pass("real_media_end_returns_to_idle_without_changing_preferences", () =>
            {
                Require(!model!.HasCurrentTrack && !model.LyricsAvailable && !LyricsVisible() && Field(main!, "idle") is true
                    && Visible(Find<FontIcon>("IdlePlaceholder")) && !Visible(Find<PlayerText>("MiniTitle")), "media_end_did_not_clear_presentation");
                Require(model.Preferences.Value.ShowProgress && model.Preferences.Value.ShowTransport, "media_end_changed_control_preferences");
            }));
            step = "idle_and_lyrics_acrylic_handoff";
            SystemBackdrop? idleMaterial = null;
            await OnUi(queue!, () =>
            {
                var material = (PlayerAcrylic)Field(main!, "acrylic")!;
                model!.Preferences.Update(model.Preferences.Value with { LyricsDisplayMode = "always", LyricsBackgroundMode = "acrylic" });
                Require(!material.IsRequested && !material.IsActive, "lyrics_material_requested_while_idle");
                idleMaterial = main!.SystemBackdrop;
                Accept(song);
            });
            await Parsed();
            await OnUi(queue!, () =>
            {
                var material = (PlayerAcrylic)Field(main!, "acrylic")!;
                bool attached = main!.SystemBackdrop is DesktopAcrylicBackdrop && !ReferenceEquals(main.SystemBackdrop, idleMaterial);
                Require(material.IsRequested && (material.IsActive ? attached : main.SystemBackdrop is null), "lyrics_material_did_not_replace_idle_material");
                Accept(new ReceiverSnapshot { Phase = ReceiverPhase.Ready });
            });
            await Settle();
            await OnUi(queue!, () => Pass(step, () =>
            {
                var material = (PlayerAcrylic)Field(main!, "acrylic")!;
                Require(!material.IsRequested && !material.IsActive && ReferenceEquals(main!.SystemBackdrop, idleMaterial),
                    "idle_material_not_restored_at_end_of_playback");
                Require(UnhandledErrors.Count == 0, "unhandled_ui_exception");
            }));
            status = "passed"; step = "complete";
        }
        catch (Exception error) { failure = error is CheckFailure ? error.Message : error.GetType().Name; detail = error.ToString(); }
        finally
        {
            try { if (queue != null) await OnUi(queue, () => { tray?.Close(); tray = null; if (main != null) { main.AllowClose = true; main.Close(); main = null; } Background(); }); }
            catch (Exception error) { cleanup.Add(error.GetType().Name); }
            try { if (model != null) { await model.DisposeAsync(); model = null; } }
            catch (Exception error) { cleanup.Add(error.GetType().Name); }
            try
            {
                if (preferencesCaptured)
                {
                    if (originalPreferences != null) { Directory.CreateDirectory(store.Data); File.WriteAllBytes(preferencesPath, originalPreferences); }
                    else if (File.Exists(preferencesPath)) File.Delete(preferencesPath);
                    restored = originalPreferences == null ? !File.Exists(preferencesPath) : File.ReadAllBytes(preferencesPath).AsSpan().SequenceEqual(originalPreferences);
                }
                L.Language = originalLanguage;
            }
            catch (Exception error) { cleanup.Add(error.GetType().Name); }
            if (!restored || cleanup.Count > 0 || UnhandledErrors.Count > 0) { status = "failed"; if (failure.Length == 0) failure = "cleanup_or_unhandled_error"; }
            void Finish()
            {
                File.WriteAllText(Path.Combine(directory, "player-refinement-check.json"), JsonSerializer.Serialize(new
                {
                    status, step, failure_code = failure, exception_detail = detail, cases, samples, captures, window_remained_hidden = hidden, foreground_not_taken = foregroundNotTaken,
                    foreground_unchanged_observed = GetForegroundWindow() == foreground, preferences_restored = restored, native_receiver_created = false, receiver_polling_started = false,
                    system_media_session_created = false, single_instance_notification_sent = false, initialized_flag_is_fixture = true, private_source_content_recorded = false,
                    visible_material_or_fullscreen_verified = false, unhandled_errors = UnhandledErrors, cleanup_errors = cleanup,
                    scope = "hidden_production_controller_player_tray_native_geometry_and_display_snapshot; no_receiver_audio_real_fullscreen_or_visible_material_claim"
                }, new JsonSerializerOptions { WriteIndented = true }));
                anchor?.Close();
            }
            if (queue == null || queue.HasThreadAccess) Finish(); else await OnUi(queue, Finish);
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
        var result = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(() => { try { action(); result.SetResult(); } catch (Exception error) { result.SetException(error); } })) result.TrySetCanceled();
        return result.Task;
    }
    private static Task OnUi(DispatcherQueue queue, Func<Task> action)
    {
        var result = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!queue.TryEnqueue(async () => { try { await action(); result.SetResult(); } catch (Exception error) { result.SetException(error); } })) result.TrySetCanceled();
        return result.Task;
    }
}
