using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace FusionPlay.Windows.Platform;

/// <summary>Keeps the native player fill anchored at the left edge when its value decreases.</summary>
public sealed class PlayerProgressBar : ProgressBar
{
    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        if (GetTemplateChild("LayoutRoot") is not FrameworkElement root) return;
        foreach (var group in VisualStateManager.GetVisualStateGroups(root))
        {
            if (group.Name != "CommonStates") continue;
            foreach (var transition in group.Transitions)
            {
                if ((transition.From == "Updating" && transition.To == "Determinate") ||
                    (transition.From == "UpdatingError" && transition.To == "Error"))
                {
                    // The base template can already have entered its initial
                    // value state. Stop only this matching transition first.
                    transition.Storyboard?.Stop();
                    RemoveIndicatorReposition(transition.Storyboard);
                }
            }
        }
    }

    private static void RemoveIndicatorReposition(Storyboard? storyboard)
    {
        if (storyboard == null) return;
        for (int index = storyboard.Children.Count - 1; index >= 0; index--)
        {
            var child = storyboard.Children[index];
            if (child is RepositionThemeAnimation { TargetName: "DeterminateProgressBarIndicator" })
                storyboard.Children.RemoveAt(index);
            else if (child is Storyboard nested) RemoveIndicatorReposition(nested);
        }
    }
}
