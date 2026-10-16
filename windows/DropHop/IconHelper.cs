using System;
using System.Drawing;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DropHop;

/// <summary>The same icon Explorer shows for a file (the Mac app uses NSWorkspace for this).</summary>
public static class IconHelper
{
    public static ImageSource? For(string path)
    {
        try
        {
            using Icon? icon = Icon.ExtractAssociatedIcon(path);
            if (icon == null) return null;
            var src = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty,
                                                          BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        catch
        {
            return null;
        }
    }
}
