using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI.Composition;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

/// <summary>Moves DirectWrite-shaped clusters using the row's existing GPU textures.</summary>
internal sealed class LyricsGlyphReflow : IDisposable
{
    internal const int CrossLineMilliseconds = 480;
    internal const int MaximumLiveClusters = 32;
    private const int SameLineMilliseconds = 190;
    private const int MaximumClusters = 64;
    private const int MaximumSourceLength = 256;
    internal readonly record struct ClusterKey(int Section, uint Start, int Length);
    internal readonly record struct Presentation(Vector2 Position, float Opacity);
    internal readonly record struct LayoutSection(CanvasTextLayout Layout, Vector2 Origin, string Text);

    private readonly LyricsGraphicsResources resources;
    private readonly List<(SpriteVisual Sprite, CompositionSurfaceBrush Brush)> segments = [];
    private readonly Dictionary<ClusterKey, Movement> movements = [];
    private readonly long started = Stopwatch.GetTimestamp();
    internal ContainerVisual Visual { get; }
    internal int ClusterCount => movements.Count;
    internal int DurationMilliseconds { get; private set; }

    private readonly record struct Cluster(Rect Ink, float Baseline, float FontSize);
    private readonly record struct Pair(ClusterKey Key, Cluster Before, Cluster After);
    private readonly record struct Movement(Vector2 From, Vector2 To, float FromOpacity, bool CrossLine)
    {
        internal Presentation At(double milliseconds)
        {
            if (!CrossLine)
            {
                float time = Math.Clamp((float)(milliseconds / SameLineMilliseconds), 0, 1);
                float easing = time < .25f ? time * .625f : time > .75f ? 1 - (1 - time) * .625f : .15625f + (time - .25f) * 1.375f;
                return new(Vector2.Lerp(From, To, easing), float.Lerp(FromOpacity, 1, easing));
            }
            float progress = Math.Clamp((float)(milliseconds / CrossLineMilliseconds), 0, 1);
            if (progress < .30f) return new(From, FromOpacity * (1 - progress / .30f));
            if (progress > .58f) return new(To, (progress - .58f) / .42f);
            return new(Vector2.Lerp(From, To, (progress - .30f) / .28f), 0);
        }
    }

    private LyricsGlyphReflow(LyricsGraphicsResources resources)
    { this.resources = resources; Visual = resources.Compositor.CreateContainerVisual(); }

    internal static LyricsGlyphReflow? TryStart(
        LyricsGraphicsResources resources, CompositionDrawingSurface source, CompositionDrawingSurface target,
        IReadOnlyList<LayoutSection> before, IReadOnlyList<LayoutSection> after, float bleed, float pixelScale,
        IReadOnlyDictionary<ClusterKey, Presentation>? continuation, out string status, bool liveResize = false)
    {
        status = "cluster_motion_budget";
        if (!resources.TryReserveClusterMotion()) return null;
        LyricsGlyphReflow? motion = null;
        bool transferred = false;
        try
        {
            int maximum = liveResize ? MaximumLiveClusters : MaximumClusters;
            var previous = ClusterRenderer.Capture(resources.Device, before, pixelScale, maximum, out status);
            if (previous == null) return null;
            var next = ClusterRenderer.Capture(resources.Device, after, pixelScale, maximum, out status);
            if (next == null) return null;
            status = "changed_cluster_boundaries";
            if (previous.Count == 0 || previous.Count != next.Count) return null;
            var pairs = new List<Pair>(previous.Count);
            foreach (var (key, oldCluster) in previous)
            {
                if (!next.TryGetValue(key, out var newCluster)) return null;
                pairs.Add(new(key, oldCluster, newCluster));
            }
            // Do not cut ink that crosses a cluster boundary. Merge adjacent
            // clusters on the same line when either snapshot needs both.
            status = "overlapping_cluster_ink";
            if (!CombineOverlappingInk(pairs)) return null;
            status = "stationary_clusters";
            motion = new(resources);
            motion.AddSegments(pairs, source, target, bleed, pixelScale, continuation);
            if (motion.DurationMilliseconds == 0) return null;
            transferred = true;
            status = "animated";
            return motion;
        }
        catch (Exception error) when (error is COMException or ArgumentException or NotSupportedException or ObjectDisposedException)
        { status = $"cluster_rendering_unavailable_{error.HResult:X8}"; return null; }
        finally
        {
            if (!transferred)
            {
                if (motion != null) motion.Dispose();
                else resources.ReleaseClusterMotion();
            }
        }
    }

