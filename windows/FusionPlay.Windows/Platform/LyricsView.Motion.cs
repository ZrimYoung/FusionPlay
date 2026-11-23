using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

public sealed partial class LyricsView
{
    private readonly DispatcherQueueTimer resizeQuietTimer, followMotionTimer;
    private readonly HashSet<LyricsRowPresenter> laggingRows = [];
    private ReadingAnchor? readingAnchor, resizeAnchor;
    private (int Revision, LyricsRowItem Item, bool ExplicitRequest)? pendingFollowRealization;
    private bool nativeViewportResize, viewportReflow, followAfterReflow, restoreQueued, realizeAnchorRequested;
    private (double Current, double Target)? requestedAnchorOffset;
    private bool allowFollowMotion;
    private LyricsFollowMotion? followMotion;
    private double? heldResizeBodySize;

    private readonly record struct ReadingAnchor(LyricsRowItem Item, double Top);

    internal bool InteractiveResize { get; private set; }
    private bool ViewportResizePending => nativeViewportResize || viewportReflow;
    private bool CanAnimateFollow => PresentationLoaded && MotionEnabled && allowFollowMotion && connected && !loading
        && !browsing && !ViewportResizePending && !InteractiveResize && !WindowSizing.ScreenReaderActive;

    internal void SetInteractiveResize(bool active)
    {
        if (disposed || InteractiveResize == active) return;
        InteractiveResize = active;
        CancelGlyphQueue();
        glyphTimer.Interval = TimeSpan.FromMilliseconds(active ? 48 : 16);
        if (active)
        {
            // Keep XAML measurement live. Published glyphs stay at their native
            // size, and the resize timer handles effects and newly visible rows.
            heldResizeBodySize = PresentationLoaded ? ResponsiveBodySize : null;
            foreach (var row in realized.ToArray()) row.BeginInteractiveResize();
            QueueEdges();
        }
        else
        {
            heldResizeBodySize = null;
            RefreshRows(style: true);
        }
    }

    internal void CancelFollowAnimation()
    {
        allowFollowMotion = false;
        ++followRevision;
        StopFollowMotion();
    }

    internal void BeginViewportResize()
    {
        if (disposed || nativeViewportResize || !PresentationLoaded) return;
        if (!viewportReflow)
            resizeAnchor = WindowSizing.ScreenReaderActive ? null : CaptureReadingAnchor();
        nativeViewportResize = true;
        resizeQuietTimer.Stop();
        ++followRevision;
        StopFollowMotion();
    }

    internal void EndViewportResize()
    {
        if (!nativeViewportResize) return;
        nativeViewportResize = false;
        if (viewportReflow) RestartResizeQuietTimer();
        else FinishViewportReflow();
    }

    private void BeginReflow()
    {
        if (!document.HasLyrics || WindowSizing.ScreenReaderActive) return;
        if (!viewportReflow)
        {
            if (!nativeViewportResize) resizeAnchor = readingAnchor;
            viewportReflow = true;
            // Old viewports may not have realized an anchor yet.
            followAfterReflow |= resizeAnchor == null;
            ++followRevision;
            StopFollowMotion();
        }
        if (!nativeViewportResize) RestartResizeQuietTimer();
    }

    private void RestartResizeQuietTimer()
    {
        resizeQuietTimer.Stop();
        resizeQuietTimer.Start();
    }

    private void ResizeQuietElapsed(DispatcherQueueTimer sender, object args)
    {
        if (nativeViewportResize || !viewportReflow) return;
        RestoreReadingAnchor();
        FinishViewportReflow();
    }

    private void FinishViewportReflow()
    {
        bool follow = followAfterReflow;
        viewportReflow = followAfterReflow = false;
        ClearReadingAnchor();
        RememberReadingAnchor();
        if (follow) ScheduleFollow(animated: true);
    }

    private void ReadingLayoutUpdated(object? sender, object args)
    {
        ResumeRealizedFollow();
        // The row has its new arranged height now. Correct its offset in
        // this layout turn before the deferred resize fallback can run.
        if (viewportReflow) RestoreReadingAnchor();
        else if (!nativeViewportResize) RememberReadingAnchor();
    }

