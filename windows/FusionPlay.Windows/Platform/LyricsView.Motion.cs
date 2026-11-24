using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using FusionPlay.Core;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Windows.Foundation;

namespace FusionPlay.Windows.Platform;

public sealed partial class LyricsView
{
    private const int ResizeQuietMilliseconds = 180;
    private const int AnchorRequestMilliseconds = 64;
    private readonly DispatcherQueueTimer resizeQuietTimer, followMotionTimer;
    private readonly Dictionary<LyricsRowPresenter, Visual> followRows = [];
    private bool followRowsNeedLayout;
    private CompositionPropertySet? followClock, followScroll;
    private ReadingAnchor? readingAnchor, resizeAnchor;
    private ReadingPosition? incomingReadingPosition;
    private (int Revision, LyricsRowItem Item, bool ExplicitRequest)? pendingFollowRealization;
    private bool nativeViewportResize, viewportReflow, followAfterReflow, restoreQueued, realizeAnchorRequested;
    private (double Target, long Started)? requestedAnchorOffset;
    private bool correctingAnchor, retryFinalAnchor, resizePaddingHeld, restoringIncomingPosition;
    private bool allowFollowMotion;
    private LyricsFollowMotion? followMotion;
    private double? heldResizeBodySize;

    private readonly record struct ReadingAnchor(LyricsRowItem Item, double Top);
    internal readonly record struct ReadingPosition(LyricsDocument Document, int Index, double Top, long BrowseUntil);

