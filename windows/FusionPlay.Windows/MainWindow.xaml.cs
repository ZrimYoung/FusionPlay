using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.System;

namespace FusionPlay.Windows;

public sealed partial class MainWindow : Window
{
    private readonly ReceiverController model;
    private readonly Backdrop miniBackdrop, loadingBackdrop;
    private readonly IDisposable squareSizing;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer hideTimer, coverTimer;
    private BitmapImage? lastArtwork;
    private bool pointerInside, focusInside, controlsShown = true, captionShown = true, closed, enlarged;
    private double restoreSide = 420;
    private string preferenceError = "";
    public bool AllowClose { get; set; }
    public event Action? ClosingToTray;
    public void RefreshAppearance() => Render();
    public MainWindow(ReceiverController controller, Action openSettings)
    {
        model = controller;
        InitializeComponent();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = true; presenter.IsMaximizable = false;
        }
        WindowSizing.Apply(this, 420, 420, 260, 260);
        squareSizing = WindowSizing.FixedSquare(this, IsInteractive, NativeHoverChanged);
        WindowSizing.ResizeContent(this, 420, 420);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Closing += (_, args) =>
        {
            if (AllowClose) return;
            args.Cancel = true; AppWindow.Hide(); ClosingToTray?.Invoke();
        };
        miniBackdrop = new Backdrop(MiniBackdropLayer, progressive: true);
        loadingBackdrop = new Backdrop(LoadingArtworkLayer, blur: 12);
        miniBackdrop.Changed += Render; loadingBackdrop.Changed += Render;
        miniBackdrop.Failed += LogBackdropFailure; loadingBackdrop.Failed += LogBackdropFailure;
        hideTimer = DispatcherQueue.CreateTimer(); hideTimer.IsRepeating = false;
        hideTimer.Interval = TimeSpan.FromMilliseconds(400);
        hideTimer.Tick += (_, _) => { if (!pointerInside && !focusInside) { ShowControls(false); ShowCaption(false); } };
        coverTimer = DispatcherQueue.CreateTimer(); coverTimer.IsRepeating = false;
        coverTimer.Interval = TimeSpan.FromMilliseconds(400);
        coverTimer.Tick += (_, _) => MiniPreviousCover.Source = null;
        var shortcut = new KeyboardAccelerator { Key = (VirtualKey)0xBC, Modifiers = VirtualKeyModifiers.Control };
        shortcut.Invoked += (_, args) => { openSettings(); args.Handled = true; };
        RootGrid.KeyboardAccelerators.Add(shortcut);
        RootGrid.KeyDown += (_, args) => { if (args.Key == VirtualKey.Tab) { focusInside = true; ShowControls(true); ShowCaption(true); } };
        RootGrid.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => focusInside = false), true);
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated)
            { pointerInside = focusInside = false; ShowCaption(false); ScheduleHide(); }
        };
        model.Changed += Render;
        Closed += (_, _) =>
        {
            closed = true; model.Changed -= Render;
            miniBackdrop.Changed -= Render; loadingBackdrop.Changed -= Render;
            miniBackdrop.Failed -= LogBackdropFailure; loadingBackdrop.Failed -= LogBackdropFailure;
            hideTimer.Stop(); coverTimer.Stop(); squareSizing.Dispose(); miniBackdrop.Dispose(); loadingBackdrop.Dispose();
        };
        Render(); ScheduleHide();
    }
    private void LogBackdropFailure(string code) => model.Store.EventDiagnostic("backdrop:" + code);
    public void RequestMiniPlayer() { ShowControls(true); ShowCaption(pointerInside); ScheduleHide(); }
    internal static void AttachVolume(Slider slider, ReceiverController model)
    {
        slider.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => model.BeginVolume()), true);
        slider.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => _ = model.CommitVolumeAsync()), true);
        slider.AddHandler(UIElement.PointerCanceledEvent, new PointerEventHandler((_, _) => _ = model.CommitVolumeAsync()), true);
        slider.AddHandler(UIElement.PointerCaptureLostEvent, new PointerEventHandler((_, _) => _ = model.CommitVolumeAsync()), true);
        slider.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, args) => { if (args.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End) model.BeginVolume(); }), true);
        slider.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler((_, args) => { if (args.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End) _ = model.CommitVolumeAsync(); }), true);
        slider.LostFocus += (_, _) => _ = model.CommitVolumeAsync();
    }
    private void Render()
    {
        if (closed || miniBackdrop == null) return;
        var state = model.State; var preferences = model.Preferences.Value;
        MiniTitle.Text = state.Title.Length > 0 ? state.Title : L.Text(state.HasMedia ? "正在接收音乐" : "让音乐，连接此刻");
        string metadata = string.Join(" · ", new[] { state.Artist, state.Album }.Where(x => !string.IsNullOrWhiteSpace(x)));
        MiniArtist.Text = metadata.Length > 0 ? metadata : state.HasMedia ? L.Text("来自手机妙播") : L.Text("在手机妙播中选择") + " " + model.Settings.Name;
        UpdateCover();
        MiniPlaceholder.Visibility = model.Artwork == null ? Visibility.Visible : Visibility.Collapsed;
        bool effects = miniBackdrop.SetArtwork(model.ArtworkBytes);
        loadingBackdrop.SetArtwork(model.ArtworkLoading ? model.ArtworkBytes : null);
        Brush solid = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        MiniControls.Background = effects ? null : solid;
        MiniRoot.Background = effects ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 21, 33, 54)) : solid;
        MiniRoot.RequestedTheme = effects ? ElementTheme.Dark : ElementTheme.Default;
        foreach (var button in new[] { MinimizeButton, ZoomButton, CloseButton, PinButton })
            button.Background = effects ? new SolidColorBrush(global::Windows.UI.Color.FromArgb(100, 20, 20, 20)) : solid;
        MiniShade.Visibility = effects ? Visibility.Visible : Visibility.Collapsed;
        MiniPreviousButton.IsEnabled = MiniPlayButton.IsEnabled = MiniNextButton.IsEnabled = model.CanControl;
        PlaybackIcons.Update(MiniPreviousIcon, PlaybackCommand.Previous);
        PlaybackIcons.Update(MiniNextIcon, PlaybackCommand.Next);
        PlaybackIcons.Update(MiniPlayIcon, state.Phase == ReceiverPhase.Playing ? PlaybackCommand.Pause : PlaybackCommand.Play);
        Label(MiniPlayButton, L.Text(state.Phase == ReceiverPhase.Playing ? "暂停" : "播放"));
        Label(MiniPreviousButton, L.Text("上一曲")); Label(MiniNextButton, L.Text("下一曲"));
        Label(MinimizeButton, L.Text("最小化", "Minimize")); Label(ZoomButton, L.Text("缩放窗口", "Resize Window")); Label(CloseButton, L.Text("关闭窗口", "Close Window"));
        Label(PinButton, L.Text(preferences.Pinned ? "取消置顶" : "窗口置顶"));
        PinIcon.Opacity = preferences.Pinned ? 1 : 0.6;
        PinButton.Visibility = preferences.ShowPinButton ? Visibility.Visible : Visibility.Collapsed;
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.IsAlwaysOnTop = preferences.Pinned;
        MiniTransport.Visibility = preferences.ShowTransport && !model.MigrationRequired ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(MiniCover, L.Text("专辑封面"));
        AutomationProperties.SetName(MiniProgress, L.Text("播放进度，只读"));
        bool progress = state.HasMedia && state.DurationMs is > 0 && state.PositionMs != null;
        MiniProgressPanel.Visibility = progress ? Visibility.Visible : Visibility.Collapsed;
        if (progress)
        {
            MiniProgress.Value = Math.Clamp(100.0 * state.PositionMs!.Value / state.DurationMs!.Value, 0, 100);
            MiniPosition.Text = FormatTime(state.PositionMs.Value); MiniDuration.Text = FormatTime(state.DurationMs.Value);
        }
        string error = preferenceError.Length > 0 ? preferenceError : model.Error;
        MigrationButton.Content = L.Text("为此电脑建立独立身份");
        MigrationButton.Visibility = model.MigrationRequired ? Visibility.Visible : Visibility.Collapsed;
        MiniStatus.Text = L.Text(error.Length > 0 ? error : model.ControlMessage);
        MiniStatus.Visibility = MiniStatus.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (preferences.AlwaysShowControls || WindowSizing.ScreenReaderActive || focusInside || error.Length > 0 || model.MigrationRequired) ShowControls(true);
        else if (!pointerInside) ScheduleHide();
        ShowCaption(pointerInside); UpdateBlurCoverage();
    }
    private static void Label(Button button, string label)
    { ToolTipService.SetToolTip(button, label); AutomationProperties.SetName(button, label); }
    private void UpdateCover()
    {
        if (ReferenceEquals(lastArtwork, model.Artwork)) return;
        coverTimer.Stop(); MiniPreviousCover.Source = lastArtwork; MiniCover.Source = model.Artwork;
        bool animate = lastArtwork != null && Backdrop.AnimationsEnabled;
        Fade(MiniPreviousCover, animate ? 1 : 0, 0, animate ? .35 : 0);
        Fade(MiniCover, animate ? 0 : 1, 1, animate ? .35 : 0);
        lastArtwork = model.Artwork;
        if (animate) coverTimer.Start(); else MiniPreviousCover.Source = null;
    }
    private void Root_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateBlurCoverage();
    private void MiniControls_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateBlurCoverage();
    private void UpdateBlurCoverage() => miniBackdrop?.SetCoverage(RootGrid.ActualHeight > 0 ? Math.Clamp(MiniControls.ActualHeight * 1.35 / RootGrid.ActualHeight, .1, 1) : .65);
    private void Root_PointerEntered(object sender, PointerRoutedEventArgs e) { pointerInside = true; hideTimer?.Stop(); ShowControls(true); ShowCaption(true); }
    private void Root_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(RootGrid).Position;
        if (point.X >= 0 && point.Y >= 0 && point.X < RootGrid.ActualWidth && point.Y < RootGrid.ActualHeight) return;
        pointerInside = false; ShowCaption(false); ScheduleHide();
    }
    private bool IsInteractive(double x, double y)
    {
        if (RootGrid.XamlRoot == null) return true;
        foreach (var element in VisualTreeHelper.FindElementsInHostCoordinates(new global::Windows.Foundation.Point(x, y), RootGrid))
        {
            DependencyObject? target = element;
            while (target != null && target != RootGrid)
            {
                if (target is Control { IsHitTestVisible: true } control && control is ButtonBase or Slider or TextBox) return true;
                target = VisualTreeHelper.GetParent(target);
            }
        }
        return false;
    }
    private void NativeHoverChanged(bool inside)
    {
        if (closed || pointerInside == inside) return;
        pointerInside = inside;
        if (inside) { hideTimer?.Stop(); ShowControls(true); ShowCaption(true); }
        else { ShowCaption(false); ScheduleHide(); }
    }
    private void Root_GotFocus(object sender, RoutedEventArgs e)
    {
        focusInside = RootGrid.XamlRoot != null && FocusManager.GetFocusedElement(RootGrid.XamlRoot) is Control { FocusState: FocusState.Keyboard };
        if (focusInside) { hideTimer?.Stop(); ShowControls(true); ShowCaption(true); }
    }
    private void Root_LostFocus(object sender, RoutedEventArgs e) => DispatcherQueue.TryEnqueue(() =>
    {
        if (closed || RootGrid.XamlRoot == null) return;
        var focused = FocusManager.GetFocusedElement(RootGrid.XamlRoot); var focus = focused as DependencyObject;
        while (focus != null && focus != RootGrid) focus = VisualTreeHelper.GetParent(focus);
        focusInside = focus == RootGrid && focused is Control { FocusState: FocusState.Keyboard };
        if (!focusInside) { ShowCaption(pointerInside); ScheduleHide(); }
    });
    private void ScheduleHide()
    {
        if (hideTimer == null || closed || pointerInside || focusInside) return;
        if (!hideTimer.IsRunning) hideTimer.Start();
    }
    private void ShowControls(bool visible)
    {
        if (MiniControls == null) return;
        visible |= model.Preferences.Value.AlwaysShowControls || WindowSizing.ScreenReaderActive || focusInside || model.Error.Length > 0 || preferenceError.Length > 0 || model.MigrationRequired;
        if (visible == controlsShown) return;
        controlsShown = visible;
        foreach (var element in new FrameworkElement[] { MiniControls, MiniBackdropLayer, MiniShade })
        { Fade(element, visible ? 0 : 1, visible ? 1 : 0, Backdrop.AnimationsEnabled ? visible ? .25 : .65 : 0); element.IsHitTestVisible = visible && element == MiniControls; }
    }
    private void ShowCaption(bool visible)
    {
        if (MiniActions == null) return;
        visible |= focusInside || WindowSizing.ScreenReaderActive;
        if (visible == captionShown) return;
        captionShown = visible;
        Fade(MiniActions, visible ? 0 : 1, visible ? 1 : 0, Backdrop.AnimationsEnabled ? visible ? .2 : .35 : 0);
        MiniActions.IsHitTestVisible = visible;
    }
    private static void Fade(FrameworkElement element, double from, double to, double seconds)
    {
        var visual = ElementCompositionPreview.GetElementVisual(element); visual.StopAnimation("Opacity");
        if (seconds == 0) { visual.Opacity = (float)to; return; }
        var animation = visual.Compositor.CreateScalarKeyFrameAnimation();
        animation.InsertKeyFrame(0, (float)from); animation.InsertKeyFrame(1, (float)to); animation.Duration = TimeSpan.FromSeconds(seconds);
        visual.StartAnimation("Opacity", animation); animation.Dispose();
    }
    private static string FormatTime(ulong milliseconds)
    { ulong seconds = milliseconds / 1000; return seconds >= 3600 ? $"{seconds / 3600}:{seconds / 60 % 60:00}:{seconds % 60:00}" : $"{seconds / 60}:{seconds % 60:00}"; }
    private void Minimize_Click(object sender, RoutedEventArgs e) { if (AppWindow.Presenter is OverlappedPresenter p) p.Minimize(); }
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void Zoom_Click(object sender, RoutedEventArgs e)
    {
        if (!enlarged) { restoreSide = Math.Max(260, RootGrid.ActualWidth); WindowSizing.ResizeContent(this, 100000, 100000); }
        else WindowSizing.ResizeContent(this, restoreSide, restoreSide);
        enlarged = !enlarged;
    }
    private void Pin_Click(object sender, RoutedEventArgs e)
    {
        try { model.Preferences.Update(model.Preferences.Value with { Pinned = !model.Preferences.Value.Pinned }); preferenceError = ""; }
        catch { preferenceError = L.Text("无法保存外观设置，请检查数据目录。"); }
        Render();
    }
    private async void Previous_Click(object sender, RoutedEventArgs e) => await model.ControlAsync(PlaybackCommand.Previous);
    private async void Next_Click(object sender, RoutedEventArgs e) => await model.ControlAsync(PlaybackCommand.Next);
    private async void Play_Click(object sender, RoutedEventArgs e) => await model.TogglePlaybackAsync();
    private async void Migration_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog { XamlRoot = RootGrid.XamlRoot, Title = L.Text("为此电脑建立独立身份"), Content = L.Text("将保留名称、音量等设置，并备份旧设备身份。此电脑会作为新的接收设备出现在手机上。"), PrimaryButtonText = L.Text("备份并建立"), CloseButtonText = L.Text("取消"), DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await model.MigrateAsync();
    }
}