    private void ResumeRealizedFollow()
    {
        if (pendingFollowRealization is not { } pending) return;
        if (pending.Revision != followRevision || ViewportResizePending || !PresentationLoaded)
        {
            pendingFollowRealization = null;
            return;
        }
        // ScrollIntoView starts asynchronous realization of an off-screen row.
        // A dispatcher callback alone can run before its container is arranged.
        if (!TryReadingBounds(pending.Item, out _, out _)) return;
        pendingFollowRealization = null;
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
            Follow(pending.Revision, animated: false, explicitRequest: pending.ExplicitRequest, realize: false));
    }

    private void RememberReadingAnchor() => readingAnchor = CaptureReadingAnchor();

    private ReadingAnchor? CaptureReadingAnchor()
    {
        if (!PresentationLoaded || scroller == null || !document.HasLyrics) return null;
        if (document.IsTimed && !browsing && activeIndex >= 0 && activeIndex < items.Length
            && TryReadingBounds(items[activeIndex], out double activeTop, out double activeHeight)
            && LyricsViewport.IntersectsViewport(activeTop, activeHeight, ViewportHeight, bleed: 0))
            return new(items[activeIndex], activeTop);

        double readingPoint = browsing || !document.IsTimed ? 0 : ViewportHeight * .32;
        double closest = double.PositiveInfinity;
        ReadingAnchor? anchor = null;
        foreach (var row in realized)
        {
            if (row.Item is not { } item || !TryReadingBounds(item, out double top, out double height)
                || !LyricsViewport.IntersectsViewport(top, height, ViewportHeight, bleed: 0)) continue;
            double distance = Math.Abs(readingPoint - Math.Clamp(readingPoint, top, top + height));
            if (distance >= closest) continue;
            closest = distance;
            anchor = new(item, top);
        }
        return anchor;
    }

    private bool TryReadingBounds(LyricsRowItem item, out double top, out double height)
    {
        top = height = 0;
        if (item.Index >= items.Length || !ReferenceEquals(items[item.Index], item)
            || list.ContainerFromIndex(item.Index) is not FrameworkElement container || container.ActualHeight <= 0) return false;
        try
        {
            top = container.TransformToVisual(this).TransformPoint(new Point()).Y;
            height = container.ActualHeight;
            return double.IsFinite(top) && double.IsFinite(height);
        }
        catch (ArgumentException) { return false; }
    }

    private void QueueReadingAnchorRestore()
    {
        if (restoreQueued || resizeAnchor == null || !PresentationLoaded) return;
        restoreQueued = DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            restoreQueued = false;
            if (viewportReflow) RestoreReadingAnchor();
        });
    }

    private void RestoreReadingAnchor()
    {
        if (resizeAnchor is not { } anchor || scroller == null || !PresentationLoaded || WindowSizing.ScreenReaderActive) return;
        if (!TryReadingBounds(anchor.Item, out double top, out _))
        {
            if (realizeAnchorRequested || anchor.Item.Index >= items.Length || !ReferenceEquals(items[anchor.Item.Index], anchor.Item)) return;
            realizeAnchorRequested = true;
            list.ScrollIntoView(anchor.Item, ScrollIntoViewAlignment.Leading);
            return;
        }

        realizeAnchorRequested = false;
        double current = scroller.VerticalOffset;
        double target = LyricsViewport.AnchorOffset(current, top, anchor.Top, scroller.ScrollableHeight);
        if (Math.Abs(target - current) <= .5)
        {
            requestedAnchorOffset = null;
            return;
        }
        // ChangeView is asynchronous. A layout notification for the same
        // geometry must not enqueue the same correction again.
        if (requestedAnchorOffset is { } request && Math.Abs(request.Current - current) <= .1
            && Math.Abs(request.Target - target) <= .1) return;
        requestedAnchorOffset = (current, target);
        scroller.ChangeView(null, target, null, disableAnimation: true);
    }

    private void ClearReadingAnchor()
    {
        readingAnchor = resizeAnchor = null;
        requestedAnchorOffset = null;
        realizeAnchorRequested = false;
    }

    private void ResetViewportMotion()
    {
        resizeQuietTimer.Stop();
        nativeViewportResize = viewportReflow = followAfterReflow = false;
        pendingFollowRealization = null;
        ClearReadingAnchor();
        StopFollowMotion();
    }

    private void StartFollowMotion(double startOffset, double targetOffset)
    {
        double span = preferences.LyricsStaggerEnabled ? preferences.LyricsStaggerMilliseconds : 0;
        var motion = new LyricsFollowMotion(Stopwatch.GetTimestamp(), startOffset, targetOffset,
            preferences.LyricsFollowDurationMilliseconds, span);
        foreach (var row in realized)
        {
            if (!TryVisibleRow(row, out int index, out double middle)) continue;
            // A new wave begins from the translation actually applied to this row.
            float presented = laggingRows.Contains(row) ? row.Translation.Y : 0;
            motion.CaptureRank(index, middle, ViewportHeight, presented);
        }
        followMotion = motion;
        if (!followMotionTimer.IsRunning) followMotionTimer.Start();
    }

    private bool TryVisibleRow(LyricsRowPresenter row, out int index, out double middle)
    {
        index = 0; middle = 0;
        if (row.Item is not { } item || !TryReadingBounds(item, out double top, out double height)
            || !LyricsViewport.IntersectsViewport(top, height, ViewportHeight, bleed: 0)) return false;
        index = item.Index;
        middle = top + height * .5;
        return true;
    }

    private void FollowMotionTick(DispatcherQueueTimer sender, object args)
    {
        if (!CanAnimateFollow || scroller == null || followMotion is not { } motion)
        {
            StopFollowMotion();
            return;
        }
        try
        {
            if (!settings.AnimationsEnabled)
            {
                StopFollowMotion();
                ScheduleFollow(animated: false);
                return;
            }
            long now = Stopwatch.GetTimestamp();
            double current = scroller.VerticalOffset;
            double desired = Math.Min(motion.ScrollOffset(now), scroller.ScrollableHeight);
            if (Math.Abs(desired - current) > .25) scroller.ChangeView(null, desired, null, disableAnimation: true);
            if (motion.IsComplete(now))
            {
                StopFollowMotion();
                return;
            }

            foreach (var row in realized)
            {
                if (!TryVisibleRow(row, out int index, out double middle))
                {
                    ResetRowMotion(row);
                    continue;
                }
                float offset = motion.RowOffset(now, index, middle, ViewportHeight);
                if (offset == 0) ResetRowMotion(row);
                else
                {
                    row.Translation = new Vector3(0, offset, 0);
                    laggingRows.Add(row);
                }
            }
            if (laggingRows.Count > 0) QueueEdges();
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException)
        {
            StopFollowMotion();
            ScheduleFollow(animated: false);
        }
    }

    private void ResetRowMotion(LyricsRowPresenter row)
    {
        if (laggingRows.Remove(row)) row.Translation = Vector3.Zero;
    }

    private void StopFollowMotion()
    {
        if (followMotion == null && laggingRows.Count == 0) return;
        followMotionTimer.Stop();
        followMotion = null;
        foreach (var row in laggingRows) row.Translation = Vector3.Zero;
        if (laggingRows.Count > 0) QueueEdges();
        laggingRows.Clear();
    }
}
