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
using Microsoft.UI.Dispatching;
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
    private GlyphPlane? plane, sparePlane, outgoingPlane;
    private ContainerVisual? planesVisual;
    private DispatcherQueueTimer? wrapTimer;
    private long wrapDeadline, wrapTransitionsStarted;
    private const int WrapDurationMs = 180;
    private CanvasRenderTarget? glyphs => plane?.Glyphs;
    private CompositionDrawingSurface? surface => plane?.Surface;
    private SpriteVisual? sprite => plane?.Sprite;
    private double sourceWidth => plane?.Width ?? 0;
    private double sourceHeight => plane?.Height ?? 0;
    private double sourceDpi => plane?.Dpi ?? 0;
    private bool attached, queued, glyphsDirty = true, faulted, actuallyVisible, drawing;
    private double edgeRadius, surfaceTop, viewportHeight;
    private double appliedEdgeRadius = double.NaN, appliedSurfaceTop = double.NaN, appliedViewportHeight = double.NaN;
    private double displayedOpacity = double.NaN;
    private Typography? typography;
    private long glyphRasterizations, surfaceCreations, edgeUpdates;
    private long resizeUploadDeadline;
    private bool urgentGlyphs = true;
    private sealed class GlyphPlane
    {
        internal CanvasRenderTarget? Glyphs;
        internal CompositionDrawingSurface? Surface;
        internal CompositionSurfaceBrush? SurfaceBrush;
        internal CompositionEffectBrush? BlurBrush;
        internal CompositionLinearGradientBrush? MaskBrush;
        internal CompositionMaskBrush? MaskedBrush;
        internal SpriteVisual? Sprite;
        internal readonly List<CompositionColorGradientStop> MaskStops = [];
        internal int PixelWidth, PixelHeight;
        internal double Width, Height, Dpi, ContentHeight;
        internal ulong OriginalBreaks, TranslationBreaks;
    }
    private sealed record Typography(string Family, ushort Weight, ushort TranslationWeight, double Size, double Scale, bool Enhanced, bool Contrast, bool Compact, string Language);
    internal LyricsRowItem? Item => item;
    internal bool UsesCompositionSurface => sprite?.IsVisible == true && measurement.Opacity == 0;
    internal long GlyphRasterizations => glyphRasterizations;
    internal long SurfaceCreations => surfaceCreations;
    internal long EdgeUpdates => edgeUpdates;
    internal long WrapTransitionsStarted => wrapTransitionsStarted;
    internal bool WrapTransitionActive => outgoingPlane != null;
    internal int WrapTransitionDurationMs => WrapDurationMs;
    internal int CachedPlaneCount => (plane == null ? 0 : 1) + (sparePlane == null ? 0 : 1) + (outgoingPlane == null ? 0 : 1);
    internal bool GlyphUploadReady => urgentGlyphs || (outgoingPlane == null || item?.Owner.MotionEnabled != true)
        && (surface == null || resizeUploadDeadline == 0 || Stopwatch.GetTimestamp() >= resizeUploadDeadline);
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
        bool interval = next.Line.Text.Length == 0;
        // One compact glyph cannot split into a second row in a narrow pane.
        original.Text = interval ? "…" : next.Line.Text; original.CharacterSpacing = 0;
        original.TextWrapping = interval ? TextWrapping.NoWrap : TextWrapping.Wrap; original.MaxLines = interval ? 1 : 0;
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
                bool interval = current.Line.Text.Length == 0;
                original.FontSize = interval ? Math.Clamp(next.Size * .65, 14, 20) : next.Size; translation.FontSize = owner.Compact ? Math.Max(12, next.Size * .56) : next.Size * .6;
                original.FontFamily = translation.FontFamily = owner.LyricFont; original.FontWeight = interval ? Microsoft.UI.Text.FontWeights.Normal : owner.BodyWeight; translation.FontWeight = owner.TranslationWeight;
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
        FinishWrap(queueDraw: false);
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
        if (!attached || item is not { } current || !current.Owner.PresentationLoaded) { actuallyVisible = false; FinishWrap(queueDraw: false); return; }
        try
        {
            var owner = current.Owner;
            double y = TransformToVisual(owner).TransformPoint(new Point()).Y;
            actuallyVisible = LyricsViewport.IntersectsViewport(y, ActualHeight, owner.ViewportHeight, owner.Bleed);
            if (!actuallyVisible) { FinishWrap(queueDraw: false); if (sprite != null) sprite.IsVisible = false; return; }
            if (!owner.MotionEnabled) FinishWrap(queueDraw: false);
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
        UpdatePlaneEffects(plane); UpdatePlaneEffects(outgoingPlane);
        appliedEdgeRadius = edgeRadius; appliedSurfaceTop = surfaceTop; appliedViewportHeight = viewportHeight;
        edgeUpdates++;
    }
    private void UpdatePlaneEffects(GlyphPlane? target)
    {
        if (target?.BlurBrush == null || target.MaskBrush == null) return;
        target.BlurBrush.Properties.InsertScalar("edge.BlurAmount", (float)edgeRadius);
        target.MaskBrush.StartPoint = new Vector2(0, (float)-surfaceTop); target.MaskBrush.EndPoint = target.MaskBrush.StartPoint + new Vector2(0, (float)Math.Max(1, viewportHeight));
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
    private void NativeFallback()
    {
        FinishWrap(queueDraw: false); measurement.Opacity = 1;
        try { if (sprite != null) sprite.IsVisible = false; }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { }
    }
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
        GlyphPlane? unpublished = null, replacedPlane = null;
        try
        {
            var resources = owner.GetGraphicsResources(); if (resources == null) { faulted = true; NativeFallback(); return; }
            using var first = CreateTextLayout(resources.Device, original, owner.TextScale);
            using var second = translation.Visibility == Visibility.Visible ? CreateTextLayout(resources.Device, translation, owner.TextScale) : null;
            ulong firstBreaks = LineBreaks(first), secondBreaks = second == null ? 0 : LineBreaks(second);
            // A stable glyph plane remains on screen until the replacement upload
            // is complete. Only real line-break/height changes crossfade; small
            // width samples retain the existing 40 ms coalescing deadline.
            bool animateWrap = !urgentGlyphs && plane != null && plane.Dpi == dpi && owner.MotionEnabled
                && (plane.OriginalBreaks != firstBreaks || plane.TranslationBreaks != secondBreaks || Math.Abs(plane.ContentHeight - height) > .5);
            FinishWrap(queueDraw: false);
            if (faulted) return;
            var previous = plane;
            var target = animateWrap ? sparePlane : plane;
            if (animateWrap) sparePlane = null;
            bool Fits(GlyphPlane? candidate) => candidate != null && candidate.Dpi == dpi
                && requiredWidth <= candidate.PixelWidth && requiredHeight <= candidate.PixelHeight
                && (long)requiredWidth * requiredHeight * 4 >= (long)candidate.PixelWidth * candidate.PixelHeight;
            if (!animateWrap && !Fits(target) && Fits(sparePlane)) { target = sparePlane; sparePlane = null; }
            // Capacity is rounded, reused, and bounded to two planes per visible
            // row. Never clear or upload into a plane that is still fading out.
            if (!Fits(target))
            {
                if (!ReferenceEquals(target, previous)) ClosePlane(target);
                var unused = sparePlane; sparePlane = null; ClosePlane(unused);
                target = unpublished = CreatePlane(resources, (requiredWidth + 63) / 64 * 64, (requiredHeight + 63) / 64 * 64, dpi);
            }
            else if (!ReferenceEquals(target, previous)) unpublished = target;
            if (target == null) throw new NotSupportedException("The lyric glyph plane could not be created.");
            using (var draw = target.Glyphs!.CreateDrawingSession())
            {
                draw.Clear(Colors.Transparent);
                using var enhanced = owner.EnhancedText ? NativeTypography.Enhance(draw) : null;
                draw.DrawTextLayout(first, (float)bleed, (float)bleed, Colors.White);
                if (second != null) draw.DrawTextLayout(second, (float)bleed, (float)(bleed + original.ActualHeight + measurement.Spacing), global::Windows.UI.Color.FromArgb(199, 255, 255, 255));
            }
            using var gamma = new GammaTransferEffect { Source = target.Glyphs, RedDisable = true, GreenDisable = true, BlueDisable = true, AlphaExponent = owner.EnhancedText ? .94f : 1, ClampOutput = true };
            using (var draw = CanvasComposition.CreateDrawingSession(target.Surface!, new Rect(0, 0, target.PixelWidth, target.PixelHeight), (float)dpi)) { draw.Clear(Colors.Transparent); draw.DrawImage(gamma); }
            target.Sprite!.Offset = new Vector3((float)-bleed, (float)-bleed, 0);
            target.OriginalBreaks = firstBreaks; target.TranslationBreaks = secondBreaks; target.ContentHeight = height;
            plane = target; unpublished = null;
            if (!ReferenceEquals(previous, target)) replacedPlane = previous;
            if (animateWrap && previous != null) StartWrap(previous);
            else
            {
                AttachPlanes();
                if (!ReferenceEquals(previous, target))
                {
                    var unused = sparePlane; sparePlane = previous; ClosePlane(unused);
                }
            }
            replacedPlane = null;
            glyphRasterizations++; glyphsDirty = false; urgentGlyphs = false; resizeUploadDeadline = 0; UpdateEffectProperties(); ShowSurface();
        }
        catch (Exception error) when (error is COMException or ArgumentException or NotSupportedException or ObjectDisposedException)
        {
            ClosePlane(unpublished);
            if (!ReferenceEquals(replacedPlane, outgoingPlane)) ClosePlane(replacedPlane);
            faulted = true; ReleaseSurface(); NativeFallback();
        }
    }
    private GlyphPlane CreatePlane(LyricsGraphicsResources resources, int width, int height, double dpi)
    {
        var result = new GlyphPlane { PixelWidth = width, PixelHeight = height, Dpi = dpi, Width = width * 96 / dpi, Height = height * 96 / dpi };
        try
        {
            var compositor = resources.Compositor;
            result.Surface = resources.GraphicsDevice.CreateDrawingSurface(new Size(width, height), DirectXPixelFormat.B8G8R8A8UIntNormalized, DirectXAlphaMode.Premultiplied);
            result.Glyphs = new CanvasRenderTarget(resources.Device, (float)result.Width, (float)result.Height, (float)dpi);
            result.SurfaceBrush = compositor.CreateSurfaceBrush(result.Surface); result.SurfaceBrush.Stretch = CompositionStretch.Fill;
            result.BlurBrush = resources.BlurFactory.CreateBrush(); result.BlurBrush.SetSourceParameter("glyphs", result.SurfaceBrush);
            result.MaskBrush = compositor.CreateLinearGradientBrush(); result.MaskBrush.MappingMode = CompositionMappingMode.Absolute;
            foreach (var stop in new[] { compositor.CreateColorGradientStop(0, Colors.Transparent), compositor.CreateColorGradientStop(.09f, Colors.White), compositor.CreateColorGradientStop(.91f, Colors.White), compositor.CreateColorGradientStop(1, Colors.Transparent) })
            { result.MaskStops.Add(stop); result.MaskBrush.ColorStops.Add(stop); }
            result.MaskedBrush = compositor.CreateMaskBrush(); result.MaskedBrush.Source = result.BlurBrush; result.MaskedBrush.Mask = result.MaskBrush;
            result.Sprite = compositor.CreateSpriteVisual(); result.Sprite.Size = new Vector2((float)result.Width, (float)result.Height); result.Sprite.Brush = result.MaskedBrush;
            surfaceCreations++; return result;
        }
        catch { ClosePlane(result); throw; }
    }
    private static CanvasTextLayout CreateTextLayout(CanvasDevice device, TextBlock text, double scale)
    {
        using var format = PlayerText.CreateFormat(text.FontFamily.Source, (float)(text.FontSize * scale), text.FontWeight, text.FontStyle, text.TextWrapping, text.TextTrimming);
        var layout = new CanvasTextLayout(device, text.Text, format, (float)Math.Max(1, text.ActualWidth), (float)Math.Max(1, text.ActualHeight));
        if (text.CharacterSpacing != 0) layout.SetCharacterSpacing(0, text.Text.Length, (float)(text.CharacterSpacing * text.FontSize / 1000), 0, 0);
        return layout;
    }
    private static ulong LineBreaks(CanvasTextLayout layout)
    {
        ulong result = 14695981039346656037;
        foreach (var line in layout.LineMetrics) result = unchecked((result ^ (uint)line.CharacterCount) * 1099511628211);
        return result;
    }
    private void AttachPlanes()
    {
        if (plane?.Sprite == null) return;
        if (planesVisual == null)
        {
            planesVisual = plane.Sprite.Compositor.CreateContainerVisual();
            ElementCompositionPreview.SetElementChildVisual(overlay, planesVisual);
        }
        planesVisual.Children.RemoveAll();
        if (outgoingPlane?.Sprite is { } previous) planesVisual.Children.InsertAtBottom(previous);
        planesVisual.Children.InsertAtTop(plane.Sprite);
    }
    private void StartWrap(GlyphPlane previous)
    {
        outgoingPlane = previous; AttachPlanes();
        var entering = plane!.Sprite!; var leaving = previous.Sprite!;
        entering.Opacity = 0; leaving.Opacity = 1; leaving.IsVisible = true;
        using var easing = entering.Compositor.CreateCubicBezierEasingFunction(new Vector2(.2f, 0), new Vector2(.2f, 1));
        using var fade = entering.Compositor.CreateScalarKeyFrameAnimation();
        fade.Duration = TimeSpan.FromMilliseconds(WrapDurationMs); fade.StopBehavior = AnimationStopBehavior.LeaveCurrentValue;
        fade.InsertKeyFrame(0, 0); fade.InsertKeyFrame(1, 1, easing); entering.StartAnimation("Opacity", fade);
        fade.InsertKeyFrame(0, 1); fade.InsertKeyFrame(1, 0, easing); leaving.StartAnimation("Opacity", fade);
        wrapTransitionsStarted++; wrapDeadline = Stopwatch.GetTimestamp() + Stopwatch.Frequency * WrapDurationMs / 1000;
        if (wrapTimer == null)
        {
            wrapTimer = DispatcherQueue.CreateTimer(); wrapTimer.IsRepeating = false;
            wrapTimer.Tick += WrapExpired;
        }
        wrapTimer.Stop(); wrapTimer.Interval = TimeSpan.FromMilliseconds(WrapDurationMs + 16); wrapTimer.Start();
    }
    private void WrapExpired(DispatcherQueueTimer sender, object args)
    {
        // A queued tick from an older transition may run after rapid reversal.
        // The current deadline owns retirement, so it cannot finish a new fade.
        long remaining = wrapDeadline - Stopwatch.GetTimestamp();
        if (outgoingPlane != null && remaining > 0)
        {
            sender.Interval = TimeSpan.FromMilliseconds(Math.Max(1, remaining * 1000.0 / Stopwatch.Frequency)); sender.Start(); return;
        }
        try { FinishWrap(queueDraw: true); }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { faulted = true; ReleaseSurface(); }
    }
    private void FinishWrap(bool queueDraw)
    {
        if (outgoingPlane == null) return;
        wrapTimer?.Stop(); wrapDeadline = 0;
        var retired = outgoingPlane; outgoingPlane = null;
        var replacedSpare = sparePlane; sparePlane = retired; ClosePlane(replacedSpare);
        try
        {
            if (plane?.Sprite is { } current) { current.StopAnimation("Opacity"); current.Opacity = 1; }
            if (retired.Sprite is { } old) { old.StopAnimation("Opacity"); old.Opacity = 1; old.IsVisible = false; }
            AttachPlanes();
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { faulted = true; ReleaseSurface(); }
        if (queueDraw && glyphsDirty) QueueDraw();
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
        if (wrapTimer is { } timer) { timer.Stop(); timer.Tick -= WrapExpired; wrapTimer = null; }
        wrapDeadline = 0;
        var oldPlane = plane; var oldSpare = sparePlane; var oldOutgoing = outgoingPlane; var oldVisual = planesVisual;
        // Native close callbacks can reenter layout. Publish the fallback state
        // before releasing any shared brush graph or drawing resource.
        plane = sparePlane = outgoingPlane = null; planesVisual = null;
        glyphsDirty = true; urgentGlyphs = true; resizeUploadDeadline = 0; appliedEdgeRadius = appliedSurfaceTop = appliedViewportHeight = double.NaN; NativeFallback();
        try { ElementCompositionPreview.SetElementChildVisual(overlay, null); oldVisual?.Children.RemoveAll(); }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { }
        ClosePlane(oldPlane); ClosePlane(oldSpare); ClosePlane(oldOutgoing); LyricsGraphicsResources.Close(oldVisual);
    }
    private static void ClosePlane(GlyphPlane? target)
    {
        if (target == null) return;
        var oldSprite = target.Sprite; var oldMasked = target.MaskedBrush; var oldMask = target.MaskBrush; var oldBlur = target.BlurBrush; var oldBrush = target.SurfaceBrush;
        var oldSurface = target.Surface; var oldGlyphs = target.Glyphs; var stops = target.MaskStops.ToArray();
        target.Sprite = null; target.MaskedBrush = null; target.MaskBrush = null; target.BlurBrush = null; target.SurfaceBrush = null; target.Surface = null; target.Glyphs = null; target.MaskStops.Clear();
        try
        {
            if (oldSprite != null) { oldSprite.StopAnimation("Opacity"); oldSprite.Brush = null; }
            if (oldMasked != null) { oldMasked.Source = null; oldMasked.Mask = null; }
            if (oldBrush != null) oldBrush.Surface = null;
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { }
        LyricsGraphicsResources.Close(oldSprite); LyricsGraphicsResources.Close(oldMasked); LyricsGraphicsResources.Close(oldMask); LyricsGraphicsResources.Close(oldBlur); LyricsGraphicsResources.Close(oldBrush);
        foreach (var stop in stops) LyricsGraphicsResources.Close(stop);
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
