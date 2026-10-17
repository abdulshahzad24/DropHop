using System;
using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace DropHop;

/// <summary>Height → CornerRadius(height / 2): a real capsule, not an oval.</summary>
public sealed class HalfConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is double h && h > 0 ? new CornerRadius(h / 2) : new CornerRadius(0);

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
