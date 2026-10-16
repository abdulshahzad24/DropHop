using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace DropHop;

public partial class PairingWindow : Window
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private readonly SyncServer _server;

    public PairingWindow(SyncServer server)
    {
        InitializeComponent();
        _server = server;
        _server.PropertyChanged += OnServerChanged;
        Closed += (_, _) =>
        {
            _server.PropertyChanged -= OnServerChanged;
            _server.CancelPairing();
        };
        Update();
    }

    private void Window_SourceInitialized(object? sender, EventArgs e)
    {
        // Dark title bar to match the rest of the app (Windows 10 20H1+ / 11).
        int on = 1;
        var h = new WindowInteropHelper(this).Handle;
        DwmSetWindowAttribute(h, 20, ref on, sizeof(int));
        DwmSetWindowAttribute(h, 19, ref on, sizeof(int));
    }

    private void OnServerChanged(object? s, PropertyChangedEventArgs e) =>
        Dispatcher.BeginInvoke(new Action(Update));

    private void Update()
    {
        var code = _server.PairingCode;
        var device = _server.Paired;

        CodePanel.Visibility = code != null ? Visibility.Visible : Visibility.Collapsed;
        PairedPanel.Visibility = code == null && device != null ? Visibility.Visible : Visibility.Collapsed;
        ExpiredPanel.Visibility = code == null && device == null ? Visibility.Visible : Visibility.Collapsed;
        CurrentPanel.Visibility = code != null && device != null ? Visibility.Visible : Visibility.Collapsed;

        if (code is { Length: 6 }) CodeText.Text = code[..3] + " " + code[3..];
        var addr = _server.Address;
        AddressText.Text = addr.Length == 0 ? "" : $"CAN'T SEE THIS PC? ENTER {addr} ON THE PHONE";
        PairedTitle.Text = device == null ? "" : $"Paired with {device.Name}";
        CurrentText.Text = device == null ? "" : $"Currently paired: {device.Name}";
    }

    private void Unpair_Click(object sender, RoutedEventArgs e) => _server.Unpair();
    private void Done_Click(object sender, RoutedEventArgs e) => Close();
    private void NewCode_Click(object sender, RoutedEventArgs e) => _server.BeginPairing();
}
