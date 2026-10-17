using System;
using System.IO;
using System.Threading;
using System.Windows;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace DropHop;

public partial class App : Application
{
    public static bool Quitting { get; private set; }

    private Mutex? _single;
    private ShelfStore _store = null!;
    private SyncServer _sync = null!;
    private ShelfWindow _shelf = null!;
    private ShakeMonitor _monitor = null!;
    private Forms.NotifyIcon _tray = null!;
    private PairingWindow? _pairWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Only one DropHop at a time.
        _single = new Mutex(true, "DropHop.SingleInstance", out bool first);
        if (!first) { Shutdown(); return; }

        DispatcherUnhandledException += (_, args) =>
        {
            try { File.AppendAllText(Path.Combine(ShelfStore.Root, "error.log"), DateTime.Now + "\n" + args.Exception + "\n\n"); } catch { }
            args.Handled = true;
        };

        _store = new ShelfStore();
        Startup.Prepare();      // run at Windows startup (on by default, switch off in the tray menu)
        _sync = new SyncServer(_store);
        _shelf = new ShelfWindow(_store);

        _monitor = new ShakeMonitor { Mode = LoadMode() };
        _monitor.Summon += () => Dispatcher.BeginInvoke(new Action(() =>
        {
            var p = Forms.Cursor.Position;
            _shelf.ShowNear(p);
        }));
        _monitor.DragEnd += () => Dispatcher.BeginInvoke(new Action(async () =>
        {
            // If you shook but never dropped anything, tuck the shelf away again.
            await System.Threading.Tasks.Task.Delay(3000);
            if (_store.Items.Count == 0 && _shelf.IsVisible && !_shelf.IsMouseOver && !_shelf.IsActive)
                _shelf.HideShelf();
        }));
        _monitor.Start();

        _sync.Start();       // lets your paired phone see and download the shelf

        BuildTray();

        _store.Received += name =>
            _tray.ShowBalloonTip(3000, "DropHop", "Received " + name + " from your phone", Forms.ToolTipIcon.Info);
    }

    private void BuildTray()
    {
        var iconStream = GetResourceStream(new Uri("pack://application:,,,/Assets/AppIcon.ico")).Stream;
        _tray = new Forms.NotifyIcon
        {
            Icon = new Drawing.Icon(iconStream),
            Text = "DropHop",
            Visible = true,
        };

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Show DropHop", null, (_, _) => _shelf.ShowFromMenu());
        menu.Items.Add("Clear Shelf", null, (_, _) => _store.Clear(new System.Collections.Generic.List<ShelfItem>(_store.Items)));
        menu.Items.Add("Pair phone…", null, (_, _) => PairPhone());
        menu.Items.Add(new Forms.ToolStripSeparator());

        // How the shelf pops up while you drag a file
        var summon = new Forms.ToolStripMenuItem("Show shelf when I…");
        var choices = new (string Label, SummonMode Mode)[]
        {
            ("Hold a dragged file still", SummonMode.Hold),
            ("Shake a dragged file", SummonMode.Shake),
            ("Either", SummonMode.Either),
        };
        foreach (var (label, mode) in choices)
        {
            var item = new Forms.ToolStripMenuItem(label) { Checked = _monitor.Mode == mode, CheckOnClick = false };
            item.Click += (_, _) =>
            {
                _monitor.Mode = mode;
                SaveMode(mode);
                foreach (Forms.ToolStripMenuItem other in summon.DropDownItems)
                    other.Checked = ReferenceEquals(other, item);
            };
            summon.DropDownItems.Add(item);
        }
        menu.Items.Add(summon);

        var startup = new Forms.ToolStripMenuItem("Start with Windows") { Checked = Startup.IsEnabled, CheckOnClick = false };
        startup.Click += (_, _) =>
        {
            Startup.Set(!Startup.IsEnabled);
            startup.Checked = Startup.IsEnabled;
        };
        menu.Items.Add(startup);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit DropHop", null, (_, _) => Quit());
        _tray.ContextMenuStrip = menu;
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) _shelf.ShowFromMenu();
        };
    }

    private static string SettingsFile => Path.Combine(ShelfStore.Root, "settings.json");

    private static SummonMode LoadMode()
    {
        try
        {
            if (File.Exists(SettingsFile))
            {
                using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(SettingsFile));
                if (Enum.TryParse(doc.RootElement.GetProperty("summon").GetString(), out SummonMode m)) return m;
            }
        }
        catch { }
        return SummonMode.Hold;
    }

    private static void SaveMode(SummonMode m)
    {
        try { File.WriteAllText(SettingsFile, System.Text.Json.JsonSerializer.Serialize(new { summon = m.ToString() })); } catch { }
    }

    private void PairPhone()
    {
        _sync.BeginPairing();
        if (_pairWindow == null)
        {
            _pairWindow = new PairingWindow(_sync);
            _pairWindow.Closed += (_, _) => _pairWindow = null;
        }
        _pairWindow.Show();
        _pairWindow.Activate();
    }

    private void Quit()
    {
        Quitting = true;
        _tray.Visible = false;
        _tray.Dispose();
        _monitor.Dispose();
        _sync.Stop();
        _shelf.Close();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { _single?.ReleaseMutex(); } catch { }
        base.OnExit(e);
    }
}
