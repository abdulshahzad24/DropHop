using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace DropHop;

public partial class ShelfWindow : Window
{
    private readonly ShelfStore _store;
    private readonly ICollectionView _view;

    private Guid? _selected;               // null = "All"
    private bool _renaming, _targeted, _draggingOut;
    private bool _changePending;

    private Point _dragStart;
    private ShelfItem? _dragItem;

    private static string SizeFile => Path.Combine(ShelfStore.Root, "window.json");

    public ShelfWindow(ShelfStore store)
    {
        InitializeComponent();
        _store = store;

        _view = CollectionViewSource.GetDefaultView(store.Items);
        _view.Filter = o => _selected == null || ((ShelfItem)o).GroupId == _selected;
        ItemsList.ItemsSource = _view;

        store.Changed += () =>
        {
            if (_changePending) return;
            _changePending = true;
            Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => { _changePending = false; Refresh(); }));
        };

        Closing += (_, e) =>
        {
            if (App.Quitting) return;
            e.Cancel = true;           // the shelf is only ever hidden, never closed
            HideShelf();
        };

        PickSize();
        Refresh();
    }

    private ShelfGroup? SelectedGroup => _selected == null ? null : _store.Groups.FirstOrDefault(g => g.Id == _selected);
    private int VisibleCount => _view.Cast<object>().Count();

    // =====================================================================
    //  Refresh: one place that brings every part of the UI up to date
    // =====================================================================

    private void Refresh()
    {
        if (_selected != null && _store.Groups.All(g => g.Id != _selected)) _selected = null;

        foreach (var item in _store.Items)
            item.GroupLabel = _selected == null ? _store.GroupName(item.GroupId) : null;
        _view.Refresh();

        int count = VisibleCount;
        TitleLabel.Text = SelectedGroup?.Name.ToUpperInvariant() ?? "ON THE SHELF";
        CountText.Text = count.ToString();
        CountLabel.Text = count == 1 ? "item" : "items";
        ClearBtn.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ListScroller.Visibility = count > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = count > 0 ? Visibility.Collapsed : Visibility.Visible;
        EmptyText.Text = SelectedGroup == null ? "Drop files here" : $"Drop files into {SelectedGroup.Name}";

        RebuildChips();
        UpdateGroupBar();
        UpdateOutline();
    }

    private void UpdateOutline()
    {
        bool empty = VisibleCount == 0;
        DropOutline.Stroke = _targeted ? (Brush)FindResource("Accent")
                           : empty ? (Brush)FindResource("Line") : Brushes.Transparent;
        DropOutline.Fill = _targeted ? (Brush)FindResource("AccentWash") : Brushes.Transparent;
        EmptyRing.Stroke = _targeted ? (Brush)FindResource("Accent") : (Brush)FindResource("Line");
        EmptyGlyph.Foreground = _targeted ? (Brush)FindResource("Accent") : new SolidColorBrush(Color.FromArgb(0xCC, 0xF3, 0xEE, 0xE6));
    }

    private void SetTargeted(bool on)
    {
        if (_targeted == on) return;
        _targeted = on;
        UpdateOutline();
    }

    // =====================================================================
    //  Chips
    // =====================================================================

    private void RebuildChips()
    {
        ChipsHost.Children.Clear();
        ChipsHost.Children.Add(MakeChip("All", null));
        foreach (var g in _store.Groups) ChipsHost.Children.Add(MakeChip(g.Name, g.Id));
    }

    private Button MakeChip(string title, Guid? group)
    {
        bool selected = _selected == group;
        var b = new Button
        {
            Style = (Style)FindResource("Pill"),
            Content = title.ToUpperInvariant(),
            Margin = new Thickness(0, 0, 6, 0),
            Padding = new Thickness(11, 6, 11, 6),
            Foreground = selected ? (Brush)FindResource("Ink") : new SolidColorBrush(Color.FromArgb(0xB3, 0xF3, 0xEE, 0xE6)),
            Background = selected ? (Brush)FindResource("Paper") : Brushes.Transparent,
            BorderBrush = selected ? Brushes.Transparent : (Brush)FindResource("Line"),
            AllowDrop = true,
            MaxWidth = 200,
        };
        b.Click += (_, _) =>
        {
            _selected = group;
            _renaming = false;
            Refresh();
        };
        // You can also drop files straight onto a chip to put them in that group.
        b.DragOver += (_, e) =>
        {
            e.Effects = !_draggingOut && e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
        };
        b.Drop += (_, e) =>
        {
            SetTargeted(false);
            AddDropped(e, group);
            e.Handled = true;
        };
        return b;
    }

    private void Add_Click(object sender, RoutedEventArgs e)
    {
        _renaming = false;
        NewGroupBox.Text = "";
        NewGroupPill.Visibility = Visibility.Visible;
        CancelAddBtn.Visibility = Visibility.Visible;
        AddBtn.Visibility = Visibility.Collapsed;
        UpdateGroupBar();
        Activate();
        NewGroupBox.Focus();
        ChipScroller.ScrollToRightEnd();
    }

    private void EndAdd()
    {
        NewGroupPill.Visibility = Visibility.Collapsed;
        CancelAddBtn.Visibility = Visibility.Collapsed;
        AddBtn.Visibility = Visibility.Visible;
    }

    private void CancelAdd_Click(object sender, RoutedEventArgs e) => EndAdd();

    private void NewGroupBox_TextChanged(object sender, TextChangedEventArgs e) =>
        NewGroupHint.Visibility = NewGroupBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    private void NewGroupBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { EndAdd(); e.Handled = true; }
        else if (e.Key == Key.Enter)
        {
            var name = NewGroupBox.Text.Trim();
            if (name.Length > 0) _selected = _store.AddGroup(name).Id;
            EndAdd();
            Refresh();
            e.Handled = true;
        }
    }

    private void ChipScroller_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        ChipScroller.ScrollToHorizontalOffset(ChipScroller.HorizontalOffset - e.Delta);
        e.Handled = true;
    }

    // =====================================================================
    //  Group bar: copy all, one link for all, rename, delete
    // =====================================================================

    private void UpdateGroupBar()
    {
        var g = SelectedGroup;
        GroupBar.Visibility = g == null ? Visibility.Collapsed : Visibility.Visible;
        if (g == null) { _renaming = false; return; }

        int n = VisibleCount;
        bool uploading = _store.IsUploading(g.Id);
        bool linkActive = g.LinkActive && g.Link != null;
        _store.GroupErrors.TryGetValue(g.Id, out var err);

        RenamePanel.Visibility = _renaming ? Visibility.Visible : Visibility.Collapsed;
        GroupInfo.Visibility = GroupButtons.Visibility = _renaming ? Visibility.Collapsed : Visibility.Visible;

        if (err != null)
        {
            GroupInfo.Text = err;
            GroupInfo.Foreground = (Brush)FindResource("Accent");
        }
        else if (linkActive)
        {
            GroupInfo.Text = g.Link;
            GroupInfo.Foreground = (Brush)FindResource("Accent");
        }
        else
        {
            GroupInfo.Text = $"GROUP · {n} ITEM{(n == 1 ? "" : "S")}";
            GroupInfo.Foreground = (Brush)FindResource("Dim");
        }
        GroupInfo.FontFamily = (err == null && !linkActive) ? (FontFamily)FindResource("MonoFont") : (FontFamily)FindResource("UiFont");

        GroupShareBtn.IsEnabled = n > 0;
        GroupSpinner.Visibility = uploading ? Visibility.Visible : Visibility.Collapsed;
        GroupCopyBtn.Visibility = !uploading && linkActive ? Visibility.Visible : Visibility.Collapsed;
        GroupLinkBtn.Visibility = !uploading && !linkActive ? Visibility.Visible : Visibility.Collapsed;
        GroupLinkBtn.IsEnabled = n > 0;
    }

    private void GroupShare_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedGroup is not ShelfGroup g) return;
        Clipboard.CopyFiles(_store.PathsInGroup(g.Id));
        Flash((Button)sender);
    }

    private void GroupCopy_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedGroup?.Link is string link) { Clipboard.Copy(link); Flash((Button)sender); }
    }

    private void GroupLink_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedGroup is not ShelfGroup g) return;
        Activate();
        ShowMenu((FrameworkElement)sender,
            Entry("Group link (zip) – 1 hour", () => _store.MakeGroupLink(g, 1)),
            Entry("Group link (zip) – 12 hours", () => _store.MakeGroupLink(g, 12)),
            Entry("Group link (zip) – 24 hours", () => _store.MakeGroupLink(g, 24)),
            Entry("Group link (zip) – 72 hours", () => _store.MakeGroupLink(g, 72)));
    }

    private void GroupMore_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedGroup is not ShelfGroup g) return;
        ShowMenu((FrameworkElement)sender,
            Entry("Rename group", () =>
            {
                _renaming = true;
                RenameBox.Text = g.Name;
                UpdateGroupBar();
                Activate();
                RenameBox.Focus();
                RenameBox.SelectAll();
            }),
            Entry("Delete group (keep files)", () => { _store.DeleteGroup(g.Id, false); _selected = null; Refresh(); }),
            Entry("Delete group and its files", () => { _store.DeleteGroup(g.Id, true); _selected = null; Refresh(); }));
    }

    private void RenameBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { FinishRename(); e.Handled = true; }
        else if (e.Key == Key.Escape) { _renaming = false; UpdateGroupBar(); e.Handled = true; }
    }

    private void RenameDone_Click(object sender, RoutedEventArgs e) => FinishRename();

    private void FinishRename()
    {
        if (SelectedGroup is ShelfGroup g) _store.RenameGroup(g.Id, RenameBox.Text);
        _renaming = false;
        Refresh();
    }

    // =====================================================================
    //  Header / footer buttons, window moving and resizing
    // =====================================================================

    private void Clear_Click(object sender, RoutedEventArgs e) =>
        _store.Clear(_view.Cast<ShelfItem>().ToList());

    private void Close_Click(object sender, RoutedEventArgs e) => HideShelf();

    private void Drag_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed) return;
        try { DragMove(); } catch (InvalidOperationException) { }
    }

    // Hold Alt and drag from anywhere (even over file rows) to move the shelf.
    private void Window_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Alt) == 0) return;
        e.Handled = true;
        try { DragMove(); } catch (InvalidOperationException) { }
    }

    private System.Drawing.Point _gripStartMouse;
    private double _gripStartW, _gripStartH;

    private void Grip_DragStarted(object sender, DragStartedEventArgs e)
    {
        _gripStartMouse = Forms.Cursor.Position;
        _gripStartW = Width;
        _gripStartH = Height;
    }

    private void Grip_DragDelta(object sender, DragDeltaEventArgs e)
    {
        // Measured against the screen, not the grip (which moves while we resize).
        double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var m = Forms.Cursor.Position;
        Width = Math.Min(Math.Max(_gripStartW + (m.X - _gripStartMouse.X) / scale, MinWidth), MaxWidth);
        Height = Math.Min(Math.Max(_gripStartH + (m.Y - _gripStartMouse.Y) / scale, MinHeight), MaxHeight);
    }

    private void Grip_DragCompleted(object sender, DragCompletedEventArgs e) => SaveSize();

    private void Window_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        double w = ActualWidth - 28, h = ActualHeight - 28;      // minus the shadow margin
        bool compact = w < 340 || h < 400;
        CountText.FontSize = compact ? 34 : 46;
        Header.Margin = compact ? new Thickness(14, 10, 14, 4) : new Thickness(20, 16, 20, 8);
        ChipsPanel.Margin = compact ? new Thickness(12, 4, 12, 4) : new Thickness(18, 8, 18, 8);
        Footer.Margin = compact ? new Thickness(14, 8, 14, 12) : new Thickness(20, 8, 14, 12);
        FooterAlt.Visibility = w >= 360 ? Visibility.Visible : Visibility.Collapsed;
        FooterMove.Visibility = w >= 300 ? Visibility.Visible : Visibility.Collapsed;
    }

    // =====================================================================
    //  Showing / hiding / sizing (size is remembered, like the Mac's frame autosave)
    // =====================================================================

    private void PickSize()
    {
        var wa = Forms.Screen.PrimaryScreen?.WorkingArea ?? new System.Drawing.Rectangle(0, 0, 1920, 1040);
        double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        double vw = wa.Width / scale, vh = wa.Height / scale;

        // Roomy on big displays, compact on small ones.
        double w = Math.Min(Math.Max(vw * 0.24, 340), 420) + 28;
        double h = Math.Min(Math.Max(vh * 0.62, 440), Math.Min(640, vh - 40)) + 28;
        try
        {
            if (File.Exists(SizeFile))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(SizeFile));
                w = doc.RootElement.GetProperty("w").GetDouble();
                h = doc.RootElement.GetProperty("h").GetDouble();
            }
        }
        catch { }
        Width = Math.Min(Math.Max(w, MinWidth), MaxWidth);
        Height = Math.Min(Math.Max(h, MinHeight), MaxHeight);
    }

    private void SaveSize()
    {
        try { File.WriteAllText(SizeFile, JsonSerializer.Serialize(new { w = Width, h = Height })); } catch { }
    }

    private void FitToScreen(System.Drawing.Rectangle wa, double scale)
    {
        Width = Math.Min(Width, wa.Width / scale - 20);
        Height = Math.Min(Height, wa.Height / scale - 20);
    }

    /// <summary>Slides in next to the pointer (screen pixels) without stealing focus.</summary>
    public void ShowNear(System.Drawing.Point p)
    {
        if (IsVisible) return;
        var screen = Forms.Screen.FromPoint(p);
        var wa = screen.WorkingArea;
        double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        FitToScreen(wa, scale);
        double sw = Width * scale, sh = Height * scale;

        double x = p.X + 40;
        if (x + sw > wa.Right - 10) x = p.X - 40 - sw;
        x = Math.Min(Math.Max(x, wa.Left + 10), wa.Right - sw - 10);
        double y = Math.Min(Math.Max(p.Y - sh / 2, wa.Top + 10), wa.Bottom - sh - 10);

        Left = x / scale;
        Top = y / scale;
        Show();
    }

    /// <summary>From the tray menu: dock to the right edge of the main screen.</summary>
    public void ShowFromMenu()
    {
        var wa = Forms.Screen.PrimaryScreen?.WorkingArea ?? new System.Drawing.Rectangle(0, 0, 1920, 1040);
        double scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        FitToScreen(wa, scale);
        Left = (wa.Right - 20) / scale - Width;
        Top = (wa.Top + wa.Height / 2.0) / scale - Height / 2;
        Show();
        Activate();
    }

    public void HideShelf()
    {
        SaveSize();
        Hide();
    }

    // =====================================================================
    //  Dropping files in
    // =====================================================================

    private void Window_DragOver(object sender, DragEventArgs e)
    {
        bool ok = !_draggingOut && e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = ok ? DragDropEffects.Copy : DragDropEffects.None;
        SetTargeted(ok);
        e.Handled = true;
    }

    private void Window_DragLeave(object sender, DragEventArgs e) => SetTargeted(false);

    private void Window_Drop(object sender, DragEventArgs e)
    {
        SetTargeted(false);
        AddDropped(e, _selected);
        e.Handled = true;
    }

    private void AddDropped(DragEventArgs e, Guid? group)
    {
        if (_draggingOut || !e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths && paths.Length > 0)
            _store.Add(paths, group);
    }

    // =====================================================================
    //  Item rows
    // =====================================================================

    private static ShelfItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as ShelfItem;

    private static bool IsOverButton(object? source)
    {
        var d = source as DependencyObject;
        while (d != null)
        {
            if (d is ButtonBase) return true;
            d = (d is Visual || d is System.Windows.Media.Media3D.Visual3D) ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
        }
        return false;
    }

    private void Row_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (IsOverButton(e.OriginalSource)) { _dragItem = null; return; }
        _dragStart = e.GetPosition(null);
        _dragItem = ItemOf(sender);
    }

    // Drag the file out of the shelf into any app / window / e-mail / chat.
    private void Row_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _dragItem == null) return;
        var d = e.GetPosition(null) - _dragStart;
        if (Math.Abs(d.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(d.Y) < SystemParameters.MinimumVerticalDragDistance) return;

        var item = _dragItem;
        _dragItem = null;
        var path = _store.FilePath(item);
        if (!File.Exists(path)) return;

        _draggingOut = true;
        try
        {
            DragDrop.DoDragDrop((DependencyObject)sender, new DataObject(DataFormats.FileDrop, new[] { path }), DragDropEffects.Copy);
        }
        finally { _draggingOut = false; }
    }

    private void Row_PreviewMouseRightButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (ItemOf(sender) is not ShelfItem item) return;
        var move = new MenuItem { Header = "Move to group" };
        move.Items.Add(Entry("No group", () => { _store.Move(item, null); Refresh(); }));
        foreach (var g in _store.Groups)
        {
            var id = g.Id;
            move.Items.Add(Entry(g.Name, () => { _store.Move(item, id); Refresh(); }));
        }
        ShowMenu((FrameworkElement)sender, mouse: true,
            move,
            Entry("Show in Explorer", () => Process.Start("explorer.exe", $"/select,\"{_store.FilePath(item)}\"")),
            Entry("Remove", () => _store.Remove(item)));
        e.Handled = true;
    }

    private void RowShare_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not ShelfItem item) return;
        Clipboard.CopyFiles(new[] { _store.FilePath(item) });
        Flash((Button)sender);
    }

    private void RowCopy_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender)?.Link is string link) { Clipboard.Copy(link); Flash((Button)sender, keepAccent: true); }
    }

    private void RowLink_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not ShelfItem item) return;
        Activate();
        ShowMenu((FrameworkElement)sender,
            Entry("Link valid for 1 hour", () => _store.MakeLink(item, 1)),
            Entry("Link valid for 12 hours", () => _store.MakeLink(item, 12)),
            Entry("Link valid for 24 hours", () => _store.MakeLink(item, 24)),
            Entry("Link valid for 72 hours", () => _store.MakeLink(item, 72)));
    }

    private void RowRemove_Click(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is ShelfItem item) _store.Remove(item);
    }

    // =====================================================================
    //  Small helpers
    // =====================================================================

    private static MenuItem Entry(string header, Action action)
    {
        var m = new MenuItem { Header = header };
        m.Click += (_, _) => action();
        return m;
    }

    private static void ShowMenu(FrameworkElement anchor, params MenuItem[] items) =>
        ShowMenu(anchor, false, items);

    private static void ShowMenu(FrameworkElement anchor, bool mouse, params MenuItem[] items)
    {
        var menu = new ContextMenu
        {
            PlacementTarget = anchor,
            Placement = mouse ? PlacementMode.MousePoint : PlacementMode.Bottom,
        };
        foreach (var i in items) menu.Items.Add(i);
        menu.IsOpen = true;
    }

    /// <summary>Briefly tints a button to confirm that a copy happened.</summary>
    private void Flash(Button b, bool keepAccent = false)
    {
        b.Foreground = (Brush)FindResource("Accent");
        var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
        t.Tick += (_, _) =>
        {
            t.Stop();
            if (!keepAccent) b.ClearValue(Control.ForegroundProperty);
        };
        t.Start();
    }
}
