using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Threading;

namespace DropHop;

public enum SummonMode { Hold, Shake, Either }

/// <summary>
/// Detects "grab a file in Explorer / on the desktop and either HOLD it still for a moment or
/// shake it left-right" with a global low-level mouse hook.
///
/// macOS can ask the drag pasteboard whether files are being dragged. Windows has no such API
/// for other apps' drags, so we use the closest reliable signal: the mouse button went down in
/// the client area of an Explorer window or the desktop, and then the pointer was shaken.
/// (Dragging from other apps can still be dropped on the shelf — summon it from the tray icon.)
/// </summary>
internal sealed class ShakeMonitor : IDisposable
{
    public event Action? Summon;
    public event Action? DragEnd;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT { public POINT Pt; public uint MouseData, Flags, Time; public IntPtr ExtraInfo; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr module, uint threadId);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hook, int nCode, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string? name);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr w, IntPtr l,
                                                    uint flags, uint timeoutMs, out IntPtr result);

    private const int WH_MOUSE_LL = 14;
    private const int WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202;
    private const uint WM_NCHITTEST = 0x84, SMTO_ABORTIFHUNG = 0x2, GA_ROOT = 2;
    private const int HTCLIENT = 1;

    private IntPtr _hook;
    private HookProc? _proc;

    // shake state (same idea as the Mac version: 3 real back-and-forth strokes within 0.9 s)
    private bool _down, _eligible, _fired;
    private int _lastX, _dir, _startX, _startY;
    private double _seg;
    private bool _moved;
    private readonly List<long> _reversals = new();

    // hold state: the drag has started, and the pointer has stayed put since _holdSince
    private int _holdX, _holdY;
    private long _holdSince;
    private DispatcherTimer? _timer;

    public SummonMode Mode { get; set; } = SummonMode.Hold;

    /// <summary>How long (ms) the pointer must rest, mid-drag, before the shelf appears.</summary>
    public int HoldMs { get; set; } = 600;

    /// <summary>Minimum stroke length in screen pixels (≈30 pt on the Mac, scaled for typical DPI).</summary>
    public double MinStroke { get; set; } = 40;

    public void Start()
    {
        _proc = Callback;
        using var p = Process.GetCurrentProcess();
        _hook = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(p.MainModule?.ModuleName), 0);

        // A resting pointer produces no mouse events, so poll for "held still long enough".
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(80) };
        _timer.Tick += (_, _) =>
        {
            if (Mode == SummonMode.Shake) return;
            if (_down && _eligible && _moved && !_fired && Environment.TickCount64 - _holdSince >= HoldMs)
            {
                _fired = true;
                Summon?.Invoke();
            }
        };
        _timer.Start();
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            try
            {
                var s = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
                switch ((int)wParam)
                {
                    case WM_LBUTTONDOWN: MouseDown(s.Pt); break;
                    case WM_MOUSEMOVE: if (_down) MouseDragged(s.Pt); break;
                    case WM_LBUTTONUP: MouseUp(); break;
                }
            }
            catch { /* never let an exception escape into the hook chain */ }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private void MouseDown(POINT pt)
    {
        _down = true;
        _eligible = IsFileDragSource(pt);
        _lastX = pt.X; _startX = pt.X; _startY = pt.Y;
        _dir = 0; _seg = 0; _moved = false; _fired = false;
        _reversals.Clear();
    }

    private void MouseUp()
    {
        bool wasDown = _down;
        _down = false; _fired = false; _eligible = false;
        if (wasDown) DragEnd?.Invoke();
    }

    private void MouseDragged(POINT pt)
    {
        if (!_eligible || _fired) return;

        // A click isn't a drag: wait until the pointer has really moved away from where it went down.
        if (!_moved)
        {
            if (Math.Abs(pt.X - _startX) + Math.Abs(pt.Y - _startY) < 12) { _lastX = pt.X; return; }
            _moved = true;
            _holdX = pt.X; _holdY = pt.Y; _holdSince = Environment.TickCount64;
        }

        long now = Environment.TickCount64;

        // Any real movement restarts the "held still" clock (tiny hand tremor doesn't).
        if (Math.Abs(pt.X - _holdX) + Math.Abs(pt.Y - _holdY) > 10)
        {
            _holdX = pt.X; _holdY = pt.Y; _holdSince = now;
        }

        if (Mode == SummonMode.Hold) { _lastX = pt.X; return; }

        int dx = pt.X - _lastX;
        _lastX = pt.X;
        if (dx == 0) return;

        int d = dx > 0 ? 1 : -1;
        if (d == _dir)
        {
            _seg += Math.Abs(dx);
        }
        else
        {
            if (_dir != 0 && _seg >= MinStroke) _reversals.Add(now);   // a real back-and-forth stroke
            _dir = d;
            _seg = Math.Abs(dx);
        }
        _reversals.RemoveAll(t => now - t > 900);
        if (_reversals.Count >= 3)
        {
            _fired = true;
            _reversals.Clear();
            Summon?.Invoke();
        }
    }

    /// <summary>True when the press landed in the client area of Explorer or the desktop (not a title bar).</summary>
    private static bool IsFileDragSource(POINT pt)
    {
        var hwnd = WindowFromPoint(pt);
        if (hwnd == IntPtr.Zero) return false;
        var root = GetAncestor(hwnd, GA_ROOT);
        if (root == IntPtr.Zero) return false;

        GetWindowThreadProcessId(root, out uint pid);
        if (pid == (uint)Environment.ProcessId) return false;          // our own shelf

        var sb = new StringBuilder(64);
        GetClassName(root, sb, sb.Capacity);
        var cls = sb.ToString();
        if (cls is not ("CabinetWClass" or "ExploreWClass" or "Progman" or "WorkerW")) return false;

        // Shaking an Explorer *window* by its title bar is a Windows feature — don't hijack it.
        long lParam = ((long)(ushort)pt.Y << 16) | (ushort)pt.X;
        if (SendMessageTimeout(root, WM_NCHITTEST, IntPtr.Zero, (IntPtr)lParam, SMTO_ABORTIFHUNG, 30, out var hit)
            == IntPtr.Zero) return false;
        return (int)hit == HTCLIENT;
    }

    public void Dispose()
    {
        _timer?.Stop();
        if (_hook != IntPtr.Zero) { UnhookWindowsHookEx(_hook); _hook = IntPtr.Zero; }
    }
}