    private static bool CombineOverlappingInk(List<Pair> pairs)
    {
        pairs.Sort(static (left, right) => left.Key.Section != right.Key.Section
            ? left.Key.Section.CompareTo(right.Key.Section) : left.Key.Start.CompareTo(right.Key.Start));
        for (int first = 0; first < pairs.Count; first++)
        {
            for (int second = first + 1; second < pairs.Count; second++)
            {
                var a = pairs[first]; var b = pairs[second];
                if (!Overlaps(a.Before.Ink, b.Before.Ink) && !Overlaps(a.After.Ink, b.After.Ink)) continue;
                if (second != first + 1 || a.Key.Section != b.Key.Section
                    || a.Before.Baseline != b.Before.Baseline || a.After.Baseline != b.After.Baseline) return false;
                var key = a.Key with { Length = checked((int)(b.Key.Start - a.Key.Start) + b.Key.Length) };
                pairs[first] = new(key, a.Before with { Ink = Union(a.Before.Ink, b.Before.Ink) }, a.After with { Ink = Union(a.After.Ink, b.After.Ink) });
                pairs.RemoveAt(second);
                first = -1;
                break;
            }
        }
        return true;
    }

    private static bool Overlaps(Rect a, Rect b) => a.Left < b.Right && b.Left < a.Right && a.Top < b.Bottom && b.Top < a.Bottom;
    private static Rect Union(Rect a, Rect b)
    {
        double left = Math.Min(a.Left, b.Left), top = Math.Min(a.Top, b.Top);
        return new(left, top, Math.Max(a.Right, b.Right) - left, Math.Max(a.Bottom, b.Bottom) - top);
    }

    private void AddSegments(IReadOnlyList<Pair> pairs, CompositionDrawingSurface source, CompositionDrawingSurface target,
        float bleed, float pixelScale, IReadOnlyDictionary<ClusterKey, Presentation>? continuation)
    {
        var compositor = resources.Compositor;
        using var linear = compositor.CreateLinearEasingFunction();
        foreach (var pair in pairs)
        {
            Vector2 oldOrigin = Position(pair.Before.Ink, bleed), destination = Position(pair.After.Ink, bleed);
            Presentation endpoint = continuation != null && continuation.TryGetValue(pair.Key, out var shown) ? shown : new(oldOrigin, 1);
            bool crosses = Math.Abs(pair.Before.Baseline - pair.After.Baseline) > Math.Max(pair.Before.FontSize, pair.After.FontSize) * .55f;
            bool moving = Vector2.DistanceSquared(endpoint.Position, destination) > .0625f || endpoint.Opacity < .99f;
            var movement = new Movement(endpoint.Position, destination, endpoint.Opacity, crosses);
            movements.Add(pair.Key, movement);
            if (!moving)
            {
                CreateSegment(target, pair.After.Ink, destination, pixelScale).Opacity = 1;
                continue;
            }
            DurationMilliseconds = Math.Max(DurationMilliseconds, crosses ? CrossLineMilliseconds : SameLineMilliseconds);
            if (crosses)
            {
                var leaving = CreateSegment(source, pair.Before.Ink, endpoint.Position, pixelScale);
                var entering = CreateSegment(target, pair.After.Ink, endpoint.Position, pixelScale);
                AnimateCrossLine(leaving, movement, true, linear);
                AnimateCrossLine(entering, movement, false, linear);
            }
            else AnimateSameLine(CreateSegment(target, pair.After.Ink, endpoint.Position, pixelScale), movement, linear);
        }
    }

