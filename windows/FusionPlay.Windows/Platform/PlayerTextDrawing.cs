using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Text;

namespace FusionPlay.Windows.Platform;

internal static class PlayerTextDrawing
{
    // A mild coverage adjustment keeps the result controllable even when an
    // external font enhancer overrides DirectWrite's rendering parameters.
    // Only the glyph surface is processed; cover/background pixels stay untouched.
    public static void Composite(CanvasDrawingSession destination, CanvasRenderTarget glyphs, float x = 0, float y = 0)
    {
        using var coverage = new GammaTransferEffect
        {
            Source = glyphs, RedDisable = true, GreenDisable = true, BlueDisable = true,
            AlphaExponent = 0.94f, ClampOutput = true
        };
        destination.DrawImage(coverage, x, y);
    }
    public static void DrawGlyphs(CanvasRenderTarget target, CanvasTextLayout layout, global::Windows.UI.Color color)
    {
        using var drawing = target.CreateDrawingSession();
        drawing.Clear(Microsoft.UI.Colors.Transparent);
        using var parameters = NativeTypography.Enhance(drawing);
        drawing.DrawTextLayout(layout, 0, 0, color);
    }
}
