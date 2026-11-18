using System.Numerics;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Diagnostics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Composition;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
using Microsoft.Graphics.DirectX;

namespace FusionPlay.Windows.Platform;

/// <summary>Native accessible row. Only glyph changes upload pixels; scrolling changes compositor properties.</summary>
public sealed class LyricsRowPresenter : Button
{
    private readonly Grid content = new();
    private readonly StackPanel measurement = new();
    private readonly TextBlock original = new() { TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.None, FontWeight = Microsoft.UI.Text.FontWeights.Bold },
        translation = new() { TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.None, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Opacity = .78 };
    private readonly Canvas overlay = new() { IsHitTestVisible = false };
    private LyricsRowItem? item;
    private CanvasRenderTarget? glyphs;
    private CompositionDrawingSurface? surface;
    private CompositionSurfaceBrush? surfaceBrush;
    private CompositionEffectBrush? blurBrush;
    private CompositionLinearGradientBrush? maskBrush;
    private CompositionMaskBrush? maskedBrush;
    private SpriteVisual? sprite;
    private readonly List<CompositionColorGradientStop> maskStops = [];
    private bool attached, queued, glyphsDirty = true, faulted, actuallyVisible, drawing;
    private int pixelWidth, pixelHeight;
    private double sourceWidth, sourceHeight, sourceDpi, edgeRadius, surfaceTop, viewportHeight;
    private double appliedEdgeRadius = double.NaN, appliedSurfaceTop = double.NaN, appliedViewportHeight = double.NaN;
    private double displayedOpacity = double.NaN;
    private Typography? typography;
    private long glyphRasterizations, surfaceCreations, edgeUpdates;
    private long resizeUploadDeadline;
    private bool urgentGlyphs = true;
    private sealed record Typography(string Family, ushort Weight, ushort TranslationWeight, double Size, double Scale, bool Enhanced, bool Contrast, bool Compact, string Language);
    internal LyricsRowItem? Item => item;
    internal bool UsesCompositionSurface => sprite?.IsVisible == true && measurement.Opacity == 0;
    internal long GlyphRasterizations => glyphRasterizations;
    internal long SurfaceCreations => surfaceCreations;
    internal long EdgeUpdates => edgeUpdates;
    internal bool GlyphUploadReady => urgentGlyphs || surface == null || resizeUploadDeadline == 0 || Stopwatch.GetTimestamp() >= resizeUploadDeadline;
    internal Rect GlyphBounds => new(content.Padding.Left - (item?.Owner.Bleed ?? 0), content.Padding.Top - (item?.Owner.Bleed ?? 0), sourceWidth, sourceHeight);

