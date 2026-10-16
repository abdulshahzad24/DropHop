using System;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace DropHop;

/// <summary>
/// Advertises "_drophop._tcp" on the local network (Bonjour / mDNS) using the DNS-SD API built into
/// Windows 10 (1809+), so the phone can find this PC without typing an address.
/// If the API isn't there, the pairing window still shows the PC's address for manual entry.
/// </summary>
internal sealed class Mdns : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr Callback;
        public IntPtr QueryContext;
        public IntPtr Credentials;
        public int UnicastEnabled;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RegisterComplete(uint status, IntPtr context, IntPtr instance);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName,
        IntPtr ip4, IntPtr ip6, ushort port, ushort priority, ushort weight,
        uint propertyCount, IntPtr keys, IntPtr values);

    [DllImport("dnsapi.dll")] private static extern void DnsServiceFreeInstance(IntPtr instance);
    [DllImport("dnsapi.dll")] private static extern uint DnsServiceRegister(ref RegisterRequest request, IntPtr cancel);
    [DllImport("dnsapi.dll")] private static extern uint DnsServiceDeRegister(ref RegisterRequest request, IntPtr cancel);

    private static readonly RegisterComplete Complete = (_, _, _) => { };   // kept alive for native code

    private IntPtr _instance;
    private RegisterRequest _request;
    private bool _registered;

    public bool Advertising => _registered;

    public static IPAddress? LocalAddress()
    {
        try
        {
            using var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            s.Connect("203.0.113.1", 9);       // no packet is sent; this just picks the outgoing interface
            if (s.LocalEndPoint is IPEndPoint ep && !IPAddress.IsLoopback(ep.Address)) return ep.Address;
        }
        catch { }
        return NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up &&
                        n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
    }

    public void Register(string name, int port)
    {
        Unregister();
        IntPtr ip = IntPtr.Zero;
        try
        {
            var addr = LocalAddress();
            if (addr != null)
            {
                ip = Marshal.AllocHGlobal(4);
                Marshal.Copy(addr.GetAddressBytes(), 0, ip, 4);     // network byte order, as IP4_ADDRESS expects
            }

            var label = new string(name.Where(c => char.IsLetterOrDigit(c) || c == '-').ToArray());
            if (label.Length == 0) label = "DropHopPC";

            _instance = DnsServiceConstructInstance(
                name + "._drophop._tcp.local", label + ".local",
                ip, IntPtr.Zero, (ushort)port, 0, 0, 0, IntPtr.Zero, IntPtr.Zero);
            if (_instance == IntPtr.Zero) return;

            _request = new RegisterRequest
            {
                Version = 1,
                InterfaceIndex = 0,
                ServiceInstance = _instance,
                Callback = Marshal.GetFunctionPointerForDelegate(Complete),
            };
            uint rc = DnsServiceRegister(ref _request, IntPtr.Zero);
            _registered = rc == 9506 /* DNS_REQUEST_PENDING */ || rc == 0;
            if (!_registered) { DnsServiceFreeInstance(_instance); _instance = IntPtr.Zero; }
        }
        catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException)
        {
            _registered = false;      // older Windows: manual address still works
        }
        finally
        {
            if (ip != IntPtr.Zero) Marshal.FreeHGlobal(ip);
        }
    }

    public void Unregister()
    {
        if (_instance == IntPtr.Zero) return;
        try
        {
            if (_registered) DnsServiceDeRegister(ref _request, IntPtr.Zero);
            DnsServiceFreeInstance(_instance);
        }
        catch { }
        _instance = IntPtr.Zero;
        _registered = false;
    }

    public void Dispose() => Unregister();
}
