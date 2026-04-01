using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace KeyValueWin.Converters;

// ── NullToVisibilityConverter ─────────────────────────────────────────────────
// ConverterParameter: "isnull" → Visible when null; "notnull" / "notempty" → Visible when not null/empty

public class NullToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type t, object? param, CultureInfo c)
    {
        var mode  = param as string ?? "notnull";
        var empty = value is null || (value is string s && string.IsNullOrWhiteSpace(s));
        return mode == "isnull"
            ? (empty ? Visibility.Visible : Visibility.Collapsed)
            : (empty ? Visibility.Collapsed : Visibility.Visible);
    }
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

// ── BoolToVisibilityConverter ─────────────────────────────────────────────────

public class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

// ── InvertVisibilityConverter ─────────────────────────────────────────────────

public class InvertVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

// ── InvertBoolConverter ───────────────────────────────────────────────────────

public class InvertBoolConverter : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c) =>
        value is false;
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

// ── BoolToFavoriteStarConverter ───────────────────────────────────────────────

public class BoolToFavoriteStarConverter : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c) =>
        value is true ? "⭐  Favorited" : "☆  Favorite";
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

// ── IntToVisibilityConverter ──────────────────────────────────────────────────
// ConverterParameter: "empty" → Visible when 0; "notempty" → Visible when >0

public class IntToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type t, object? param, CultureInfo c)
    {
        var count = value is int i ? i : 0;
        var mode  = param as string ?? "notempty";
        return mode == "empty"
            ? (count == 0 ? Visibility.Visible : Visibility.Collapsed)
            : (count >  0 ? Visibility.Visible : Visibility.Collapsed);
    }
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}