    private static Vector2 Position(Rect ink, float bleed) => new((float)ink.X - bleed, (float)ink.Y - bleed);
    private SpriteVisual CreateSegment(CompositionDrawingSurface surface, Rect source, Vector2 origin, float pixelScale)
    {
        var compositor = resources.Compositor;
        var brush = compositor.CreateSurfaceBrush(surface);
        SpriteVisual? sprite = null;
        try
        {
            brush.Stretch = CompositionStretch.None; brush.HorizontalAlignmentRatio = brush.VerticalAlignmentRatio = 0;
            brush.Scale = new Vector2(1 / pixelScale); brush.Offset = new Vector2((float)-source.X, (float)-source.Y);
            sprite = compositor.CreateSpriteVisual(); sprite.Size = new Vector2((float)source.Width, (float)source.Height);
            sprite.Offset = new Vector3(origin, 0); sprite.Brush = brush;
            Visual.Children.InsertAtTop(sprite); segments.Add((sprite, brush));
            return sprite;
        }
        catch
        { LyricsGraphicsResources.Close(sprite); LyricsGraphicsResources.Close(brush); throw; }
    }

    private static void AnimateSameLine(SpriteVisual sprite, Movement movement, CompositionEasingFunction easing)
    {
        sprite.Opacity = movement.FromOpacity;
        using var move = sprite.Compositor.CreateVector3KeyFrameAnimation();
        using var fade = sprite.Compositor.CreateScalarKeyFrameAnimation();
        move.Duration = fade.Duration = TimeSpan.FromMilliseconds(SameLineMilliseconds);
        foreach (float progress in new[] { 0, .25f, .75f, 1 })
        {
            var state = movement.At(progress * SameLineMilliseconds);
            move.InsertKeyFrame(progress, new Vector3(state.Position, 0), easing);
            fade.InsertKeyFrame(progress, state.Opacity, easing);
        }
        sprite.StartAnimation("Offset", move); sprite.StartAnimation("Opacity", fade);
    }

    private static void AnimateCrossLine(SpriteVisual sprite, Movement movement, bool outgoing, CompositionEasingFunction easing)
    {
        sprite.Opacity = outgoing ? movement.FromOpacity : 0;
        using var move = sprite.Compositor.CreateVector3KeyFrameAnimation();
        using var fade = sprite.Compositor.CreateScalarKeyFrameAnimation();
        move.Duration = fade.Duration = TimeSpan.FromMilliseconds(CrossLineMilliseconds);
        move.InsertKeyFrame(0, new Vector3(movement.From, 0), easing); move.InsertKeyFrame(.30f, new Vector3(movement.From, 0), easing);
        move.InsertKeyFrame(.58f, new Vector3(movement.To, 0), easing); move.InsertKeyFrame(1, new Vector3(movement.To, 0), easing);
        fade.InsertKeyFrame(0, sprite.Opacity, easing); fade.InsertKeyFrame(outgoing ? .30f : .58f, 0, easing);
        fade.InsertKeyFrame(1, outgoing ? 0 : 1, easing);
        sprite.StartAnimation("Offset", move); sprite.StartAnimation("Opacity", fade);
    }

    internal Dictionary<ClusterKey, Presentation> Sample()
    {
        double elapsed = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
        return movements.ToDictionary(static pair => pair.Key, pair => pair.Value.At(elapsed));
    }

    public void Dispose()
    {
        LyricsGraphicsResources.Close(Visual);
        foreach (var (sprite, brush) in segments)
        {
            LyricsGraphicsResources.Close(sprite);
            LyricsGraphicsResources.Close(brush);
        }
        segments.Clear(); resources.ReleaseClusterMotion();
    }

    private sealed class ClusterRenderer(CanvasDevice device, float pixelScale, int maximumClusters) : ICanvasTextRenderer
    {
        private readonly Dictionary<ClusterKey, Cluster> clusters = [];
        private int section;
        private string? unsupported;
        private string text = "";
        public float Dpi => 96 * pixelScale;
        public bool PixelSnappingDisabled => true;
        public Matrix3x2 Transform => Matrix3x2.Identity;

        internal static Dictionary<ClusterKey, Cluster>? Capture(CanvasDevice device, IReadOnlyList<LayoutSection> layouts,
            float pixelScale, int maximumClusters, out string status)
        {
            var renderer = new ClusterRenderer(device, pixelScale, maximumClusters);
            foreach (var layout in layouts)
            {
                renderer.text = layout.Text;
                layout.Layout.DrawToTextRenderer(renderer, layout.Origin);
                if (renderer.unsupported is { } reason) { status = reason; return null; }
                renderer.section++;
            }
            status = "captured";
            return renderer.clusters;
        }