    internal bool InteractiveResize { get; private set; }
    internal string? FollowCompositorFailure { get; private set; }
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
        if (incomingReadingPosition != null) ClearReadingAnchor();
        ++followRevision;
        StopFollowMotion();
    }

    internal ReadingPosition? CaptureReadingPosition()
    {
        if (disposed || WindowSizing.ScreenReaderActive) return null;
        if (incomingReadingPosition is { } incoming) return incoming;
        if (!PresentationLoaded || !connected || !document.HasLyrics) return null;
        if ((resizeAnchor ?? CaptureReadingAnchor()) is not { } anchor) return null;
        double top = anchor.Top;
        if (resizeAnchor == null && scroller != null && followMotion is { } motion)
        {
            long now = Stopwatch.GetTimestamp();
            top += scroller.VerticalOffset - motion.ScrollOffset(now);
        }
        long browseUntil = browsing ? browsingDeadline : 0;
        return new(document, anchor.Item.Index, top, browseUntil);
    }

    internal void ReceiveReadingPosition(ReadingPosition position)
    {
        if (disposed || !connected || WindowSizing.ScreenReaderActive || !ReferenceEquals(document, position.Document)
            || position.Index < 0 || position.Index >= items.Length) return;
        ClearReadingAnchor();
        incomingReadingPosition = position;
        pendingFollowRealization = null;
        followAfterReflow = false;
        resizeQuietTimer.Stop();
        ++followRevision;
    }

    private void BeginIncomingReadingPosition()
    {
        if (restoringIncomingPosition || incomingReadingPosition is not { } position || !PresentationLoaded || scroller == null) return;
        if (WindowSizing.ScreenReaderActive)
        {
            incomingReadingPosition = null;
            return;
        }

        restoringIncomingPosition = viewportReflow = true;
        resizeAnchor = new(items[position.Index], position.Top);
        followAfterReflow = false;
        UpdateRowTransitions();
        StopFollowMotion();

        browsingTimer.Stop();
        long remaining = position.BrowseUntil - Stopwatch.GetTimestamp();
        browsing = remaining > 0;
        if (browsing)
        {
            browsingDeadline = position.BrowseUntil;
            browsingTimer.Interval = TimeSpan.FromSeconds(Math.Max(.001, remaining / (double)Stopwatch.Frequency));
            browsingTimer.Start();
        }
        if (!nativeViewportResize) RestartResizeQuietTimer();
    }

    internal void BeginViewportResize()
    {
        if (disposed || nativeViewportResize) return;
        if (!viewportReflow && PresentationLoaded)
        {
            resizeAnchor = WindowSizing.ScreenReaderActive ? null : CaptureReadingAnchor();
            if (resizeAnchor is { } anchor && scroller != null && followMotion is { } motion)
                resizeAnchor = anchor with { Top = anchor.Top + scroller.VerticalOffset - motion.ScrollOffset(Stopwatch.GetTimestamp()) };
        }
        StopFollowMotion(keepReadingPosition: true);
        nativeViewportResize = true;
        resizePaddingHeld = PresentationLoaded;
        resizeQuietTimer.Stop();
        UpdateRowTransitions();
        ++followRevision;
        StopFollowMotion();
    }

    internal void EndViewportResize()
    {
        if (!nativeViewportResize) return;
        if (PresentationLoaded && UpdateViewportPadding()) BeginReflow();
        nativeViewportResize = resizePaddingHeld = false;
        if (viewportReflow)
        {
            RestartResizeQuietTimer();
            QueueReadingAnchorRestore();
        }
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
            UpdateRowTransitions();
            ++followRevision;
            StopFollowMotion();
        }
        if (!nativeViewportResize) RestartResizeQuietTimer();
    }

    private void RestartResizeQuietTimer()
    {
        retryFinalAnchor = false;
        resizeQuietTimer.Stop();
        resizeQuietTimer.Interval = TimeSpan.FromMilliseconds(ResizeQuietMilliseconds);
        resizeQuietTimer.Start();
    }

    private void ResizeQuietElapsed(DispatcherQueueTimer sender, object args)
    {
        if (nativeViewportResize || !viewportReflow) return;
        RestoreReadingAnchor();
        if (!retryFinalAnchor && (requestedAnchorOffset != null || realizeAnchorRequested))
        {
            // The last native offset or realization can finish a dispatcher turn
            // after geometry has stopped changing. Bound the extra wait.
            retryFinalAnchor = true;
            resizeQuietTimer.Interval = TimeSpan.FromMilliseconds(32);
            resizeQuietTimer.Start();
            return;
        }
        FinishViewportReflow();
    }

    private void FinishViewportReflow()
    {
        bool follow = followAfterReflow;
        viewportReflow = followAfterReflow = false;
        UpdateRowTransitions();
        ClearReadingAnchor(preserveIncoming: !restoringIncomingPosition);
        RememberReadingAnchor();
        if (follow) ScheduleFollow(animated: true);
    }

    private void ReadingLayoutUpdated(object? sender, object args)
    {
        BeginIncomingReadingPosition();
        ResumeRealizedFollow();
        if (followRowsNeedLayout && followMotion != null) AttachFollowRows();
        // The narrow and wide views can trade places during the same drag. Pin
        // the newly visible view once its own containers have been arranged.
        if (nativeViewportResize && resizeAnchor == null && !WindowSizing.ScreenReaderActive)
            resizeAnchor = CaptureReadingAnchor();
        // The row has its new arranged height now. Correct its offset in
        // this layout turn before the deferred resize fallback can run.
        if (viewportReflow) RestoreReadingAnchor();
        else if (!nativeViewportResize && followMotion == null) RememberReadingAnchor();
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
        if (correctingAnchor || resizeAnchor is not { } anchor || scroller == null || !PresentationLoaded || WindowSizing.ScreenReaderActive) return;
        double current = scroller.VerticalOffset;
        if (requestedAnchorOffset is { } request)
        {
            // ChangeView can publish a newer offset after another size sample.
            // Wait for it rather than targeting a second stale scroll offset.
            if (Math.Abs(current - request.Target) > .5
                && Stopwatch.GetElapsedTime(request.Started).TotalMilliseconds < AnchorRequestMilliseconds) return;
            requestedAnchorOffset = null;
        }
        if (!TryReadingBounds(anchor.Item, out double top, out _))
        {
            if (realizeAnchorRequested || anchor.Item.Index >= items.Length || !ReferenceEquals(items[anchor.Item.Index], anchor.Item)) return;
            realizeAnchorRequested = true;
            list.ScrollIntoView(anchor.Item, ScrollIntoViewAlignment.Leading);
            return;
        }

        realizeAnchorRequested = false;
        double target = LyricsViewport.AnchorOffset(current, top, anchor.Top, scroller.ScrollableHeight);
        if (Math.Abs(target - current) <= .5) return;
        requestedAnchorOffset = (target, Stopwatch.GetTimestamp());
        correctingAnchor = true;
        try
        {
            if (!scroller.ChangeView(null, target, null, disableAnimation: true)) requestedAnchorOffset = null;
        }
        catch (Exception error) when (error is ArgumentException or COMException or ObjectDisposedException)
        {
            requestedAnchorOffset = null;
        }
        finally { correctingAnchor = false; }
    }

    private void AnchorViewChanged(bool intermediate)
    {
        if (!viewportReflow || resizeAnchor == null || scroller == null) return;
        if (requestedAnchorOffset is { } request && (!intermediate || Math.Abs(scroller.VerticalOffset - request.Target) <= .5))
            requestedAnchorOffset = null;
        QueueReadingAnchorRestore();
    }

    private void ClearReadingAnchor(bool preserveIncoming = false)
    {
        readingAnchor = resizeAnchor = null;
        requestedAnchorOffset = null;
        realizeAnchorRequested = false;
        restoringIncomingPosition = false;
        if (!preserveIncoming) incomingReadingPosition = null;
    }

    private void ResetViewportMotion()
    {
        resizeQuietTimer.Stop();
        nativeViewportResize = !disposed && InteractiveResize;
        viewportReflow = followAfterReflow = resizePaddingHeld = false;
        if (!disposed) UpdateRowTransitions();
        pendingFollowRealization = null;
        ClearReadingAnchor(preserveIncoming: !disposed);
        StopFollowMotion();
    }

    private bool StartFollowMotion(double targetOffset)
    {
        if (scroller == null) return false;
        FollowCompositorFailure = null;
        long now = Stopwatch.GetTimestamp();
        double nativeOffset = scroller.VerticalOffset;
        var previous = followMotion;
        double startOffset = previous?.ScrollOffset(now) ?? nativeOffset;
        // The ListView retains a limited realization cache. Longer jumps use
        // native scrolling so it can bring the intervening containers on screen.
        if (Math.Abs(targetOffset - startOffset) > ViewportHeight * .5
            || Math.Abs(targetOffset - nativeOffset) > ViewportHeight * .5)
        {
            FollowCompositorFailure = $"outside_cache:{targetOffset - startOffset:G4}/{ViewportHeight:G4}";
            return false;
        }

        double span = preferences.LyricsStaggerEnabled ? preferences.LyricsStaggerMilliseconds : 0;
        var motion = new LyricsFollowMotion(now, startOffset, targetOffset, preferences.LyricsFollowDurationMilliseconds, span);
        try
        {
            var compositor = ElementCompositionPreview.GetElementVisual(this).Compositor;
            followScroll ??= ElementCompositionPreview.GetScrollViewerManipulationPropertySet(scroller);
            followClock ??= compositor.CreatePropertySet();
            if (previous != null)
            {
                followClock.StopAnimation("Elapsed");
                followClock.StopAnimation("Progress");
            }
            followClock.InsertScalar("Elapsed", 0);
            followClock.InsertScalar("Progress", 0);
            followClock.InsertScalar("Start", (float)startOffset);
            followClock.InsertScalar("Target", (float)targetOffset);
            int direction = Math.Sign(targetOffset - startOffset);
            followClock.InsertScalar("Direction", direction);
            followClock.InsertScalar("Lag", (float)(direction * LyricsFollowMotion.MaxLag));

            followMotion = motion;
            AttachFollowRows(previous, now, nativeOffset - startOffset, restarting: true);
            if (followRows.Count == 0 || !scroller.ChangeView(null, targetOffset, null, disableAnimation: true))
            {
                FollowCompositorFailure ??= followRows.Count == 0 ? "no_rows" : "native_scroll_rejected";
                StopFollowMotion();
                return false;
            }

            using var elapsed = compositor.CreateScalarKeyFrameAnimation();
            using var linear = compositor.CreateLinearEasingFunction();
            elapsed.Duration = TimeSpan.FromMilliseconds(motion.TotalDuration);
            elapsed.InsertKeyFrame(0, 0);
            elapsed.InsertKeyFrame(1, (float)(motion.TotalDuration / motion.Duration), linear);
            elapsed.StopBehavior = AnimationStopBehavior.SetToFinalValue;
            using var progress = compositor.CreateScalarKeyFrameAnimation();
            using var ease = compositor.CreateCubicBezierEasingFunction(new(1f / 3, 0), new(2f / 3, 1));
            progress.Duration = elapsed.Duration;
            progress.InsertKeyFrame(0, 0);
            progress.InsertKeyFrame((float)(motion.Duration / motion.TotalDuration), 1, ease);
            if (motion.Duration < motion.TotalDuration) progress.InsertKeyFrame(1, 1, linear);
            progress.StopBehavior = AnimationStopBehavior.SetToFinalValue;
            followClock.StartAnimation("Elapsed", elapsed);
            followClock.StartAnimation("Progress", progress);
            if (!followMotionTimer.IsRunning) followMotionTimer.Start();
            return true;
        }
        catch (Exception error) when (error is COMException or ArgumentException or ObjectDisposedException)
        {
            FollowCompositorFailure = $"motion:{error.HResult:X8}:{error.Message}";
            StopFollowMotion();
            return false;
        }
    }

    private static string SmoothStep(string t) => $"({t} * {t} * (3 - 2 * {t}))";
    private static readonly string RowProgress = SmoothStep("Clamp(clock.Elapsed - delay, 0, 1)");
    private const string CarriedLag = "(carry * (1 - clock.Progress))";
    private static readonly string FollowTranslation = "Vector3(0, "
        + "-Lerp(clock.Start, clock.Target, clock.Progress) - scroll.Translation.Y"
        + $" + {CarriedLag} + clock.Lag * (clock.Progress - {RowProgress})"
        + $" * (1 - Max(0, clock.Direction * {CarriedLag}) / {LyricsFollowMotion.MaxLag:0}), 0)";

    private void AttachFollowRows(LyricsFollowMotion? previous = null, long now = 0, double offset = 0, bool restarting = false)
    {
        followRowsNeedLayout = false;
        if (followMotion is not { } motion || followClock == null || followScroll == null) return;
        if (!restarting && scroller != null)
            offset = scroller.VerticalOffset - motion.ScrollOffset(Stopwatch.GetTimestamp());
        foreach (var row in realized)
        {
            bool tracked = followRows.TryGetValue(row, out var visual);
            if (!restarting && tracked) continue;
            if (row.Item is not { } item || !TryReadingBounds(item, out double top, out double height))
            {
                ResetRowMotion(row);
                followRowsNeedLayout = true;
                continue;
            }
            double middle = top + offset + height * .5;
            float carry = tracked ? previous?.RowOffset(now, item.Index, middle, ViewportHeight) ?? 0 : 0;
            motion.CaptureRank(item.Index, middle, ViewportHeight, carry);
            try
            {
                if (visual == null)
                {
                    ElementCompositionPreview.SetIsTranslationEnabled(row, true);
                    visual = ElementCompositionPreview.GetElementVisual(row);
                }
                // Compensate for the *presented* native offset, including the
                // delay between ChangeView and the next compositor commit.
                using var expression = visual.Compositor.CreateExpressionAnimation(FollowTranslation);
                expression.SetReferenceParameter("clock", followClock);
                expression.SetReferenceParameter("scroll", followScroll);
                expression.SetScalarParameter("delay", (float)(motion.RowDelay(item.Index) / motion.Duration));
                expression.SetScalarParameter("carry", carry);
                visual.Properties.StartAnimation("Translation", expression);
                followRows[row] = visual;
            }
            catch (Exception error) when (error is COMException or ArgumentException or ObjectDisposedException)
            {
                FollowCompositorFailure = $"row:{error.HResult:X8}:{error.Message}";
                ResetRowMotion(row);
            }
        }
    }

    private void FollowMotionTick(DispatcherQueueTimer sender, object args)
    {
        if (!CanAnimateFollow || !settings.AnimationsEnabled || followMotion?.IsComplete(Stopwatch.GetTimestamp()) != false)
            StopFollowMotion();
        else QueueEdges();
    }

    internal double FollowRowOffset(LyricsRowPresenter row, int index, double middle)
    {
        if (followMotion is not { } motion || scroller == null || !followRows.ContainsKey(row)) return 0;
        long now = Stopwatch.GetTimestamp();
        return scroller.VerticalOffset - motion.ScrollOffset(now) + motion.RowOffset(now, index, middle, ViewportHeight);
    }

    private void ResetRowMotion(LyricsRowPresenter row)
    {
        if (!followRows.Remove(row, out var visual)) return;
        try
        {
            visual.Properties.StopAnimation("Translation");
            visual.Properties.InsertVector3("Translation", Vector3.Zero);
        }
        catch (Exception error) when (error is COMException or ObjectDisposedException) { }
    }

    private void StopFollowMotion(bool keepReadingPosition = false)
    {
        if (followMotion is not { } motion) return;
        followMotionTimer.Stop();
        followMotion = null;
        followRowsNeedLayout = false;
        if (keepReadingPosition && scroller != null)
        {
            double position = Math.Clamp(motion.ScrollOffset(Stopwatch.GetTimestamp()), 0, scroller.ScrollableHeight);
            try { scroller.ChangeView(null, position, null, disableAnimation: true); }
            catch (Exception error) when (error is COMException or ArgumentException or ObjectDisposedException) { }
        }
        foreach (var row in followRows.Keys.ToArray()) ResetRowMotion(row);
        try
        {
            followClock?.StopAnimation("Elapsed");
            followClock?.StopAnimation("Progress");
        }
        catch (Exception error) when (error is COMException or ArgumentException or ObjectDisposedException) { }
        QueueEdges();
    }
}
