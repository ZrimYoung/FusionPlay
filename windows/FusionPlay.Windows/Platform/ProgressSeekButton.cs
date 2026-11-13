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

/// <summary>A native click target over a read-only progress visual; it never changes local playback position.</summary>
public sealed class ProgressSeekButton : Button
{
    private SeekRequest? pointerRequest;
    private uint? pointerId;
    private long pointerVersion;
    public Func<ReceiverSnapshot>? Snapshot { get; set; }
    public event Action<SeekRequest>? SeekRequested;
    public ProgressSeekButton()
    {
        ClickMode = ClickMode.Release;
        Click += (_, _) => CommitPointerClick();
        IsEnabledChanged += (_, _) => { if (!IsEnabled) CancelPointer(); };
        Unloaded += (_, _) => CancelPointer();
    }
    protected override void OnPointerPressed(PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(this);
        bool allowed = AllowsPointer(args.Pointer.PointerDeviceType, point.Properties.IsLeftButtonPressed, point.Properties.IsRightButtonPressed, point.Properties.IsMiddleButtonPressed);
        BeginPointer(args.Pointer.PointerId, point.Position.X, ActualWidth, allowed);
        base.OnPointerPressed(args);
    }
    protected override void OnPointerReleased(PointerRoutedEventArgs args)
    {
        // ButtonBase raises Click from its normal release processing. Only a
        // pointer press that started here can have prepared a request for it.
        base.OnPointerReleased(args);
        if (pointerId == args.Pointer.PointerId) QueuePointerCancellation();
    }
    protected override void OnPointerCanceled(PointerRoutedEventArgs args) { CancelPointer(); base.OnPointerCanceled(args); }
    protected override void OnPointerCaptureLost(PointerRoutedEventArgs args)
    {
        base.OnPointerCaptureLost(args);
        // ButtonBase can release its capture immediately before raising Click.
        // Keep this request for the rest of that event route, then discard it.
        QueuePointerCancellation();
    }
    protected override void OnKeyDown(KeyRoutedEventArgs args)
    {
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
    internal void BeginPointer(uint id, double x, double width, bool allowed)
    {
        if (pointerId != null) { CancelPointer(); return; }
        ++pointerVersion;
        pointerId = id;
        var state = Snapshot?.Invoke();
        pointerRequest = allowed && IsEnabled && state != null ? Seeking.AtPoint(state, x, width) : null;
    }
    internal bool CommitPointerClick()
    {
        var request = pointerRequest;
        CancelPointer();
        return request != null && Dispatch(request);
    }
    internal void CancelPointer() { ++pointerVersion; pointerRequest = null; pointerId = null; }
    private void QueuePointerCancellation()
    {
        long request = pointerVersion;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { if (request == pointerVersion) CancelPointer(); });
    }
    public void RefreshState()
    {
        var state = Snapshot?.Invoke();
        if (pointerRequest != null && (!IsEnabled || state == null || !Seeking.MatchesCurrent(state, pointerRequest))) CancelPointer();
        if (FrameworkElementAutomationPeer.FromElement(this) is ProgressSeekPeer peer) peer.Refresh();
    }
    private bool Dispatch(SeekRequest request)
    {
        var state = Snapshot?.Invoke();
        if (!IsEnabled || state == null || !Seeking.MatchesCurrent(state, request)) return false;
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