        public void DrawGlyphRun(Vector2 point, CanvasFontFace fontFace, float fontSize, CanvasGlyph[] glyphs,
            bool isSideways, uint bidiLevel, object brush, CanvasTextMeasuringMode measuringMode, string localeName,
            string textString, int[] clusterMapIndices, uint characterIndex, CanvasGlyphOrientation glyphOrientation)
        {
            if (unsupported != null) return;
            // Win2D constructs the callback string from DirectWrite's pointer
            // without its run length. The cluster map and the source index
            // delimit the actual run, including after fallback-font splits.
            if (isSideways || glyphOrientation != CanvasGlyphOrientation.Upright || characterIndex > text.Length
                || clusterMapIndices.Length > text.Length - (int)characterIndex || glyphs.Length > MaximumSourceLength)
            { unsupported = "unsupported_glyph_run"; return; }
            if (clusterMapIndices.Length == 0) return;
            int[] boundaries = clusterMapIndices.Distinct().Order().ToArray();
            if (boundaries[0] != 0 || boundaries[^1] >= glyphs.Length) { unsupported = "invalid_cluster_map"; return; }
            var baselineOffsets = new float[glyphs.Length + 1];
            float direction = (bidiLevel & 1) == 0 ? 1 : -1;
            for (int index = 0; index < glyphs.Length; index++) baselineOffsets[index + 1] = baselineOffsets[index] + glyphs[index].Advance * direction;
            for (int start = 0; start < clusterMapIndices.Length;)
            {
                int end = start + 1;
                int glyphStart = clusterMapIndices[start];
                while (end < clusterMapIndices.Length && clusterMapIndices[end] == glyphStart) end++;
                if (!text.AsSpan((int)characterIndex + start, end - start).IsWhiteSpace())
                {
                    int boundary = Array.BinarySearch(boundaries, glyphStart);
                    int glyphEnd = boundary + 1 < boundaries.Length ? boundaries[boundary + 1] : glyphs.Length;
                    var origin = point + new Vector2(baselineOffsets[glyphStart], 0);
                    using var shape = CanvasGeometry.CreateGlyphRun(device, origin, fontFace, fontSize, glyphs[glyphStart..glyphEnd],
                        false, bidiLevel, measuringMode, glyphOrientation);
                    Rect bounds = shape.ComputeBounds();
                    if (bounds.Width > 0 && bounds.Height > 0)
                    {
                        double x = Math.Floor(bounds.Left * pixelScale) / pixelScale, y = Math.Floor(bounds.Top * pixelScale) / pixelScale;
                        var ink = new Rect(x, y, Math.Ceiling(bounds.Right * pixelScale) / pixelScale - x, Math.Ceiling(bounds.Bottom * pixelScale) / pixelScale - y);
                        if (clusters.Count >= maximumClusters || !clusters.TryAdd(new(section, characterIndex + (uint)start, end - start), new(ink, point.Y, fontSize)))
                        { unsupported = "duplicate_or_too_many_clusters"; return; }
                    }
                    else { unsupported = "missing_cluster_outline"; return; }
                }
                start = end;
            }
        }

        public void DrawUnderline(Vector2 point, float underlineWidth, float underlineThickness, float underlineOffset, float runHeight,
            CanvasTextDirection textDirection, object brush, CanvasTextMeasuringMode measuringMode, string localeName, CanvasGlyphOrientation glyphOrientation) => unsupported = "underline";
        public void DrawStrikethrough(Vector2 point, float width, float thickness, float offset, CanvasTextDirection direction,
            object brush, CanvasTextMeasuringMode measuringMode, string localeName, CanvasGlyphOrientation glyphOrientation) => unsupported = "strikethrough";
        public void DrawInlineObject(Vector2 point, ICanvasTextInlineObject inlineObject, bool isSideways, bool isRightToLeft, object brush,
            CanvasGlyphOrientation glyphOrientation) => unsupported = "inline_object";
    }

    internal static bool Supports(string original, string translation) => original.Length + translation.Length <= MaximumSourceLength;
}
