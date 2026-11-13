using FusionPlay.Core;
using FusionPlay.Windows.Platform;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FusionPlay.Windows;

internal sealed class FontSettingsPanel : StackPanel, IDisposable
{
    private sealed record FamilyChoice(string Name, string Label, int[] Weights);
    private sealed record WeightChoice(int Weight, string Label);
    private sealed record RenderingChoice(string Key, string Label);
    private readonly UiPreferencesStore preferences;
    private readonly Func<Func<UiPreferences, UiPreferences>, bool> update;
    private readonly ComboBox family = new() { DisplayMemberPath = "Label", SelectedValuePath = "Name", IsTextSearchEnabled = true, MaxDropDownHeight = 320, HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = false };
    private readonly ComboBox weight = new() { DisplayMemberPath = "Label", SelectedValuePath = "Weight", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox rendering = new() { DisplayMemberPath = "Label", SelectedValuePath = "Key", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock description = new() { FontSize = 13, Opacity = 0.85, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock availability = new() { FontSize = 13, TextWrapping = TextWrapping.Wrap };
    private readonly PlayerText preview = new() { Text = "FusionPlay · 让音乐，连接此刻 0123456789", FontSize = 16, MaxLines = 2, TextWrapping = TextWrapping.Wrap };
    private readonly Button reset = new() { HorizontalAlignment = HorizontalAlignment.Left };
    private InstalledFontFamily[] fonts = [];
    private bool refreshing, disposed, fontLoadFailed;
    private string choicesKey = "";
    internal Task FontLoading { get; }
    internal ComboBox FamilySelector => family;
    internal ComboBox WeightSelector => weight;
    internal ComboBox RenderingSelector => rendering;

    public FontSettingsPanel(UiPreferencesStore store, Func<Func<UiPreferences, UiPreferences>, bool> save)
    {
        preferences = store; update = save; Spacing = 12;
        var selectors = new Grid { ColumnSpacing = 12 };
        selectors.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
        selectors.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        selectors.Children.Add(family); Grid.SetColumn(weight, 1); selectors.Children.Add(weight);
        Children.Add(selectors); Children.Add(description); Children.Add(availability);
        Children.Add(rendering); Children.Add(preview); Children.Add(reset);
        family.SelectionChanged += (_, _) =>
        {
            if (refreshing || family.SelectedItem is not FamilyChoice selected) return;
            update(p => p with { UiFontFamily = selected.Name, UiFontWeight = FontSelection.NearestWeight(selected.Weights, p.UiFontWeight) });
        };
        weight.SelectionChanged += (_, _) =>
        {
            if (!refreshing && weight.SelectedItem is WeightChoice selected) update(p => p with { UiFontWeight = selected.Weight });
        };
        rendering.SelectionChanged += (_, _) =>
        {
            if (!refreshing && rendering.SelectedItem is RenderingChoice selected) update(p => p with { PlayerTextRendering = selected.Key });
        };
        reset.Click += (_, _) => update(p => p with { UiFontFamily = "", UiFontWeight = 400, PlayerTextRendering = "enhanced" });
        Loaded += (_, _) => UiTypography.Apply(this, preferences.Value, force: true);
        Localize(); FontLoading = LoadFonts();
    }
    private async Task LoadFonts()
    {
        try { fonts = await Task.Run(NativeTypography.GetFamilies); }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ArgumentException)
        { fontLoadFailed = true; }
        if (disposed) return;
        family.IsEnabled = true; choicesKey = ""; Refresh();
    }
    public void Localize()
    {
        family.Header = L.Text("界面字体"); weight.Header = L.Text("字重"); rendering.Header = L.Text("播放器文字效果");
        description.Text = L.Text("按字族选择已安装字体；标题自动使用同字族较粗的字重。可在字体列表中键入名称定位。");
        reset.Content = L.Text("恢复默认字体与文字效果"); choicesKey = ""; Refresh();
    }
    public void Refresh()
    {
        if (disposed) return;
        refreshing = true;
        try
        {
            var value = preferences.Value;
            string key = L.Language + ":" + value.UiFontFamily;
            if (choicesKey != key)
            {
                var choices = new List<FamilyChoice> { new("", L.Text("跟随系统字体"), UiTypography.Resolve("").Weights) };
                choices.AddRange(fonts.OrderBy(f => f.Label, StringComparer.CurrentCultureIgnoreCase).Select(f => new FamilyChoice(f.Name, f.Label, f.Weights)));
                if (value.UiFontFamily.Length > 0 && !choices.Any(f => f.Name.Equals(value.UiFontFamily, StringComparison.OrdinalIgnoreCase)))
                    choices.Add(new(value.UiFontFamily, value.UiFontFamily + " · " + L.Text("未安装"), [value.UiFontWeight]));
                family.ItemsSource = choices;
                rendering.ItemsSource = new[] { new RenderingChoice("enhanced", L.Text("柔和")), new RenderingChoice("system", L.Text("系统默认")) };
                choicesKey = key;
            }
            var families = (List<FamilyChoice>)family.ItemsSource;
            var chosen = families.First(f => f.Name.Equals(value.UiFontFamily, StringComparison.OrdinalIgnoreCase));
            family.SelectedItem = chosen;
            var weights = chosen.Weights.Select(number => new WeightChoice(number, WeightLabel(number))).ToArray();
            weight.ItemsSource = weights;
            weight.SelectedItem = weights.First(w => w.Weight == FontSelection.NearestWeight(chosen.Weights, value.UiFontWeight));
            rendering.SelectedItem = ((RenderingChoice[])rendering.ItemsSource).First(r => r.Key == value.PlayerTextRendering);
            bool missing = value.UiFontFamily.Length > 0 && fonts.Length > 0 && !fonts.Any(f => f.Name.Equals(value.UiFontFamily, StringComparison.OrdinalIgnoreCase));
            availability.Text = fontLoadFailed ? L.Text("无法读取字体列表，当前使用系统字体。") : missing ? L.Text("此字体未安装，当前使用系统字体；已保留原来的选择。") : "";
            availability.Visibility = availability.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            UiTypography.Apply(this, value);
        }
        finally { refreshing = false; }
    }
    private static string WeightLabel(int number)
    {
        string name = number switch { 100 => "极细", 200 => "特细", 300 => "细体", 350 => "半细", 400 => "常规", 500 => "中等", 600 => "半粗", 700 => "粗体", 800 => "特粗", 900 => "黑体", 950 => "超黑", _ => "" };
        return name.Length > 0 ? L.Text(name) + " (" + number + ")" : number.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }
    public void Dispose() => disposed = true;
}
