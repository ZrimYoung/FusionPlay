using System.Runtime.CompilerServices;
using FusionPlay.Core;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

/// <summary>Filled transport marks with identical view boxes and no dependency on the system icon font.</summary>
internal static class PlaybackIcons
{
    private sealed class IconState { public PlaybackCommand? Command; }
    private static readonly ConditionalWeakTable<PathIcon, IconState> States = new();

    public static PathIcon Create(PlaybackCommand command, double size = 18)
    {
        var icon = new PathIcon { Width = size, Height = size, IsHitTestVisible = false };
        Update(icon, command);
        return icon;
    }

    public static void Update(PathIcon icon, PlaybackCommand command)
    {
        ArgumentNullException.ThrowIfNull(icon);
        var state = States.GetValue(icon, static _ => new IconState());
        if (state.Command == command) return;
        // Geometry has presentation state in WinUI: every PathIcon owns its own instance.
        // Cache the command on that icon, rather than sharing one mutable shape across windows.
        var geometry = Draw(command);
        icon.Data = geometry;
        state.Command = command;
    }

    private static PathGeometry Draw(PlaybackCommand command)
    {
        var geometry = new PathGeometry { FillRule = FillRule.Nonzero };
        switch (command)
        {
            case PlaybackCommand.Play:
            {
                var triangle = Figure(6, 3.8);
                Curve(triangle, 6, 3, 6.65, 2.65, 7.35, 3.1);
                Line(triangle, 16.55, 8.85);
                Curve(triangle, 17.45, 9.4, 17.45, 10.6, 16.55, 11.15);
                Line(triangle, 7.35, 16.9);
                Curve(triangle, 6.65, 17.35, 6, 17, 6, 16.2);
                geometry.Figures.Add(triangle);
                break;
            }
            case PlaybackCommand.Pause:
                RoundedBar(geometry, 5.2, 3, 3.6, 14, 0.9);
                RoundedBar(geometry, 11.2, 3, 3.6, 14, 0.9);
                break;
            case PlaybackCommand.Previous:
            case PlaybackCommand.Next:
            {
                Step(geometry, previous: command == PlaybackCommand.Previous);
                break;
            }
            default:
                throw new ArgumentOutOfRangeException(nameof(command));
        }
        return geometry;
    }

    private static void Step(PathGeometry geometry, bool previous)
    {
        // Bake the mirror into every point. Both versions use the same filled bounds,
        // including a generous end bar, with no geometry-level transform or phantom figure.
        Point At(double x, double y) => new(previous ? 20 - x : x, y);
        var triangle = new PathFigure { StartPoint = At(3, 4.75), IsClosed = true, IsFilled = true };
        triangle.Segments.Add(new BezierSegment { Point1 = At(3, 4.05), Point2 = At(3.65, 3.7), Point3 = At(4.3, 4.1) });
        triangle.Segments.Add(new LineSegment { Point = At(12.25, 9.1) });
        triangle.Segments.Add(new BezierSegment { Point1 = At(13, 9.55), Point2 = At(13, 10.45), Point3 = At(12.25, 10.9) });
        triangle.Segments.Add(new LineSegment { Point = At(4.3, 15.9) });
        triangle.Segments.Add(new BezierSegment { Point1 = At(3.65, 16.3), Point2 = At(3, 15.95), Point3 = At(3, 15.25) });
        geometry.Figures.Add(triangle);
        RoundedBar(geometry, previous ? 3 : 14, 4, 3, 12, 0.75);
    }

    private static PathFigure Figure(double x, double y) => new() { StartPoint = new Point(x, y), IsClosed = true, IsFilled = true };
    private static void Line(PathFigure figure, double x, double y) => figure.Segments.Add(new LineSegment { Point = new Point(x, y) });
    private static void Curve(PathFigure figure, double ax, double ay, double bx, double by, double x, double y) =>
        figure.Segments.Add(new BezierSegment { Point1 = new Point(ax, ay), Point2 = new Point(bx, by), Point3 = new Point(x, y) });
    private static void RoundedBar(PathGeometry geometry, double x, double y, double width, double height, double radius)
    {
        const double tangent = 0.5522847498307936;
        double r = radius, c = r * tangent, right = x + width, bottom = y + height;
        var bar = Figure(x + r, y);
        Line(bar, right - r, y); Curve(bar, right - r + c, y, right, y + r - c, right, y + r);
        Line(bar, right, bottom - r); Curve(bar, right, bottom - r + c, right - r + c, bottom, right - r, bottom);
        Line(bar, x + r, bottom); Curve(bar, x + r - c, bottom, x, bottom - r + c, x, bottom - r);
        Line(bar, x, y + r); Curve(bar, x, y + r - c, x + r - c, y, x + r, y);
        geometry.Figures.Add(bar);
    }
}