    public LyricsRowPresenter()
    {
        Padding = new Thickness(0); BorderThickness = new Thickness(0); Background = new SolidColorBrush(Colors.Transparent);
        HorizontalContentAlignment = HorizontalAlignment.Stretch; VerticalContentAlignment = VerticalAlignment.Stretch;
        measurement.Children.Add(original); measurement.Children.Add(translation); content.Children.Add(measurement); content.Children.Add(overlay); Content = content;
        foreach (var child in new FrameworkElement[] { content, measurement, original, translation, overlay }) AutomationProperties.SetAccessibilityView(child, AccessibilityView.Raw);
        DataContextChanged += (_, _) => SetItem(DataContext as LyricsRowItem);
        Loaded += (_, _) => { attached = true; faulted = false; item?.Owner.Register(this); UpdateEdge(); };
        Unloaded += (_, _) => { attached = false; item?.Owner.Unregister(this); StopAnimations(); ReleaseSurface(); };
        SizeChanged += (_, args) =>
        {
            if (args.NewSize.Width != args.PreviousSize.Width || args.NewSize.Height != args.PreviousSize.Height)
                InvalidateGlyphs(widthResize: args.NewSize.Width != args.PreviousSize.Width || resizeUploadDeadline != 0 && !urgentGlyphs);
            UpdateEdge();
        };
        Click += (_, _) => { if (item is { } current) current.Owner.RequestSeek(current); };
    }
    private void SetItem(LyricsRowItem? next)
    {
        if (ReferenceEquals(item, next)) return;
        if (attached) item?.Owner.Unregister(this);
        StopAnimations(); ReleaseSurface(); item = next; faulted = false; typography = null;
        if (next == null) { original.Text = translation.Text = ""; return; }
        Name = "LyricLine_" + next.Line.Id;
        original.Text = next.Line.Text.Length == 0 ? "•••" : next.Line.Text; original.CharacterSpacing = next.Line.Text.Length == 0 ? 180 : 0;
        translation.Text = next.Line.Translation ?? ""; translation.Visibility = translation.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (attached) next.Owner.Register(this); else ApplyState(style: true);
    }
    internal void ApplyState(bool style)
    {
        if (item is not { } current) return;
        var owner = current.Owner;
        bool active = current.Index == owner.ActiveIndex;
        IsEnabled = current.Line.TimeMs.HasValue && owner.CanSeek; IsTabStop = current.Line.TimeMs.HasValue;
        AutomationProperties.SetName(this, (current.Line.Text.Length == 0 ? L.Text("歌词间隔", "Instrumental break") : current.Line.Text) + (current.Line.Translation is { Length: > 0 } text ? "\n" + text : ""));
        AutomationProperties.SetHelpText(this, IsEnabled ? L.Text("跳转到此歌词", "Seek to this lyric") : "");
        AutomationProperties.SetItemStatus(this, active ? L.Text("当前歌词", "Current lyric") : "");
        SetOpacity(LyricsViewport.LineOpacity(owner.Timed, current.Index, owner.ActiveIndex, owner.HighContrast), owner.MotionEnabled && owner.PresentationLoaded);
        if (style)
        {
            var next = new Typography(owner.LyricFont.Source, owner.BodyWeight.Weight, owner.TranslationWeight.Weight, owner.BodySize, owner.TextScale, owner.EnhancedText, owner.HighContrast, owner.Compact, L.Language);
            if (next != typography)
            {
                bool widthOnly = typography != null && next.Size != typography.Size && next == (typography with { Size = next.Size });
                typography = next;
                original.FontSize = next.Size; translation.FontSize = owner.Compact ? Math.Max(12, next.Size * .56) : next.Size * .6;
                original.FontFamily = translation.FontFamily = owner.LyricFont; original.FontWeight = owner.BodyWeight; translation.FontWeight = owner.TranslationWeight;
                original.Language = translation.Language = L.Language == "en" ? "en-US" : "zh-CN";
                content.Padding = new Thickness(owner.Bleed + 3, owner.Compact ? 3 : 5, owner.Bleed + 3, owner.Compact ? 3 : 5);
                measurement.Spacing = owner.Compact ? 5 : 7; Margin = new Thickness(0, 0, 0, owner.Compact ? 12 : 20);
                Brush foreground = owner.HighContrast ? (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"] : new SolidColorBrush(Colors.White);
                original.Foreground = translation.Foreground = foreground;
                InvalidateGlyphs(widthResize: widthOnly);
            }
            else if (owner.HighContrast)
            {
                original.Foreground = translation.Foreground = (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
            }
        }
        UpdateEdge();
    }
    private void SetOpacity(double value, bool animate)
    {
        if (displayedOpacity == value && animate) return;
        bool first = double.IsNaN(displayedOpacity); displayedOpacity = value;
        try
        {
            var visual = ElementCompositionPreview.GetElementVisual(this); visual.StopAnimation("Opacity");
            if (first || !animate) { visual.Opacity = (float)value; return; }
            using var easing = visual.Compositor.CreateCubicBezierEasingFunction(new Vector2(.42f, 0), new Vector2(.58f, 1));
            using var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
            animation.InsertExpressionKeyFrame(0, "this.StartingValue"); animation.InsertKeyFrame(1, (float)value, easing);
            animation.Duration = TimeSpan.FromMilliseconds(300); animation.StopBehavior = AnimationStopBehavior.LeaveCurrentValue; visual.StartAnimation("Opacity", animation);
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { Opacity = value; }
    }
    internal void StopAnimations()
    {
        displayedOpacity = double.NaN;
        try { ElementCompositionPreview.GetElementVisual(this).StopAnimation("Opacity"); }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { }
    }
    internal void InvalidateGlyphs() => InvalidateGlyphs(widthResize: false);
    private void InvalidateGlyphs(bool widthResize)
    {
        glyphsDirty = true; faulted = false;
        if (widthResize && surface != null && !urgentGlyphs)
        {
            // Set once per pending upload: further width samples replace the
            // requested geometry without postponing this bounded deadline.
            if (resizeUploadDeadline == 0) resizeUploadDeadline = Stopwatch.GetTimestamp() + Stopwatch.Frequency * 40 / 1000;
        }
        else { urgentGlyphs = true; resizeUploadDeadline = 0; }
        QueueDraw();
    }
    internal void UpdateEdge()
    {
        if (!attached || item is not { } current || !current.Owner.PresentationLoaded) { actuallyVisible = false; return; }
        try
        {
            var owner = current.Owner;
            double y = TransformToVisual(owner).TransformPoint(new Point()).Y;
            actuallyVisible = LyricsViewport.IntersectsViewport(y, ActualHeight, owner.ViewportHeight, owner.Bleed);
            if (!actuallyVisible) { if (sprite != null) sprite.IsVisible = false; return; }
            double radius = LyricsViewport.EdgeBlur(y + ActualHeight * .5, owner.ViewportHeight, owner.Compact, owner.EffectsEnabled);
            double top = measurement.TransformToVisual(owner).TransformPoint(new Point()).Y - owner.Bleed;
            bool changed = double.IsNaN(appliedEdgeRadius) || Math.Abs(radius - appliedEdgeRadius) > .05 || Math.Abs(top - appliedSurfaceTop) > .5 || appliedViewportHeight != owner.ViewportHeight;
            edgeRadius = radius; surfaceTop = top; viewportHeight = owner.ViewportHeight;
            if (owner.HighContrast || faulted) { NativeFallback(); return; }
            if (surface != null && changed) UpdateEffectProperties();
            if (glyphsDirty || surface == null) QueueDraw();
            if (surface != null) ShowSurface();
        }
        catch (Exception error) when (error is COMException or ArgumentException or ObjectDisposedException) { faulted = true; NativeFallback(); }
    }
    private void UpdateEffectProperties()
    {
        if (blurBrush == null || maskBrush == null) return;
        blurBrush.Properties.InsertScalar("edge.BlurAmount", (float)edgeRadius);
        maskBrush.StartPoint = new Vector2(0, (float)-surfaceTop); maskBrush.EndPoint = maskBrush.StartPoint + new Vector2(0, (float)Math.Max(1, viewportHeight));
        appliedEdgeRadius = edgeRadius; appliedSurfaceTop = surfaceTop; appliedViewportHeight = viewportHeight;
        edgeUpdates++;
    }
    private void QueueDraw()
    {
        if (!attached || queued || drawing || faulted || !actuallyVisible || item?.Owner.PresentationLoaded != true || item.Owner.HighContrast) return;
        queued = true; item.Owner.QueueGlyphDraw(this);
    }
    internal void CancelQueuedDraw() => queued = false;
    internal void RenderPendingGlyphs()
    {
        queued = false;
        if (!attached || item?.Owner.PresentationLoaded != true) return;
        drawing = true;
        try
        {
            UpdateEdge(); if (!actuallyVisible || faulted || item.Owner.HighContrast || !glyphsDirty && surface != null) return;
            DrawGlyphs();
        }
        finally { drawing = false; }
    }
    private void NativeFallback() { measurement.Opacity = 1; if (sprite != null) sprite.IsVisible = false; }
    private void ShowSurface()
    {
        if (sprite == null || !actuallyVisible) return;
        measurement.Opacity = 0; sprite.IsVisible = true;
    }
    private void DrawGlyphs()
    {
        if (item is not { } current) return;
        var owner = current.Owner;
        double bleed = owner.Bleed, width = measurement.ActualWidth, height = measurement.ActualHeight, dpi = 96 * (XamlRoot?.RasterizationScale ?? 1), scale = dpi / 96;
        int requiredWidth = (int)Math.Ceiling((width + bleed * 2) * scale), requiredHeight = (int)Math.Ceiling((height + bleed * 2) * scale);
        if (width <= 0 || height <= 0 || requiredWidth > 8192 || requiredHeight > 8192)
        {
            // A previous, smaller plane must never hide the current native text.
            // Oversized rows retry only after their size/style is invalidated.
            faulted = requiredWidth > 8192 || requiredHeight > 8192; ReleaseSurface(); return;
        }
        try
        {
            var resources = owner.GetGraphicsResources(); if (resources == null) { faulted = true; NativeFallback(); return; }
            // Reuse capacity across small resize steps rather than allocating for every DIP.
            if (surface == null || sourceDpi != dpi || requiredWidth > pixelWidth || requiredHeight > pixelHeight || (long)requiredWidth * requiredHeight * 4 < (long)pixelWidth * pixelHeight)
                CreateSurface(resources, (requiredWidth + 63) / 64 * 64, (requiredHeight + 63) / 64 * 64, dpi);
            using (var draw = glyphs!.CreateDrawingSession())
            {
                draw.Clear(Colors.Transparent);
                using var enhanced = owner.EnhancedText ? NativeTypography.Enhance(draw) : null;
                DrawText(draw, resources.Device, original, (float)bleed, (float)bleed, 255, owner.TextScale);
                if (translation.Visibility == Visibility.Visible) DrawText(draw, resources.Device, translation, (float)bleed, (float)(bleed + original.ActualHeight + measurement.Spacing), 199, owner.TextScale);
            }
            using var gamma = new GammaTransferEffect { Source = glyphs, RedDisable = true, GreenDisable = true, BlueDisable = true, AlphaExponent = owner.EnhancedText ? .94f : 1, ClampOutput = true };
            using (var draw = CanvasComposition.CreateDrawingSession(surface!, new Rect(0, 0, pixelWidth, pixelHeight), (float)dpi)) { draw.Clear(Colors.Transparent); draw.DrawImage(gamma); }
            sprite!.Offset = new Vector3((float)-bleed, (float)-bleed, 0);
            glyphRasterizations++; glyphsDirty = false; urgentGlyphs = false; resizeUploadDeadline = 0; UpdateEffectProperties(); ShowSurface();
        }
        catch (Exception error) when (error is COMException or ArgumentException or NotSupportedException or ObjectDisposedException)
        {
            faulted = true; ReleaseSurface(); NativeFallback();
        }
    }
    private void CreateSurface(LyricsGraphicsResources resources, int width, int height, double dpi)
    {
        ReleaseSurface();
        pixelWidth = width; pixelHeight = height; sourceDpi = dpi; sourceWidth = width * 96 / dpi; sourceHeight = height * 96 / dpi;
        var compositor = resources.Compositor;
        surface = resources.GraphicsDevice.CreateDrawingSurface(new Size(width, height), DirectXPixelFormat.B8G8R8A8UIntNormalized, DirectXAlphaMode.Premultiplied);
        glyphs = new CanvasRenderTarget(resources.Device, (float)sourceWidth, (float)sourceHeight, (float)dpi);
        surfaceBrush = compositor.CreateSurfaceBrush(surface); surfaceBrush.Stretch = CompositionStretch.Fill;
        blurBrush = resources.BlurFactory.CreateBrush(); blurBrush.SetSourceParameter("glyphs", surfaceBrush);
        maskBrush = compositor.CreateLinearGradientBrush(); maskBrush.MappingMode = CompositionMappingMode.Absolute;
        foreach (var stop in new[] { compositor.CreateColorGradientStop(0, Colors.Transparent), compositor.CreateColorGradientStop(.09f, Colors.White), compositor.CreateColorGradientStop(.91f, Colors.White), compositor.CreateColorGradientStop(1, Colors.Transparent) })
        { maskStops.Add(stop); maskBrush.ColorStops.Add(stop); }
        maskedBrush = compositor.CreateMaskBrush(); maskedBrush.Source = blurBrush; maskedBrush.Mask = maskBrush;
        sprite = compositor.CreateSpriteVisual(); sprite.Size = new Vector2((float)sourceWidth, (float)sourceHeight); sprite.Offset = new Vector3((float)-item!.Owner.Bleed, (float)-item.Owner.Bleed, 0); sprite.Brush = maskedBrush;
        ElementCompositionPreview.SetElementChildVisual(overlay, sprite); surfaceCreations++;
    }
    private static void DrawText(CanvasDrawingSession draw, CanvasDevice device, TextBlock text, float x, float y, byte alpha, double scale)
    {
        using var format = PlayerText.CreateFormat(text.FontFamily.Source, (float)(text.FontSize * scale), text.FontWeight, text.FontStyle, TextWrapping.Wrap, TextTrimming.None);
        using var layout = new CanvasTextLayout(device, text.Text, format, (float)Math.Max(1, text.ActualWidth), (float)Math.Max(1, text.ActualHeight));
        if (text.CharacterSpacing != 0) layout.SetCharacterSpacing(0, text.Text.Length, (float)(text.CharacterSpacing * text.FontSize / 1000), 0, 0);
        draw.DrawTextLayout(layout, x, y, global::Windows.UI.Color.FromArgb(alpha, 255, 255, 255));
    }
    // Explicit diagnostic capture of the real cache and current effect state. It never
    // replaces production visuals or triggers source glyph rasterization.
    internal CanvasRenderTarget? CaptureForCheck()
    {
        if (!UsesCompositionSurface || glyphs == null || item is not { } current) return null;
        var device = glyphs.Device;
        var result = new CanvasRenderTarget(device, (float)sourceWidth, (float)sourceHeight, (float)sourceDpi);
        try
        {
            using var gamma = new GammaTransferEffect { Source = glyphs, RedDisable = true, GreenDisable = true, BlueDisable = true, AlphaExponent = current.Owner.EnhancedText ? .94f : 1, ClampOutput = true };
            using var blur = new GaussianBlurEffect { Source = gamma, BlurAmount = (float)appliedEdgeRadius, BorderMode = EffectBorderMode.Soft };
            using var mask = new CanvasCommandList(device);
            using (var draw = mask.CreateDrawingSession())
            {
                using var brush = new CanvasLinearGradientBrush(device, new CanvasGradientStop[] { new() { Position = 0, Color = Colors.Transparent }, new() { Position = .09f, Color = Colors.White }, new() { Position = .91f, Color = Colors.White }, new() { Position = 1, Color = Colors.Transparent } });
                brush.StartPoint = new Vector2(0, (float)-appliedSurfaceTop); brush.EndPoint = brush.StartPoint + new Vector2(0, (float)Math.Max(1, appliedViewportHeight)); draw.FillRectangle(0, 0, (float)sourceWidth, (float)sourceHeight, brush);
            }
            using var masked = new AlphaMaskEffect { Source = blur, AlphaMask = mask };
            using var faded = new OpacityEffect { Source = masked, Opacity = (float)(double.IsNaN(displayedOpacity) ? 1 : displayedOpacity) };
            using (var draw = result.CreateDrawingSession()) { draw.Clear(Colors.Transparent); draw.DrawImage(faded); }
            return result;
        }
        catch { result.Dispose(); throw; }
    }
    internal IDisposable BeginCaptureForCheck()
    {
        using var capture = CaptureForCheck();
        if (capture == null) return new CaptureLease(() => { });
        // Read back synchronously. RTB receives an ordinary XAML bitmap, never
        // a temporary Win2D SurfaceImageSource sharing the live graphics device.
        var size = capture.SizeInPixels; byte[] pixels = capture.GetPixelBytes();
        long expected = checked((long)size.Width * size.Height * 4);
        if (pixels.LongLength != expected) throw new InvalidOperationException("Lyric capture pixel buffer size mismatch.");
        var copy = new WriteableBitmap(checked((int)size.Width), checked((int)size.Height));
        if (copy.PixelBuffer.Capacity < expected) throw new InvalidOperationException("Lyric capture bitmap buffer is too small.");
        using (var stream = copy.PixelBuffer.AsStream()) stream.Write(pixels, 0, pixels.Length);
        copy.Invalidate();
        var image = new Image { Source = copy, Width = sourceWidth, Height = sourceHeight, Stretch = Stretch.Fill, IsHitTestVisible = false };
        AutomationProperties.SetAccessibilityView(image, AccessibilityView.Raw);
        double bleed = item?.Owner.Bleed ?? 0; Canvas.SetLeft(image, -bleed); Canvas.SetTop(image, -bleed); overlay.Children.Add(image);
        return new CaptureLease(() => { overlay.Children.Remove(image); image.Source = null; GC.KeepAlive(copy); });
    }
    private sealed class CaptureLease(Action close) : IDisposable
    {
        private Action? cleanup = close;
        public void Dispose() => Interlocked.Exchange(ref cleanup, null)?.Invoke();
    }
    internal void ReleaseSurface()
    {
        var oldSprite = sprite; var oldMasked = maskedBrush; var oldMask = maskBrush; var oldBlur = blurBrush; var oldBrush = surfaceBrush;
        var oldSurface = surface; var oldGlyphs = glyphs; var oldStops = maskStops.ToArray();
        // Native close callbacks can reenter layout. Publish the fallback state
        // before releasing any shared brush graph or drawing resource.
        sprite = null; maskedBrush = null; maskBrush = null; blurBrush = null; surfaceBrush = null; surface = null; glyphs = null; maskStops.Clear();
        glyphsDirty = true; urgentGlyphs = true; resizeUploadDeadline = 0; appliedEdgeRadius = appliedSurfaceTop = appliedViewportHeight = double.NaN; NativeFallback();
        try { ElementCompositionPreview.SetElementChildVisual(overlay, null); if (oldSprite != null) oldSprite.Brush = null; }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { }
        LyricsGraphicsResources.Close(oldSprite); LyricsGraphicsResources.Close(oldMasked); LyricsGraphicsResources.Close(oldMask); LyricsGraphicsResources.Close(oldBlur); LyricsGraphicsResources.Close(oldBrush);
        foreach (var stop in oldStops) LyricsGraphicsResources.Close(stop);
        LyricsGraphicsResources.Close(oldSurface); LyricsGraphicsResources.Close(oldGlyphs);
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new LyricPeer(this);
    private sealed class LyricPeer(LyricsRowPresenter owner) : ButtonAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => owner.item?.Line.TimeMs.HasValue == true ? AutomationControlType.Button : AutomationControlType.Text;
        protected override object? GetPatternCore(PatternInterface patternInterface)
            => patternInterface == PatternInterface.Invoke && owner.item?.Line.TimeMs == null ? null : base.GetPatternCore(patternInterface);
    }
}
