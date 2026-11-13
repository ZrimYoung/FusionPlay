using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;
using FusionPlay.Windows.Platform;

namespace FusionPlay.Windows;

/// <summary>Native XAML measurement/accessibility with a DPI-matched DirectWrite
/// surface. A native TextBlock remains the fallback for high contrast or device loss.</summary>
public sealed class PlayerText : UserControl
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(PlayerText), new PropertyMetadata("", Changed));
    public static readonly DependencyProperty MaxLinesProperty = DependencyProperty.Register(nameof(MaxLines), typeof(int), typeof(PlayerText), new PropertyMetadata(1, Changed));
    public static readonly DependencyProperty TextWrappingProperty = DependencyProperty.Register(nameof(TextWrapping), typeof(TextWrapping), typeof(PlayerText), new PropertyMetadata(TextWrapping.NoWrap, Changed));
    public static readonly DependencyProperty TextTrimmingProperty = DependencyProperty.Register(nameof(TextTrimming), typeof(TextTrimming), typeof(PlayerText), new PropertyMetadata(TextTrimming.CharacterEllipsis, Changed));
    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public int MaxLines { get => (int)GetValue(MaxLinesProperty); set => SetValue(MaxLinesProperty, value); }
    public TextWrapping TextWrapping { get => (TextWrapping)GetValue(TextWrappingProperty); set => SetValue(TextWrappingProperty, value); }
    public TextTrimming TextTrimming { get => (TextTrimming)GetValue(TextTrimmingProperty); set => SetValue(TextTrimmingProperty, value); }
    private readonly TextBlock measurement = new() { IsHitTestVisible = false };
    private readonly Image image = new() { IsHitTestVisible = false, Stretch = Stretch.Fill, Visibility = Visibility.Collapsed };
    private readonly UISettings ui = new();
    private readonly AccessibilitySettings accessibility = new();
    private CanvasImageSource? surface;
    private CanvasRenderTarget? glyphs;
    private XamlRoot? subscribedRoot;
    private double surfaceWidth, surfaceHeight, surfaceDpi;
    private bool enhanced = true, queued, renderFaulted, attached;
    internal bool Enhanced { get => enhanced; set { if (enhanced == value) return; enhanced = value; Refresh(); } }
    internal bool UsesEnhancedSurface => image.Visibility == Visibility.Visible;

    public PlayerText()
    {
        IsTabStop = false; UseLayoutRounding = true;
        AutomationProperties.SetAccessibilityView(measurement, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(image, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var overlay = new Canvas { IsHitTestVisible = false }; overlay.Children.Add(image);
        var grid = new Grid(); grid.Children.Add(measurement); grid.Children.Add(overlay); Content = grid;
        foreach (var property in new[] { FontFamilyProperty, FontWeightProperty, FontSizeProperty, FontStyleProperty, ForegroundProperty, CharacterSpacingProperty })
            RegisterPropertyChangedCallback(property, (_, _) => Refresh());
        Loaded += (_, _) =>
        {
            attached = true;
            subscribedRoot = XamlRoot;
            if (subscribedRoot != null) subscribedRoot.Changed += RootChanged;
            ui.TextScaleFactorChanged += TextScaleChanged; ui.ColorValuesChanged += ContrastChanged;
            Refresh();
        };
        Unloaded += (_, _) =>
        {
            attached = false;
            if (subscribedRoot != null) subscribedRoot.Changed -= RootChanged;
            subscribedRoot = null;
            ui.TextScaleFactorChanged -= TextScaleChanged; ui.ColorValuesChanged -= ContrastChanged;
            surface = null; glyphs?.Dispose(); glyphs = null; image.Source = null; NativeFallback();
        };
        ActualThemeChanged += (_, _) => Refresh();
        SizeChanged += (_, _) => QueueDraw();
        SyncMeasurement();
    }
    private static void Changed(DependencyObject sender, DependencyPropertyChangedEventArgs args) => ((PlayerText)sender).Refresh();
    private void RootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => QueueDraw();
    private void TextScaleChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(Refresh);
    private void ContrastChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(Refresh);
    private void Refresh()
    {
        renderFaulted = false; SyncMeasurement(); QueueDraw();
    }
    private void SyncMeasurement()
    {
        measurement.Text = Text ?? ""; measurement.MaxLines = MaxLines;
        measurement.TextWrapping = TextWrapping; measurement.TextTrimming = TextTrimming;
        measurement.FontFamily = FontFamily; measurement.FontWeight = FontWeight;
        measurement.FontStyle = FontStyle; measurement.FontSize = FontSize;
        measurement.CharacterSpacing = CharacterSpacing;
        if (Foreground != null) measurement.Foreground = Foreground;
    }
    private void QueueDraw()
    {
        if (!attached || queued) return;
        queued = DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { queued = false; if (attached) Draw(); });
    }
    private void NativeFallback() { measurement.Opacity = 1; image.Visibility = Visibility.Collapsed; }
    internal bool RenderForCheck() { Draw(allowUnloaded: true); return UsesEnhancedSurface; }
    private void Draw(bool allowUnloaded = false)
    {
        if ((!attached && !allowUnloaded) || !enhanced || accessibility.HighContrast || renderFaulted || Text.Length == 0)
        { NativeFallback(); return; }
        double width = ActualWidth, height = ActualHeight, dpi = 96 * (XamlRoot?.RasterizationScale ?? 1);
        if (width <= 0 || height <= 0 || width * dpi / 96 > 8192 || height * dpi / 96 > 8192 || measurement.Foreground is not SolidColorBrush foreground)
        { NativeFallback(); return; }
        try
        {
            var device = CanvasDevice.GetSharedDevice();
            if (surface == null || surfaceWidth != width || surfaceHeight != height || surfaceDpi != dpi)
            {
                surface = new CanvasImageSource(device, (float)width, (float)height, (float)dpi);
                glyphs?.Dispose(); glyphs = new CanvasRenderTarget(device, (float)width, (float)height, (float)dpi);
                surfaceWidth = width; surfaceHeight = height; surfaceDpi = dpi;
            }
            using var format = CreateFormat(FontFamily.Source, (float)(FontSize * ui.TextScaleFactor), FontWeight, FontStyle, TextWrapping, TextTrimming);
            using var layout = new CanvasTextLayout(device, Text, format, (float)width, (float)height);
            if (CharacterSpacing != 0) layout.SetCharacterSpacing(0, Text.Length, (float)(CharacterSpacing * FontSize / 1000), 0, 0);
            PlayerTextDrawing.DrawGlyphs(glyphs!, layout, foreground.Color);
            using (var drawing = surface.CreateDrawingSession(Colors.Transparent))
            {
                PlayerTextDrawing.Composite(drawing, glyphs!);
            }
            image.Width = width; image.Height = height; image.Source = surface;
            image.Visibility = Visibility.Visible; measurement.Opacity = 0;
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ArgumentException or NotSupportedException)
        {
            // Font/device/rendering failures never interrupt receiver polling or
            // leave blank metadata. No song text is written to diagnostics.
            renderFaulted = true; surface = null; glyphs?.Dispose(); glyphs = null; image.Source = null; NativeFallback();
            System.Diagnostics.Debug.WriteLine("Player text fallback: " + error.GetType().Name);
        }
    }
    internal static CanvasTextFormat CreateFormat(string family, float size, global::Windows.UI.Text.FontWeight weight,
        global::Windows.UI.Text.FontStyle style = global::Windows.UI.Text.FontStyle.Normal,
        TextWrapping wrapping = TextWrapping.NoWrap, TextTrimming trimming = TextTrimming.CharacterEllipsis) => new()
    {
        FontFamily = string.IsNullOrEmpty(family) || family == "XamlAutoFontFamily" ? NativeTypography.SystemFamily.Name : family,
        FontSize = size, FontWeight = weight, FontStyle = style,
        LocaleName = L.Language == "en" ? "en-US" : "zh-CN",
        WordWrapping = wrapping == TextWrapping.NoWrap ? CanvasWordWrapping.NoWrap : CanvasWordWrapping.Wrap,
        TrimmingGranularity = trimming == TextTrimming.None ? CanvasTextTrimmingGranularity.None : CanvasTextTrimmingGranularity.Character,
        TrimmingSign = trimming == TextTrimming.None ? CanvasTrimmingSign.None : CanvasTrimmingSign.Ellipsis,
        Options = CanvasDrawTextOptions.EnableColorFont
    };
    protected override AutomationPeer OnCreateAutomationPeer() => new PlayerTextPeer(this);
    private sealed class PlayerTextPeer(PlayerText owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override string GetNameCore() => owner.Text;
        protected override string GetClassNameCore() => "TextBlock";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
    }
}
