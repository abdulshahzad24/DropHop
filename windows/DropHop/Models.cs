using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media;

namespace DropHop;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected void RaiseMany(params string[] names)
    {
        foreach (var n in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}

public sealed class ShelfGroup : Observable
{
    private string _name = "";
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get => _name; set => Set(ref _name, value); }
    public string? Link { get; set; }
    public DateTime? LinkExpiry { get; set; }

    [JsonIgnore]
    public bool LinkActive => Link != null && (LinkExpiry ?? DateTime.MaxValue) > DateTime.Now;
}

public sealed class ShelfItem : Observable
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public long Size { get; set; }
    public Guid? GroupId { get; set; }

    private string? _link;
    private DateTime? _linkExpiry;
    private bool _uploading;
    private string? _error;
    private string? _groupLabel;
    private ImageSource? _icon;

    public string? Link { get => _link; set { if (Set(ref _link, value)) RefreshState(); } }
    public DateTime? LinkExpiry { get => _linkExpiry; set { if (Set(ref _linkExpiry, value)) RefreshState(); } }

    // ---- runtime-only state (never saved) ----

    [JsonIgnore] public bool Uploading { get => _uploading; set { if (Set(ref _uploading, value)) RefreshState(); } }
    [JsonIgnore] public string? Error { get => _error; set { if (Set(ref _error, value)) RefreshState(); } }
    /// <summary>Group name shown in the subtitle while the "All" chip is selected.</summary>
    [JsonIgnore] public string? GroupLabel { get => _groupLabel; set { if (Set(ref _groupLabel, value)) RefreshState(); } }
    [JsonIgnore] public ImageSource? Icon { get => _icon; set => Set(ref _icon, value); }

    [JsonIgnore] public bool LinkActive => Link != null && (LinkExpiry ?? DateTime.MaxValue) > DateTime.Now;

    [JsonIgnore]
    public string Subtitle
    {
        get
        {
            if (Uploading) return "Uploading… this can take a minute for big files";
            if (Error != null) return Error;
            if (LinkActive && Link != null) return Link;
            var s = Format.Bytes(Size);
            return GroupLabel != null ? s + " · " + GroupLabel : s;
        }
    }

    /// <summary>Errors and links are drawn in the accent colour, plain info is dimmed.</summary>
    [JsonIgnore] public bool SubtitleAccent => Uploading || Error != null || LinkActive;

    [JsonIgnore] public Visibility SpinnerVisibility => Uploading ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility CopyVisibility => !Uploading && LinkActive ? Visibility.Visible : Visibility.Collapsed;
    [JsonIgnore] public Visibility LinkMenuVisibility => !Uploading && !LinkActive ? Visibility.Visible : Visibility.Collapsed;

    public void RefreshState() =>
        RaiseMany(nameof(Subtitle), nameof(SubtitleAccent), nameof(LinkActive),
                  nameof(SpinnerVisibility), nameof(CopyVisibility), nameof(LinkMenuVisibility));
}

public sealed class ShelfManifest
{
    public List<ShelfItem> Items { get; set; } = new();
    public List<ShelfGroup> Groups { get; set; } = new();
}

public sealed class PairedDevice
{
    public string Name { get; set; } = "Phone";
    public string TokenHash { get; set; } = "";     // SHA-256 of the token; the token itself is never stored here
    public DateTime PairedAt { get; set; }
}

public static class Format
{
    /// <summary>Decimal units, like macOS "file" style (1 MB = 1,000,000 bytes).</summary>
    public static string Bytes(long n)
    {
        if (n < 1000) return n == 1 ? "1 byte" : n + " bytes";
        string[] units = { "KB", "MB", "GB", "TB" };
        double v = n;
        int i = -1;
        do { v /= 1000; i++; } while (v >= 1000 && i < units.Length - 1);
        return (v >= 100 ? v.ToString("0") : v.ToString("0.#")) + " " + units[i];
    }
}
