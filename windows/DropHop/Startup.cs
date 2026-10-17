using System;
using System.IO;
using Microsoft.Win32;

namespace DropHop;

/// <summary>"Start with Windows": a per-user entry in the Run key. No admin rights needed.</summary>
public static class AutoStart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "DropHop";

    private static string Marker => Path.Combine(ShelfStore.Root, "startup-configured");

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) != null;
            }
            catch { return false; }
        }
    }

    public static void Set(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (key == null) return;
            if (on)
            {
                var exe = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exe)) key.SetValue(ValueName, "\"" + exe + "\"");
            }
            else key.DeleteValue(ValueName, false);
        }
        catch { }
    }

    /// <summary>
    /// First launch with this feature: switch it on, once. After that the user's choice (tray menu) wins.
    /// If it is on, the entry is rewritten each launch so it keeps pointing at the exe even if you moved it.
    /// </summary>
    public static void Prepare()
    {
        try
        {
            if (!File.Exists(Marker))
            {
                Set(true);
                File.WriteAllText(Marker, "1");
            }
            else if (IsEnabled) Set(true);
        }
        catch { }
    }
}
