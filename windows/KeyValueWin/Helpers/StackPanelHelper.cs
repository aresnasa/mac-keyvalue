using System.Windows;
using System.Windows.Controls;

namespace KeyValueWin.Helpers;

/// <summary>
/// Attached property that adds spacing between StackPanel children.
/// Drop-in replacement for the WPF 9+ native StackPanel.Spacing —
/// required for cross-platform (macOS) builds via EnableWindowsTargeting.
/// Usage:  h:StackPanelHelper.Spacing="8"
/// </summary>
public static class StackPanelHelper
{
    public static readonly DependencyProperty SpacingProperty =
        DependencyProperty.RegisterAttached(
            "Spacing",
            typeof(double),
            typeof(StackPanelHelper),
            new PropertyMetadata(0.0, OnSpacingChanged));

    public static double GetSpacing(DependencyObject obj) =>
        (double)obj.GetValue(SpacingProperty);

    public static void SetSpacing(DependencyObject obj, double value) =>
        obj.SetValue(SpacingProperty, value);

    private static void OnSpacingChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not StackPanel panel) return;
        ApplySpacing(panel);
        panel.Loaded -= Panel_Loaded;
        panel.Loaded += Panel_Loaded;
    }

    private static void Panel_Loaded(object sender, RoutedEventArgs e) =>
        ApplySpacing((StackPanel)sender);

    private static void ApplySpacing(StackPanel panel)
    {
        var gap = GetSpacing(panel);
        var horiz = panel.Orientation == Orientation.Horizontal;

        for (int i = 0; i < panel.Children.Count; i++)
        {
            if (panel.Children[i] is not FrameworkElement el) continue;
            var m = el.Margin;
            el.Margin = horiz
                ? new Thickness(i > 0 ? gap : m.Left, m.Top, m.Right, m.Bottom)
                : new Thickness(m.Left, i > 0 ? gap : m.Top, m.Right, m.Bottom);
        }
    }
}
