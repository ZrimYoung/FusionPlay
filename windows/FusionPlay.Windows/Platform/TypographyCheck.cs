using System.Runtime.InteropServices;
using System.Text.Json;
using FusionPlay.Core;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace FusionPlay.Windows.Platform;

/// <summary>Opt-in, hidden native/font/UI regression check; never creates a
/// receiver, single-instance message, media session or visible window.</summary>
internal static class TypographyCheck
{
    internal static List<string> UnhandledErrors { get; } = [];
    public static async Task Run(string directory)
    {
        Directory.CreateDirectory(directory);
        nint foreground = GetForegroundWindow(), hwnd = 0;
        Window? window = null; FontSettingsPanel? panel = null;
        ReceiverController? controller = null; MainWindow? player = null; SettingsWindow? settings = null;
        string step = "installed_font_families", status = "failed", exception = "", message = "", cleanupError = "";
        var samples = new List<object>();
        int familyCount = 0;
        bool visibilityPreserved = true, focusPreservedAtCreation = true;
        string previewCapture = "not_attempted";
        bool fullWindowsCreated = false;
        void Require(bool ok, string reason) { if (!ok) throw new InvalidOperationException(reason); }
        try
        {
            var fonts = await Task.Run(NativeTypography.GetFamilies);
            familyCount = fonts.Length;
            File.WriteAllText(Path.Combine(directory, "installed-families.json"), JsonSerializer.Serialize(fonts));
            Require(familyCount > 0 && fonts.Select(f => f.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() == familyCount, "font_family_names_not_unique");
            Require(fonts.All(f => f.Weights.Length > 0 && f.Weights.SequenceEqual(f.Weights.Distinct().Order()) && f.Weights.All(w => w is >= 1 and <= 999)), "invalid_family_weights");
            Require(NativeTypography.FindFamily("FusionPlay-Missing-Font-7CF7") == null, "absent_family_was_found");
            var family = NativeTypography.SystemFamily;
            var device = CanvasDevice.GetSharedDevice();
            step = "native_directwrite_parameters_and_dpi";
            foreach (float dpi in new[] { 96f, 120f, 144f, 192f })
            foreach (int weight in new[] { 400, 600 })
            {
                using var target = new CanvasRenderTarget(device, 640, 192, dpi);
                using var format = PlayerText.CreateFormat(family.Name, 18, new() { Weight = (ushort)weight }, trimming: TextTrimming.None);
                using var layout = new CanvasTextLayout(device, "FusionPlay 音乐 · Taylor Swift 0123456789", format, 640, 48);
                NativeTypography.RenderingParameters? parameters = null;
                using var glyphs = new CanvasRenderTarget(device, 640, 48, dpi);
                PlayerTextDrawing.DrawGlyphs(glyphs, layout, Colors.White);
                using (var drawing = target.CreateDrawingSession())
                {
                    drawing.Clear(Colors.Transparent); drawing.TextAntialiasing = CanvasTextAntialiasing.Grayscale;
                    drawing.DrawTextLayout(layout, 0, 0, Colors.White);
                    using (var enhanced = NativeTypography.Enhance(drawing)) { parameters = enhanced.Inspect(); drawing.DrawTextLayout(layout, 0, 48, Colors.White); }
                    drawing.DrawTextLayout(layout, 0, 96, Colors.White);
                    PlayerTextDrawing.Composite(drawing, glyphs, 0, 144);
                }
                byte[] pixels = target.GetPixelBytes();
                int stride = (int)target.SizeInPixels.Width * 4, rows = (int)(48 * dpi / 96), changed = 0, restoreMismatch = 0, colorFringes = 0, visible = 0, softChanges = 0;
                for (int row = 0; row < rows; row++)
                for (int x = 0; x < stride; x += 4)
                {
                    int original = row * stride + x, enhanced = (row + rows) * stride + x, restored = (row + rows * 2) * stride + x;
                    int soft = (row + rows * 3) * stride + x;
                    if (pixels[soft + 3] != 0) visible++;
                    if (pixels[soft] != pixels[soft + 1] || pixels[soft + 1] != pixels[soft + 2]) colorFringes++;
                    if (!pixels.AsSpan(original, 4).SequenceEqual(pixels.AsSpan(soft, 4))) softChanges++;
                    if (!pixels.AsSpan(original, 4).SequenceEqual(pixels.AsSpan(enhanced, 4))) changed++;
                    if (!pixels.AsSpan(original, 4).SequenceEqual(pixels.AsSpan(restored, 4))) restoreMismatch++;
                }
                await target.SaveAsync(Path.Combine(directory, $"directwrite-{dpi}-{weight}.png"), CanvasBitmapFileFormat.Png);
                samples.Add(new { dpi, weight, visible_pixels = visible, parameter_changed_pixels = changed, soft_changed_pixels = softChanges, rgb_fringe_pixels = colorFringes, restored_pixel_mismatches = restoreMismatch, parameters });
                Require(visible > 200 && softChanges > 0, "custom_rendering_did_not_change_glyph_pixels");
                Require(changed > 0 || parameters?.ExternalOverride == true, "native_parameters_were_ignored_without_external_override");
                Require(colorFringes == 0, "transparent_text_has_rgb_fringes");
                Require(restoreMismatch == 0, "native_render_state_not_restored");
            }
            step = "hidden_font_settings_and_native_text_fallback";
            var store = new UiPreferencesStore(Path.Combine(directory, "temporary-preferences-" + Guid.NewGuid().ToString("N")));
            panel = new FontSettingsPanel(store, change => { store.Update(change(store.Value)); panel?.Refresh(); return true; });
            var icon = new FontIcon { Glyph = "\uE713" }; string iconFamily = UiTypography.SymbolFamily.Source;
            var text = new PlayerText { Text = "FusionPlay 音乐 🎵", Width = 320, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = new SolidColorBrush(Colors.White), MaxLines = 2, TextWrapping = TextWrapping.Wrap };
            var root = new StackPanel { Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"] }; root.Children.Add(panel); root.Children.Add(icon); root.Children.Add(text);
            nint beforeCreation = GetForegroundWindow();
            window = new Window { Content = root, Title = "FusionPlay Background Typography Check" };
            window.AppWindow.IsShownInSwitchers = false;
            WindowSizing.Apply(window, 640, 520);
            hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
            focusPreservedAtCreation = GetForegroundWindow() == beforeCreation;
            visibilityPreserved &= !IsWindowVisible(hwnd);
            await panel.FontLoading;
            visibilityPreserved &= !IsWindowVisible(hwnd);
            Require(visibilityPreserved && focusPreservedAtCreation, "font_check_window_interrupted_desktop");
            Require(panel.FamilySelector.Items.Count == familyCount + 1, "font_selector_contains_face_duplicates");
            panel.FamilySelector.SelectedValue = family.Name;
            int chosenWeight = family.Weights.Max(); panel.WeightSelector.SelectedValue = chosenWeight;
            Require(store.Value.UiFontFamily == family.Name && store.Value.UiFontWeight == chosenWeight, "separate_family_weight_selection_not_saved");
            Require(panel.WeightSelector.Items.Count == family.Weights.Length, "weight_choices_do_not_match_installed_faces");
            panel.RenderingSelector.SelectedValue = "system";
            Require(store.Value.PlayerTextRendering == "system", "renderer_selection_not_saved");
            UiTypography.Apply(root, store.Value, force: true);
            Require(!text.Enhanced && text.FontFamily.Source == family.Name, "player_did_not_follow_typography_preferences");
            Require(icon.FontFamily.Source == iconFamily, "interface_font_replaced_icon_font");
            store.Update(store.Value with { PlayerTextRendering = "enhanced", UiFontWeight = 400 });
            panel.Refresh();
            UiTypography.Apply(root, store.Value, force: true);
            root.Measure(new Size(640, 1800)); root.Arrange(new Rect(0, 0, 640, 1800));
            Require(text.RenderForCheck(), "player_native_surface_unavailable");
            try
            {
                var bitmap = new RenderTargetBitmap();
                await bitmap.RenderAsync(root);
                var buffer = await bitmap.GetPixelsAsync();
                byte[] bytes = new byte[buffer.Length];
                using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(bytes);
                var file = await (await StorageFolder.GetFolderFromPathAsync(directory)).CreateFileAsync("font-settings-preview.png", CreationCollisionOption.ReplaceExisting);
                using var stream = await file.OpenAsync(FileAccessMode.ReadWrite);
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes);
                await encoder.FlushAsync(); previewCapture = "font-settings-preview.png";
            }
            catch (Exception error) when (error is COMException or InvalidOperationException) { previewCapture = error.GetType().Name; }
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(text);
            Require(peer?.GetName() == text.Text && peer.GetAutomationControlType() == AutomationControlType.Text, "custom_text_accessibility_lost");
            text.Enhanced = false; Require(!text.RenderForCheck(), "native_text_mode_did_not_restore_fallback");
            store.Update(store.Value with { UiFontFamily = "FusionPlay-Missing-Font-7CF7" }); panel.Refresh(); UiTypography.Apply(root, store.Value, force: true);
            Require(text.FontFamily.Source == family.Name && store.Value.UiFontFamily == "FusionPlay-Missing-Font-7CF7", "missing_font_fallback_destroyed_choice");
            step = "hidden_full_player_and_settings_initialization";
            controller = new ReceiverController(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
            player = new MainWindow(controller, () => { }) { AllowClose = true };
            player.AppWindow.IsShownInSwitchers = false;
            settings = new SettingsWindow(controller); settings.AppWindow.IsShownInSwitchers = false;
            visibilityPreserved &= !IsWindowVisible(WinRT.Interop.WindowNative.GetWindowHandle(player)) && !IsWindowVisible(WinRT.Interop.WindowNative.GetWindowHandle(settings));
            Require(!controller.Initialized && visibilityPreserved, "full_window_check_created_receiver_or_showed_window");
            fullWindowsCreated = true;
            settings.Close(); settings = null; player.Close(); player = null;
            await controller.DisposeAsync(); controller = null;
            visibilityPreserved &= !IsWindowVisible(hwnd);
            Require(visibilityPreserved, "font_check_did_not_stay_hidden");
            Require(UnhandledErrors.Count == 0, "unexpected_xaml_error");
            status = "passed";
        }
        catch (Exception error) { exception = error.GetType().Name; message = error.Message; }
        finally
        {
            try { settings?.Close(); if (player != null) { player.AllowClose = true; player.Close(); } if (controller != null) await controller.DisposeAsync(); panel?.Dispose(); window?.Close(); }
            catch (Exception error) { cleanupError = error.GetType().Name + ": " + error.Message; status = "failed"; }
            File.WriteAllText(Path.Combine(directory, "typography-check.json"), JsonSerializer.Serialize(new
            {
                status, step, exception_type = exception, message, cleanup_error = cleanupError, installed_family_count = familyCount, samples,
                receiver_created = false, foreground_unchanged_during_creation = focusPreservedAtCreation,
                foreground_unchanged_over_entire_check = GetForegroundWindow() == foreground,
                window_remained_hidden = visibilityPreserved, unhandled_errors = UnhandledErrors, preview_capture = previewCapture, full_windows_created = fullWindowsCreated
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
    }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint hwnd);
}
