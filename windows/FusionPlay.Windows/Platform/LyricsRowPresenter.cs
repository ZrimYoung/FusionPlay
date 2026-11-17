using System.Numerics;
using System.Runtime.InteropServices;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

/// <summary>A virtualized native button/text row with a cached DirectWrite glyph plane.</summary>
public sealed class LyricsRowPresenter : Button
{
    private readonly Grid content = new();
    private readonly StackPanel measurement = new();
    private readonly TextBlock original = new() { TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.None, FontWeight = Microsoft.UI.Text.FontWeights.Bold },
        translation = new() { TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.None, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Opacity = .78 };
    private readonly Image image = new() { Stretch = Stretch.Fill, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    private readonly Canvas overlay = new() { IsHitTestVisible = false };
    private LyricsRowItem? item;
    private CanvasImageSource? surface;
    private CanvasRenderTarget? glyphs;
    private bool attached, queued, glyphsDirty = true, faulted;
    private double sourceWidth, sourceHeight, sourceDpi, edgeRadius, surfaceTop, viewportHeight;
    private double displayedOpacity = double.NaN;
    internal LyricsRowItem? Item => item;

    public LyricsRowPresenter()
    {
        Padding = new Thickness(0); BorderThickness = new Thickness(0); Background = new SolidColorBrush(Colors.Transparent);
        HorizontalContentAlignment = HorizontalAlignment.Stretch; VerticalContentAlignment = VerticalAlignment.Stretch;
        measurement.Children.Add(original); measurement.Children.Add(translation); content.Children.Add(measurement); overlay.Children.Add(image); content.Children.Add(overlay); Content = content;
        foreach (var child in new FrameworkElement[] { content, measurement, original, translation, overlay, image }) AutomationProperties.SetAccessibilityView(child, AccessibilityView.Raw);
        DataContextChanged += (_, _) => SetItem(DataContext as LyricsRowItem);
        Loaded += (_, _) => { attached = true; faulted = false; item?.Owner.Register(this); QueueDraw(); };
        Unloaded += (_, _) => { attached = false; item?.Owner.Unregister(this); StopAnimations(); ReleaseSurface(); };
        SizeChanged += (_, _) => { glyphsDirty = true; faulted = false; UpdateEdge(); QueueDraw(); };
        Click += (_, _) => { if (item is { } current) current.Owner.RequestSeek(current); };
    }
    private void SetItem(LyricsRowItem? next)
    {
        if (ReferenceEquals(item, next)) return;
        if (attached) item?.Owner.Unregister(this);
        StopAnimations(); ReleaseSurface(); item = next; faulted = false;
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
        double opacity = LyricsViewport.LineOpacity(owner.Timed, current.Index, owner.ActiveIndex, owner.HighContrast);
        SetOpacity(opacity, owner.MotionEnabled && owner.PresentationLoaded);
        if (style)
        {
            double size = owner.BodySize;
            original.FontSize = size; translation.FontSize = owner.Compact ? Math.Max(12, size * .56) : size * .6;
            original.FontFamily = translation.FontFamily = owner.LyricFont; original.FontWeight = owner.BodyWeight; translation.FontWeight = owner.TranslationWeight;
            original.Language = translation.Language = L.Language == "en" ? "en-US" : "zh-CN";
            content.Padding = new Thickness(owner.Bleed + 3, owner.Compact ? 3 : 5, owner.Bleed + 3, owner.Compact ? 3 : 5);
            measurement.Spacing = owner.Compact ? 5 : 7; Margin = new Thickness(0, 0, 0, owner.Compact ? 12 : 20);
            Brush foreground = owner.HighContrast ? (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"] : new SolidColorBrush(Colors.White);
            original.Foreground = translation.Foreground = foreground;
            glyphsDirty = true; faulted = false;
        }
        UpdateEdge(); QueueDraw();
    }
    private void SetOpacity(double value, bool animate)
    {
        if (displayedOpacity == value && animate) return;
        bool first = double.IsNaN(displayedOpacity); displayedOpacity = value;
        try
        {
            var visual = ElementCompositionPreview.GetElementVisual(this);
            // The interrupted animation leaves its effective value on the compositor;
            // StartingValue therefore never snaps back to the previous target.
            visual.StopAnimation("Opacity");
            if (first || !animate) { visual.Opacity = (float)value; return; }
            using var easing = visual.Compositor.CreateCubicBezierEasingFunction(new Vector2(.42f, 0), new Vector2(.58f, 1));
            using var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
            animation.InsertExpressionKeyFrame(0, "this.StartingValue"); animation.InsertKeyFrame(1, (float)value, easing);
            animation.Duration = TimeSpan.FromMilliseconds(300); animation.StopBehavior = AnimationStopBehavior.LeaveCurrentValue;
            visual.StartAnimation("Opacity", animation);
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { Opacity = value; }
    }
    internal void StopAnimations()
    {
        displayedOpacity = double.NaN;
        try { ElementCompositionPreview.GetElementVisual(this).StopAnimation("Opacity"); }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { }
    }
    internal void UpdateEdge()
    {
        if (!attached || item is not { } current) return;
        try
        {
            var owner = current.Owner;
            double y = TransformToVisual(owner).TransformPoint(new Point()).Y;
            double radius = LyricsViewport.EdgeBlur(y + ActualHeight * .5, owner.ViewportHeight, owner.Compact, owner.EffectsEnabled);
            double top = measurement.TransformToVisual(owner).TransformPoint(new Point()).Y - owner.Bleed;
            if (Math.Abs(radius - edgeRadius) > .05 || Math.Abs(top - surfaceTop) > .5 || viewportHeight != owner.ViewportHeight)
            {
                edgeRadius = radius; surfaceTop = top; viewportHeight = owner.ViewportHeight; QueueDraw();
            }
        }
        catch (ArgumentException) { }
    }
    private void QueueDraw()
    {
        if (!attached || queued || item?.Owner.PresentationLoaded != true) return;
        queued = DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { queued = false; if (attached) Draw(); });
    }
    private void NativeFallback() { measurement.Opacity = 1; image.Visibility = Visibility.Collapsed; }
    private void Draw()
    {
        if (!attached || item is not { } current || !current.Owner.PresentationLoaded) return;
        var owner = current.Owner;
        bool fade = viewportHeight > 0 && (surfaceTop < viewportHeight * .09 || surfaceTop + measurement.ActualHeight + owner.Bleed * 2 > viewportHeight * .91);
        if (owner.HighContrast || faulted || !owner.EnhancedText && edgeRadius < .01 && !fade) { NativeFallback(); return; }
        double bleed = owner.Bleed, width = measurement.ActualWidth, height = measurement.ActualHeight, dpi = 96 * (XamlRoot?.RasterizationScale ?? 1);
        double paddedWidth = width + bleed * 2, paddedHeight = height + bleed * 2;
        if (width <= 0 || height <= 0 || paddedWidth * dpi / 96 > 8192 || paddedHeight * dpi / 96 > 8192) { NativeFallback(); return; }
        try
        {
            var device = CanvasDevice.GetSharedDevice();
            if (surface == null || sourceWidth != paddedWidth || sourceHeight != paddedHeight || sourceDpi != dpi)
            {
                ReleaseSurface(); surface = new CanvasImageSource(device, (float)paddedWidth, (float)paddedHeight, (float)dpi);
                glyphs = new CanvasRenderTarget(device, (float)paddedWidth, (float)paddedHeight, (float)dpi);
                sourceWidth = paddedWidth; sourceHeight = paddedHeight; sourceDpi = dpi; glyphsDirty = true;
            }
            if (glyphsDirty)
            {
                using var draw = glyphs!.CreateDrawingSession(); draw.Clear(Colors.Transparent);
                using var enhanced = owner.EnhancedText ? NativeTypography.Enhance(draw) : null;
                DrawText(draw, device, original, (float)bleed, (float)bleed, 255, owner.TextScale);
                if (translation.Visibility == Visibility.Visible)
                {
                    float y = (float)(bleed + original.ActualHeight + measurement.Spacing);
                    DrawText(draw, device, translation, (float)bleed, y, 199, owner.TextScale);
                }
                glyphsDirty = false;
            }
            using var gamma = new GammaTransferEffect { Source = glyphs, RedDisable = true, GreenDisable = true, BlueDisable = true, AlphaExponent = owner.EnhancedText ? .94f : 1, ClampOutput = true };
            using var blur = new GaussianBlurEffect { Source = gamma, BlurAmount = (float)edgeRadius, BorderMode = EffectBorderMode.Soft, Optimization = EffectOptimization.Balanced };
            using var mask = new CanvasCommandList(device);
            using (var maskDraw = mask.CreateDrawingSession())
            {
                using var brush = new CanvasLinearGradientBrush(device, new CanvasGradientStop[]
                {
                    new() { Position = 0, Color = Colors.Transparent }, new() { Position = .09f, Color = Colors.White },
                    new() { Position = .91f, Color = Colors.White }, new() { Position = 1, Color = Colors.Transparent }
                });
                brush.StartPoint = new Vector2(0, (float)-surfaceTop); brush.EndPoint = brush.StartPoint + new Vector2(0, (float)Math.Max(1, viewportHeight));
                maskDraw.FillRectangle(0, 0, (float)paddedWidth, (float)paddedHeight, brush);
            }
            using var masked = new AlphaMaskEffect { Source = blur, AlphaMask = mask };
            using (var draw = surface.CreateDrawingSession(Colors.Transparent)) draw.DrawImage(masked);
            image.Width = paddedWidth; image.Height = paddedHeight; Canvas.SetLeft(image, -bleed); Canvas.SetTop(image, -bleed); image.Source = surface;
            measurement.Opacity = 0; image.Visibility = Visibility.Visible;
        }
        catch (Exception error) when (error is COMException or ArgumentException or NotSupportedException or ObjectDisposedException)
        {
            // Device loss and very large rows remain readable as native text, with no lyric logging.
            faulted = true; ReleaseSurface(); NativeFallback();
        }
    }
    private static void DrawText(CanvasDrawingSession draw, CanvasDevice device, TextBlock text, float x, float y, byte alpha, double scale)
    {
        using var format = PlayerText.CreateFormat(text.FontFamily.Source, (float)(text.FontSize * scale), text.FontWeight, text.FontStyle, TextWrapping.Wrap, TextTrimming.None);
        using var layout = new CanvasTextLayout(device, text.Text, format, (float)Math.Max(1, text.ActualWidth), (float)Math.Max(1, text.ActualHeight));
        if (text.CharacterSpacing != 0) layout.SetCharacterSpacing(0, text.Text.Length, (float)(text.CharacterSpacing * text.FontSize / 1000), 0, 0);
        draw.DrawTextLayout(layout, x, y, global::Windows.UI.Color.FromArgb(alpha, 255, 255, 255));
    }
    internal void ReleaseSurface()
    {
        image.Source = null; surface = null; glyphs?.Dispose(); glyphs = null; glyphsDirty = true; NativeFallback();
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new LyricPeer(this);
    private sealed class LyricPeer(LyricsRowPresenter owner) : ButtonAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => owner.item?.Line.TimeMs.HasValue == true ? AutomationControlType.Button : AutomationControlType.Text;
        protected override object? GetPatternCore(PatternInterface patternInterface)
            => patternInterface == PatternInterface.Invoke && owner.item?.Line.TimeMs == null ? null : base.GetPatternCore(patternInterface);
    }
}
