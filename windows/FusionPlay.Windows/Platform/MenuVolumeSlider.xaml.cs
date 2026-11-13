using Microsoft.UI.Xaml.Controls;

namespace FusionPlay.Windows.Platform;

/// <summary>Compact tray appearance around a native Slider, with its full input and UIA behavior.</summary>
public sealed partial class MenuVolumeSlider : UserControl
{
    /// <summary>The native control for shared volume gestures, ValueChanged, and model feedback.</summary>
    public Slider Slider => NativeSlider;

    public MenuVolumeSlider() => InitializeComponent();
}
