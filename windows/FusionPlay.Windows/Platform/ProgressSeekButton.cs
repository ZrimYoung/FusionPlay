using FusionPlay.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace FusionPlay.Windows.Platform;

/// <summary>Previews a captured timeline position and requests a source seek on release.</summary>
public sealed class ProgressSeekButton : Button
{
    private readonly record struct PointerSeek(uint Id, ReceiverSnapshot Source, SeekRequest Request);
    private PointerSeek? pointerSeek;
    private Pointer? capturedPointer;
    public Func<ReceiverSnapshot>? Snapshot { get; set; }
    public event Action<SeekRequest>? SeekRequested;
    internal event Action? PointerPreviewChanged;
    internal ulong? PointerPreviewPositionMs => pointerSeek?.Request.PositionMs;
    internal bool PointerSeekActive => pointerSeek != null;

    public ProgressSeekButton()
    {
        IsEnabledChanged += (_, _) => { if (!IsEnabled) CancelPointer(); };
        Unloaded += (_, _) => CancelPointer();
    }
    protected override void OnPointerPressed(PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(this);
        bool allowed = AllowsPointer(args.Pointer.PointerDeviceType, point.Properties.IsLeftButtonPressed, point.Properties.IsRightButtonPressed, point.Properties.IsMiddleButtonPressed);
        if (!allowed && !PointerSeekActive) { base.OnPointerPressed(args); return; }
        args.Handled = true;
        if (BeginPointer(args.Pointer.PointerId, point.Position.X, ActualWidth, allowed, args.Pointer))
            Focus(FocusState.Pointer);
    }
    protected override void OnPointerMoved(PointerRoutedEventArgs args)
    {
        if (pointerSeek?.Id != args.Pointer.PointerId) { base.OnPointerMoved(args); return; }
        args.Handled = true;
        var point = args.GetCurrentPoint(this);
        if (args.Pointer.PointerDeviceType == PointerDeviceType.Mouse && (point.Properties.IsRightButtonPressed || point.Properties.IsMiddleButtonPressed))
            CancelPointer();
        else
            MovePointer(args.Pointer.PointerId, point.Position.X, ActualWidth);
    }
    protected override void OnPointerReleased(PointerRoutedEventArgs args)
    {
        if (pointerSeek?.Id != args.Pointer.PointerId) { base.OnPointerReleased(args); return; }
        args.Handled = true;
        ReleasePointer(args.Pointer.PointerId, args.GetCurrentPoint(this).Position.X, ActualWidth);
    }
    protected override void OnPointerCanceled(PointerRoutedEventArgs args)
    {
        if (pointerSeek?.Id == args.Pointer.PointerId) CancelPointer();
        base.OnPointerCanceled(args);
    }
    protected override void OnPointerCaptureLost(PointerRoutedEventArgs args)
    {
        if (pointerSeek?.Id == args.Pointer.PointerId) CancelPointer();
        base.OnPointerCaptureLost(args);
    }
    protected override void OnKeyDown(KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape && PointerSeekActive)
        {
            CancelPointer();
            args.Handled = true;
            return;
        }
        if (args.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End)
        { _ = SeekFromKey(args.Key); args.Handled = true; return; }
        // Space/Enter must not reuse the last pointer's location. Direction keys
        // and the automation range pattern provide explicit accessible targets.
        if (args.Key is VirtualKey.Space or VirtualKey.Enter) { args.Handled = true; return; }
        base.OnKeyDown(args);
    }
    protected override void OnKeyUp(KeyRoutedEventArgs args)
    {
        if (args.Key is VirtualKey.Space or VirtualKey.Enter) { args.Handled = true; return; }
        base.OnKeyUp(args);
    }
    internal static bool AllowsPointer(PointerDeviceType device, bool left, bool right, bool middle) =>
        device == PointerDeviceType.Touch || device == PointerDeviceType.Mouse && left && !right && !middle;

    internal bool BeginPointer(uint id, double x, double width, bool allowed, Pointer? pointer = null)
    {
        if (PointerSeekActive) { CancelPointer(); return false; }
        if (!allowed || !IsEnabled) return false;
        var state = Snapshot?.Invoke();
        if (state == null || Seeking.AtPoint(state, x, width) is not { } request ||
            pointer != null && !CapturePointer(pointer)) return false;
        capturedPointer = pointer;
        pointerSeek = new(id, state, request);
        PointerPreviewChanged?.Invoke();
        return true;
    }

    internal bool MovePointer(uint id, double x, double width)
    {
        if (pointerSeek is not { } seek || seek.Id != id) return false;
        if (!IsEnabled || !MatchesCurrent(Snapshot?.Invoke(), seek.Request, seek.Source.DurationMs) ||
            Seeking.AtPoint(seek.Source, x, width) is not { } request)
        {
            CancelPointer();
            return false;
        }
        if (request.PositionMs != seek.Request.PositionMs)
        {
            pointerSeek = seek with { Request = request };
            PointerPreviewChanged?.Invoke();
        }
        return true;
    }

    internal bool ReleasePointer(uint id, double x, double width)
        => MovePointer(id, x, width) && CommitPointer();

    private bool CommitPointer()
    {
        if (pointerSeek is not { } seek) return false;
        ClearPointer();
        // The controller can start its pending seek feedback before the view
        // returns from this release to the regular playback timeline.
        try { return Dispatch(seek.Request, seek.Source.DurationMs); }
        finally { PointerPreviewChanged?.Invoke(); }
    }

    internal void CancelPointer()
    {
        if (!PointerSeekActive) return;
        ClearPointer();
        PointerPreviewChanged?.Invoke();
    }

    private void ClearPointer()
    {
        var pointer = capturedPointer;
        capturedPointer = null;
        pointerSeek = null;
        if (pointer != null) ReleasePointerCapture(pointer);
    }

    public void RefreshState()
    {
        var state = Snapshot?.Invoke();
        if (pointerSeek is { } seek && (!IsEnabled || !MatchesCurrent(state, seek.Request, seek.Source.DurationMs))) CancelPointer();
        if (FrameworkElementAutomationPeer.FromElement(this) is ProgressSeekPeer peer) peer.Refresh();
    }

    private static bool MatchesCurrent(ReceiverSnapshot? state, SeekRequest request, ulong? duration)
        => state != null && (duration == null || state.DurationMs == duration) && Seeking.MatchesCurrent(state, request);

    private bool Dispatch(SeekRequest request, ulong? duration = null)
    {
        if (!IsEnabled || !MatchesCurrent(Snapshot?.Invoke(), request, duration)) return false;
        SeekRequested?.Invoke(request); return true;
    }
    internal bool SeekFromKey(VirtualKey key)
    {
        CancelPointer();
        var state = Snapshot?.Invoke();
        if (!IsEnabled || state == null || !Seeking.CanSeek(state)) return false;
        ulong duration = state.DurationMs!.Value, current = Math.Min(state.PositionMs!.Value, duration);
        ulong target = key switch
        {
            VirtualKey.Home => 0,
            VirtualKey.End => duration,
            VirtualKey.Left or VirtualKey.Down => current > 10_000 ? current - 10_000 : 0,
            VirtualKey.Right or VirtualKey.Up => current + Math.Min(10_000UL, duration - current),
            _ => current
        };
        if (key is not (VirtualKey.Home or VirtualKey.End or VirtualKey.Left or VirtualKey.Down or VirtualKey.Right or VirtualKey.Up)) return false;
        return Dispatch(new SeekRequest(target, state.TrackId, state.Title));
    }
    private bool SeekPercent(double percent)
    {
        CancelPointer();
        var state = Snapshot?.Invoke();
        if (!IsEnabled || state == null || !double.IsFinite(percent) || percent < 0 || percent > 100) return false;
        var request = Seeking.AtFraction(state, percent / 100);
        return request != null && Dispatch(request);
    }
    private double Percent
    {
        get
        {
            var state = Snapshot?.Invoke();
            return state?.DurationMs is > 0 && state.PositionMs != null ? Math.Clamp(100.0 * state.PositionMs.Value / state.DurationMs.Value, 0, 100) : 0;
        }
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new ProgressSeekPeer(this);
    private sealed class ProgressSeekPeer(ProgressSeekButton owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        private double? reportedValue;
        protected override string GetClassNameCore() => nameof(ProgressSeekButton);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Slider;
        protected override object GetPatternCore(PatternInterface pattern) => pattern == PatternInterface.RangeValue ? this : base.GetPatternCore(pattern);
        public bool IsReadOnly => !owner.IsEnabled || owner.Snapshot?.Invoke() is not { } state || !Seeking.CanSeek(state);
        public double Minimum => 0;
        public double Maximum => 100;
        public double Value => owner.Percent;
        public double SmallChange
        {
            get { var duration = owner.Snapshot?.Invoke()?.DurationMs; return duration is > 0 ? Math.Min(100, 1_000_000.0 / duration.Value) : 1; }
        }
        public double LargeChange => 10;
        public void SetValue(double value)
        {
            if (!double.IsFinite(value) || value < Minimum || value > Maximum) throw new ArgumentOutOfRangeException(nameof(value));
            if (!owner.SeekPercent(value)) throw new InvalidOperationException("Seeking is unavailable.");
        }
        internal void Refresh()
        {
            double value = Value;
            if (reportedValue is { } old && old != value) RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, old, value);
            reportedValue = value;
        }
    }
}
