using System.Runtime.InteropServices;
using FusionPlay.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;

namespace FusionPlay.Windows.Platform;

/// <summary>Fades between two unscaled marks inside the same centered player button.</summary>
public sealed class PlayPauseGlyph : Grid
{
    private const double IconSize = 20;
    private static readonly Duration FadeDuration = new(TimeSpan.FromMilliseconds(160));
    private bool? playing;
    private Storyboard? fade;

    internal PathIcon PlayMark { get; } = PlaybackIcons.Create(PlaybackCommand.Play, IconSize);
    internal PathIcon PauseMark { get; } = PlaybackIcons.Create(PlaybackCommand.Pause, IconSize);

    public PlayPauseGlyph()
    {
        // PathIcon draws the paths in their original 20-DIP coordinates.
        Width = Height = IconSize;
        IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(this, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(PlayMark, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(PauseMark, AccessibilityView.Raw);
        PauseMark.Opacity = 0;
        Children.Add(PlayMark);
        Children.Add(PauseMark);
        Unloaded += (_, _) => Settle();
    }

    internal void Update(bool isPlaying, bool allowAnimation)
    {
        bool changed = playing != isPlaying;
        if (!changed && fade == null) return;
        if (playing == null || !CanAnimate(allowAnimation))
        {
            playing = isPlaying;
            Settle();
            return;
        }
        if (!changed) return;

        // A rapid toggle continues from the effective opacity of both marks.
        double playOpacity = PlayMark.Opacity, pauseOpacity = PauseMark.Opacity;
        Stop();
        playing = isPlaying;
        double targetPause = isPlaying ? 1 : 0;
        if (Math.Abs(pauseOpacity - targetPause) < .001 && Math.Abs(playOpacity - (1 - targetPause)) < .001)
        {
            Settle();
            return;
        }

        fade = new Storyboard();
        fade.Children.Add(OpacityAnimation(PlayMark, playOpacity, 1 - targetPause));
        fade.Children.Add(OpacityAnimation(PauseMark, pauseOpacity, targetPause));
        fade.Completed += FadeCompleted;
        try { fade.Begin(); }
        catch (Exception error) when (error is COMException or InvalidOperationException) { Settle(); }
    }

    private bool CanAnimate(bool requested)
    {
        if (!requested || !IsLoaded || XamlRoot?.IsHostVisible != true || !Backdrop.AnimationsEnabled) return false;
        for (DependencyObject? node = this; node != null; node = VisualTreeHelper.GetParent(node))
        {
            if (node is UIElement element && (element.Visibility == Visibility.Collapsed || element.Opacity == 0)) return false;
        }
        return true;
    }

    private static DoubleAnimation OpacityAnimation(UIElement element, double from, double to)
    {
        var animation = new DoubleAnimation
        {
            From = from,
            To = to,
            Duration = FadeDuration,
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut }
        };
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, nameof(Opacity));
        return animation;
    }

    private void FadeCompleted(object? sender, object args)
    {
        if (ReferenceEquals(sender, fade)) Settle();
    }

    private void Stop()
    {
        if (fade is not { } previous) return;
        fade = null;
        previous.Completed -= FadeCompleted;
        previous.Stop();
    }

    private void Settle()
    {
        Stop();
        PauseMark.Opacity = playing == true ? 1 : 0;
        PlayMark.Opacity = 1 - PauseMark.Opacity;
    }
}
