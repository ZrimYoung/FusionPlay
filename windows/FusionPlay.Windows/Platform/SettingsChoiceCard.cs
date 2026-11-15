using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Markup;

namespace FusionPlay.Windows.Platform;

/// <summary>A compact preference tile with the native ToggleButton template, input and automation.</summary>
internal sealed class SettingsChoiceCard : ToggleButton
{
    private readonly TextBlock title = new() { FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
    private readonly TextBlock status = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
    private readonly FontIcon check = new() { Glyph = "\uE73E", FontSize = 14, Width = 16, Height = 22, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
    private string onText = "", offText = "";

    public SettingsChoiceCard(string glyph)
    {
        ArgumentNullException.ThrowIfNull(glyph);
        MinHeight = 92; MinWidth = 0; Padding = new Thickness(12); CornerRadius = new CornerRadius(12);
        HorizontalAlignment = HorizontalAlignment.Stretch;
        HorizontalContentAlignment = HorizontalAlignment.Stretch; VerticalContentAlignment = VerticalAlignment.Stretch;
        IsThreeState = false; UseSystemFocusVisuals = true; FocusVisualMargin = new Thickness(2);

        // Override only this tile's checked palette. Native visual states still
        // supply hover/press/disabled effects, focus and the background transition.
        Resources.ThemeDictionaries["Default"] = CheckedPalette("SystemAccentColorLight2");
        Resources.ThemeDictionaries["Light"] = CheckedPalette("SystemAccentColorDark1");
        Resources.ThemeDictionaries["HighContrast"] = HighContrastPalette();

        var content = new Grid { RowSpacing = 4, IsHitTestVisible = false };
        content.RowDefinitions.Add(new RowDefinition { Height = new GridLength(22) });
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var icon = new FontIcon { Glyph = glyph, FontFamily = UiTypography.SymbolFamily, FontSize = 22, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        check.FontFamily = UiTypography.SymbolFamily;
        content.Children.Add(icon); content.Children.Add(check);
        Grid.SetRow(title, 1); content.Children.Add(title);
        Grid.SetRow(status, 2); content.Children.Add(status);
        Content = content;
        foreach (var child in new FrameworkElement[] { icon, check, title, status })
            AutomationProperties.SetAccessibilityView(child, AccessibilityView.Raw);

        Checked += (_, _) => RefreshState(); Unchecked += (_, _) => RefreshState(); Indeterminate += (_, _) => RefreshState();
        Loaded += (_, _) => RefreshState();
        // ThemeResource values in the per-instance dictionaries update the
        // native template for light/dark/high contrast and system accent changes.
        ActualThemeChanged += (_, _) => RefreshState();
        RefreshState();
    }

    public void SetLabels(string title, string onText, string offText)
    {
        ArgumentNullException.ThrowIfNull(title); ArgumentNullException.ThrowIfNull(onText); ArgumentNullException.ThrowIfNull(offText);
        this.title.Text = title; this.onText = onText; this.offText = offText;
        AutomationProperties.SetName(this, title);
        RefreshState();
    }

    private void RefreshState()
    {
        bool selected = IsChecked == true;
        check.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        status.Text = selected ? onText : offText;
        AutomationProperties.SetHelpText(this, status.Text);
    }

    private static ResourceDictionary CheckedPalette(string accentColor) => (ResourceDictionary)XamlReader.Load($$"""
        <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
          <SolidColorBrush x:Key="ToggleButtonBackgroundChecked" Color="{ThemeResource {{accentColor}}}" Opacity="0.10"/>
          <SolidColorBrush x:Key="ToggleButtonBackgroundCheckedPointerOver" Color="{ThemeResource {{accentColor}}}" Opacity="0.15"/>
          <SolidColorBrush x:Key="ToggleButtonBackgroundCheckedPressed" Color="{ThemeResource {{accentColor}}}" Opacity="0.20"/>
          <SolidColorBrush x:Key="ToggleButtonBorderBrushChecked" Color="{ThemeResource {{accentColor}}}" Opacity="0.65"/>
          <SolidColorBrush x:Key="ToggleButtonBorderBrushCheckedPointerOver" Color="{ThemeResource {{accentColor}}}" Opacity="0.85"/>
          <SolidColorBrush x:Key="ToggleButtonBorderBrushCheckedPressed" Color="{ThemeResource {{accentColor}}}"/>
          <SolidColorBrush x:Key="ToggleButtonForegroundChecked" Color="{ThemeResource TextFillColorPrimary}"/>
          <SolidColorBrush x:Key="ToggleButtonForegroundCheckedPointerOver" Color="{ThemeResource TextFillColorPrimary}"/>
          <SolidColorBrush x:Key="ToggleButtonForegroundCheckedPressed" Color="{ThemeResource TextFillColorPrimary}"/>
        </ResourceDictionary>
        """);

    private static ResourceDictionary HighContrastPalette() => (ResourceDictionary)XamlReader.Load("""
        <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
          <SolidColorBrush x:Key="ToggleButtonBackgroundChecked" Color="{ThemeResource SystemColorHighlightColor}"/>
          <SolidColorBrush x:Key="ToggleButtonBackgroundCheckedPointerOver" Color="{ThemeResource SystemColorHighlightColor}"/>
          <SolidColorBrush x:Key="ToggleButtonBackgroundCheckedPressed" Color="{ThemeResource SystemColorHighlightColor}"/>
          <SolidColorBrush x:Key="ToggleButtonBorderBrushChecked" Color="{ThemeResource SystemColorHighlightTextColor}"/>
          <SolidColorBrush x:Key="ToggleButtonBorderBrushCheckedPointerOver" Color="{ThemeResource SystemColorHighlightTextColor}"/>
          <SolidColorBrush x:Key="ToggleButtonBorderBrushCheckedPressed" Color="{ThemeResource SystemColorHighlightTextColor}"/>
          <SolidColorBrush x:Key="ToggleButtonForegroundChecked" Color="{ThemeResource SystemColorHighlightTextColor}"/>
          <SolidColorBrush x:Key="ToggleButtonForegroundCheckedPointerOver" Color="{ThemeResource SystemColorHighlightTextColor}"/>
          <SolidColorBrush x:Key="ToggleButtonForegroundCheckedPressed" Color="{ThemeResource SystemColorHighlightTextColor}"/>
        </ResourceDictionary>
        """);
}
