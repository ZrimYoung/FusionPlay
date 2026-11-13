using System.Runtime.CompilerServices;
using FusionPlay.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FusionPlay.Windows.Platform;

internal static class UiTypography
{
    private sealed record Original(FontFamily Family, global::Windows.UI.Text.FontWeight Weight, bool Heading = false);
    private sealed class RootState { public string Key = ""; }
    private static readonly ConditionalWeakTable<DependencyObject, Original> Originals = new();
    private static readonly ConditionalWeakTable<FrameworkElement, RootState> Roots = new();
    private static string? resolvedKey;
    private static InstalledFontFamily? resolved;
    internal static FontFamily SymbolFamily => Application.Current.Resources.TryGetValue("SymbolThemeFontFamily", out object resource) && resource is FontFamily family
        ? family : new FontFamily("Segoe Fluent Icons");
    internal static InstalledFontFamily Resolve(string family)
    {
        if (resolvedKey == family && resolved != null) return resolved;
        try { resolved = (family.Length > 0 ? NativeTypography.FindFamily(family) : null) ?? NativeTypography.SystemFamily; }
        catch (System.Runtime.InteropServices.COMException) { resolved = new("Segoe UI", "Segoe UI", [400, 600, 700]); }
        resolvedKey = family;
        return resolved;
    }
    public static void Apply(FrameworkElement root, UiPreferences preferences, bool force = false)
    {
        var state = Roots.GetOrCreateValue(root);
        string key = preferences.UiFontFamily + ":" + preferences.UiFontWeight + ":" + preferences.PlayerTextRendering;
        if (!force && state.Key == key) return;
        var family = Resolve(preferences.UiFontFamily);
        FontFamily selected = new(family.Name);
        int weight = FontSelection.NearestWeight(family.Weights, preferences.UiFontWeight);
        var elements = new List<DependencyObject>();
        void Collect(DependencyObject element)
        {
            elements.Add(element);
            // FontIcon/SymbolIcon may contain private TextBlocks. Replacing
            // those overrides the icon font even if FontIcon.FontFamily is kept.
            if (element is IconElement) return;
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(element); i++) Collect(VisualTreeHelper.GetChild(element, i));
        }
        Collect(root);
        // Snapshot the entire tree before changing inherited properties, so
        // icon fonts and semantic heading weights cannot be captured incorrectly.
        foreach (var element in elements)
        {
            if (Originals.TryGetValue(element, out _)) continue;
            if (element is TextBlock text) Originals.Add(element, new(text.FontFamily, text.FontWeight, text.ReadLocalValue(TextBlock.FontWeightProperty) is global::Windows.UI.Text.FontWeight tw && tw.Weight >= 600));
            else if (element is Control control) Originals.Add(element, new(control.FontFamily, control.FontWeight, control.ReadLocalValue(Control.FontWeightProperty) is global::Windows.UI.Text.FontWeight cw && cw.Weight >= 600));
            else if (element is FontIcon icon) Originals.Add(element, new(icon.ReadLocalValue(FontIcon.FontFamilyProperty) is FontFamily explicitFamily ? explicitFamily : SymbolFamily, icon.FontWeight));
        }
        foreach (var element in elements)
        {
            if (!Originals.TryGetValue(element, out var original)) continue;
            if (element is FontIcon icon) { icon.FontFamily = original.Family; icon.FontWeight = original.Weight; continue; }
            // Keep diagnostic logs monospaced; user-interface text follows the selection.
            if (original.Family.Source == "Cascadia Mono") continue;
            var effective = new global::Windows.UI.Text.FontWeight { Weight = (ushort)(original.Heading ? FontSelection.HeadingWeight(family.Weights, weight) : weight) };
            if (element is PlayerText player) player.Enhanced = preferences.PlayerTextRendering == "enhanced";
            if (element is TextBlock text) { text.FontFamily = selected; text.FontWeight = effective; }
            else if (element is Control control) { control.FontFamily = selected; control.FontWeight = effective; }
        }
        state.Key = key;
    }
}
