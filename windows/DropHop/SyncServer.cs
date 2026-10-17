using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace DropHop;

// ---- Wire format: identical to the Mac app, so the same phone app talks to either. ----
// Deliberately separate from ShelfItem so public share links never leave the PC.

internal sealed record SyncItem(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("groupID")] Guid? GroupID,
    [property: JsonPropertyName("isFolder")] bool IsFolder);

internal sealed record SyncGroup(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("name")] string Name);

internal sealed record SyncManifest(
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("items")] List<SyncItem> Items,
    [property: JsonPropertyName("groups")] List<SyncGroup> Groups);

internal sealed record Ping(
    [property: JsonPropertyName("app")] string App,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("paired")] bool Paired);

internal sealed record PairReply(
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("host")] string Host);

internal sealed record LinkReply([property: JsonPropertyName("url")] string Url);

internal sealed class PairRequest
{
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("deviceName")] public string? DeviceName { get; set; }
}

internal sealed class HttpRequest
{
    public string Method = "";
    public string Path = "";
    public Dictionary<string, string> Headers = new();   // lower-cased keys
    public byte[] Body = Array.Empty<byte>();

    // Phone → PC uploads are streamed straight to disk instead of being held in memory.
    public bool Streaming;
    public long ContentLength;
    public byte[] Prefix = Array.Empty<byte>();     // the first body bytes that arrived together with the headers
}

internal abstract record SyncResponse;
internal sealed record JsonResponse(int Status, byte[] Body) : SyncResponse;
internal sealed record FileResponse(string Path, bool Temporary) : SyncResponse;

/// <summary>
/// Serves the shelf to ONE paired phone over the local network.
///  - Advertised over mDNS as "_drophop._tcp".
///  - Nothing except /v1/ping and /v1/pair is reachable without the bearer token.
///  - Pairing needs a 6-digit code that only this PC's screen shows (2 min, 5 tries).
///  - Pairing a new phone replaces the old one.
/// </summary>
public sealed class SyncServer : Observable
{
    private readonly ShelfStore _store;
    private readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
    private readonly Mdns _mdns = new();
    private TcpListener? _listener;
    private DateTime _codeExpiry;
    private int _failedAttempts;

    private PairedDevice? _paired;
    private string? _pairingCode;
    private bool _listening;

    public PairedDevice? Paired { get => _paired; private set => Set(ref _paired, value); }
    public string? PairingCode { get => _pairingCode; private set => Set(ref _pairingCode, value); }
    public bool Listening { get => _listening; private set => Set(ref _listening, value); }
    public int Port { get; private set; }

    public static string HostName => Environment.MachineName;
    public string Address
    {
        get
        {
            var ip = Mdns.LocalAddress();
            return ip == null || Port == 0 ? "" : $"{ip}:{Port}";
        }
    }

    private static string PairingFile => Path.Combine(ShelfStore.Root, "pairing.json");
    private static readonly JsonSerializerOptions JsonOpts = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public SyncServer(ShelfStore store)
    {
        _store = store;
        LoadPairing();
    }

    // ---------- lifecycle ----------

    public void Start()
    {
        if (_listener != null) return;
        try
        {
            var l = new TcpListener(IPAddress.Any, 0);       // IPv4, any free port
            l.Start();
            _listener = l;
            Port = ((IPEndPoint)l.LocalEndpoint).Port;
            Listening = true;
            _mdns.Register(HostName, Port);
            NetworkChange.NetworkAddressChanged += OnNetworkChanged;
            _ = AcceptLoop(l);
        }
        catch
        {
            Listening = false;
            _ = RetryLater();
        }
    }

    private async Task RetryLater()
    {
        await Task.Delay(5000);
        _listener = null;
        Start();
    }

    private DateTime _lastNet = DateTime.MinValue;
    private void OnNetworkChanged(object? s, EventArgs e)
    {
        // Wi-Fi changed: announce ourselves again on the new network.
        if ((DateTime.Now - _lastNet).TotalSeconds < 3) return;
        _lastNet = DateTime.Now;
        _ui.BeginInvoke(new Action(() => { if (_listener != null) _mdns.Register(HostName, Port); }));
    }

    public void Stop()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        _mdns.Dispose();
        try { _listener?.Stop(); } catch { }
        _listener = null;
    }

    private async Task AcceptLoop(TcpListener l)
    {
        while (true)
        {
            TcpClient c;
            try { c = await l.AcceptTcpClientAsync(); }
            catch { return; }
            _ = Task.Run(() => HandleConnection(c));
        }
    }

    // ---------- pairing ----------

    public void BeginPairing()
    {
        var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
        PairingCode = code;
        _codeExpiry = DateTime.Now.AddSeconds(120);
        _failedAttempts = 0;
        _ = Task.Delay(121_000).ContinueWith(_ =>
            _ui.BeginInvoke(new Action(() => { if (PairingCode == code) CancelPairing(); })));
    }

    public void CancelPairing() => PairingCode = null;

    public void Unpair()
    {
        Paired = null;
        try { File.Delete(PairingFile); } catch { }
    }

    private SyncResponse HandlePair(HttpRequest req)
    {
        if (PairingCode is not string code || _codeExpiry <= DateTime.Now)
            return Fail(403, "No pairing in progress. Choose “Pair phone…” on your PC first.");

        PairRequest? body;
        try { body = JsonSerializer.Deserialize<PairRequest>(req.Body); }
        catch { body = null; }
        if (body == null) return Fail(400, "Bad request");

        if (!FixedEq(body.Code, code))
        {
            _failedAttempts++;
            if (_failedAttempts >= 5) CancelPairing();
            return Fail(403, _failedAttempts >= 5
                ? "Too many wrong codes. Start pairing again on your PC."
                : "Wrong code");
        }

        var token = RandomToken();
        Paired = new PairedDevice
        {
            Name = string.IsNullOrWhiteSpace(body.DeviceName) ? "Phone" : body.DeviceName!,
            TokenHash = Hash(token),
            PairedAt = DateTime.Now,
        };
        SavePairing();
        CancelPairing();
        return Json(200, new PairReply(token, HostName));
    }

    private bool IsAuthorized(HttpRequest req)
    {
        if (Paired is not PairedDevice device) return false;
        if (!req.Headers.TryGetValue("authorization", out var header) ||
            !header.StartsWith("Bearer ", StringComparison.Ordinal)) return false;
        return FixedEq(Hash(header[7..]), device.TokenHash);
    }

    private static bool FixedEq(string a, string b) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(a), Encoding.UTF8.GetBytes(b));

    // ---------- routing (runs on the UI thread, where the store lives) ----------

    private async Task<SyncResponse> Route(HttpRequest req)
    {
        var path = req.Path.Split('?')[0];

        if (req.Method == "GET" && path == "/v1/ping")
            return Json(200, new Ping("DropHop", HostName, Paired != null));
        if (req.Method == "POST" && path == "/v1/pair")
            return HandlePair(req);

        // Everything below needs the paired phone's token.
        if (!IsAuthorized(req)) return Fail(401, "Not paired");

        if (req.Method == "GET" && path == "/v1/manifest") return Manifest();

        const string files = "/v1/files/";
        if (req.Method == "POST" && path.StartsWith(files) && path.EndsWith("/link"))
        {
            var idStr = path[files.Length..^"/link".Length];
            if (!Guid.TryParse(idStr, out var id) || _store.Items.All(i => i.Id != id))
                return Fail(404, "No such file");
            try { return Json(200, new LinkReply(await _store.LinkForSync(id))); }
            catch (Exception e) { return Fail(502, "Upload failed: " + e.Message); }
        }
        if (req.Method == "GET" && path.StartsWith(files))
        {
            var item = Guid.TryParse(path[files.Length..], out var id)
                ? _store.Items.FirstOrDefault(i => i.Id == id) : null;
            if (item == null) return Fail(404, "No such file");
            return await FileFor(item);
        }
        return Fail(404, "Not found");
    }

    private SyncResponse Manifest()
    {
        var items = _store.Items.Select(i =>
        {
            bool isDir = Directory.Exists(_store.FilePath(i));
            return new SyncItem(i.Id, isDir ? i.Name + ".zip" : i.Name, i.Size, i.GroupId, isDir);
        }).ToList();
        var groups = _store.Groups.Select(g => new SyncGroup(g.Id, g.Name)).ToList();
        return Json(200, new SyncManifest(HostName, items, groups));
    }

    private async Task<SyncResponse> FileFor(ShelfItem item)
    {
        var path = _store.FilePath(item);
        if (File.Exists(path)) return new FileResponse(path, false);
        if (!Directory.Exists(path)) return Fail(404, "File is gone");

        // Folders are sent as a zip.
        var zip = Path.Combine(Path.GetTempPath(), "drophop-" + Guid.NewGuid().ToString("N") + ".zip");
        try
        {
            await Task.Run(() => ZipFile.CreateFromDirectory(path, zip, CompressionLevel.Fastest, true));
            return new FileResponse(zip, true);
        }
        catch { return Fail(500, "Could not zip folder"); }
    }

    // ---------- helpers ----------

    private static SyncResponse Json<T>(int status, T value) =>
        new JsonResponse(status, JsonSerializer.SerializeToUtf8Bytes(value, JsonOpts));

    private static SyncResponse Fail(int status, string message) =>
        Json(status, new Dictionary<string, string> { ["error"] = message });

    internal static string RandomToken() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace('+', '-').Replace('/', '_').TrimEnd('=');

    internal static string Hash(string token) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();

    private void SavePairing()
    {
        try { File.WriteAllText(PairingFile, JsonSerializer.Serialize(Paired)); } catch { }
    }

    private void LoadPairing()
    {
        try
        {
            if (File.Exists(PairingFile))
                _paired = JsonSerializer.Deserialize<PairedDevice>(File.ReadAllText(PairingFile));
        }
        catch { }
    }

    // ---------- minimal HTTP/1.1 (one request per connection) ----------

    private async Task HandleConnection(TcpClient client)
    {
        using var _ = client;
        try
        {
            client.NoDelay = true;
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var stream = client.GetStream();
            var req = await ReadRequest(stream, cts.Token);
            if (req == null) return;

            if (req.Streaming)
            {
                await HandleUpload(stream, req);
                return;
            }

            var response = await await _ui.InvokeAsync(() => Route(req));
            await Send(stream, response);
        }
        catch { /* the phone went away; nothing to do */ }
    }

    // ---------- phone → PC upload:  PUT /v1/upload?name=<url-encoded file name> ----------

    private const long MaxUploadBytes = 4L * 1024 * 1024 * 1024;

    private async Task HandleUpload(NetworkStream stream, HttpRequest req)
    {
        // Same rule as everything else: no token, no upload. Checked before a single byte is stored.
        bool allowed = await _ui.InvokeAsync(() => IsAuthorized(req));
        if (!allowed) { await Send(stream, Fail(401, "Not paired")); return; }
        if (req.ContentLength < 0 || req.ContentLength > MaxUploadBytes)
        {
            await Send(stream, Fail(413, "That file is too large"));
            return;
        }

        var name = SafeFileName(QueryValue(req.Path, "name"));
        var id = Guid.NewGuid();
        var dir = Path.Combine(ShelfStore.Root, id.ToString());
        var dest = Path.Combine(dir, name);
        try
        {
            Directory.CreateDirectory(dir);
            long remaining = req.ContentLength;
            await using (var fs = new FileStream(dest, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 18, true))
            {
                if (req.Prefix.Length > 0)
                {
                    await fs.WriteAsync(req.Prefix);
                    remaining -= req.Prefix.Length;
                }
                var buf = new byte[256 * 1024];
                while (remaining > 0)
                {
                    // gives up only if the phone goes completely silent for 30 s
                    using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                    int n = await stream.ReadAsync(buf.AsMemory(0, (int)Math.Min(buf.Length, remaining)), cts.Token);
                    if (n <= 0) throw new IOException("The upload was cut off");
                    await fs.WriteAsync(buf.AsMemory(0, n));
                    remaining -= n;
                }
            }

            long size = new FileInfo(dest).Length;
            await _ui.InvokeAsync(() => _store.AddReceived(id, name, size));
            await Send(stream, Json(200, new Dictionary<string, string> { ["ok"] = "true" }));
        }
        catch (Exception e)
        {
            try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
            try { await Send(stream, Fail(500, "Could not save the file: " + e.Message)); } catch { }
        }
    }

    private static string QueryValue(string pathAndQuery, string key)
    {
        int q = pathAndQuery.IndexOf('?');
        if (q < 0) return "";
        foreach (var part in pathAndQuery[(q + 1)..].Split('&'))
        {
            int eq = part.IndexOf('=');
            if (eq > 0 && part[..eq] == key)
            {
                try { return Uri.UnescapeDataString(part[(eq + 1)..]); } catch { return ""; }
            }
        }
        return "";
    }

    /// <summary>A name the phone chose can never escape the shelf folder or contain characters Windows rejects.</summary>
    private static string SafeFileName(string raw)
    {
        var name = raw.Replace('\\', '/');
        name = name.Substring(name.LastIndexOf('/') + 1);
        foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
        name = name.Trim().TrimEnd('.');
        if (name.Length > 150) name = name[..150];
        return name.Length == 0 ? "file" : name;
    }

    private static async Task<HttpRequest?> ReadRequest(NetworkStream stream, CancellationToken ct)
    {
        var buf = new List<byte>(1024);
        var chunk = new byte[8192];
        int headEnd = -1;
        while (headEnd < 0)
        {
            int n = await stream.ReadAsync(chunk, ct);
            if (n <= 0 || buf.Count > 200_000) return null;
            buf.AddRange(chunk.AsSpan(0, n).ToArray());
            headEnd = IndexOfCrlfCrlf(buf);
        }

        var head = Encoding.UTF8.GetString(buf.GetRange(0, headEnd).ToArray());
        var lines = head.Split("\r\n");
        var first = lines[0].Split(' ');
        if (first.Length < 2) return null;

        var req = new HttpRequest { Method = first[0], Path = first[1] };
        foreach (var line in lines.Skip(1))
        {
            int colon = line.IndexOf(':');
            if (colon <= 0) continue;
            req.Headers[line[..colon].ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }

        long declared = req.Headers.TryGetValue("content-length", out var cl) && long.TryParse(cl, out var v) ? v : 0;
        int bodyStart = headEnd + 4;

        // A file coming from the phone: don't read it here, HandleUpload streams it to disk.
        if (req.Method == "PUT" && req.Path.Split('?')[0] == "/v1/upload")
        {
            req.Streaming = true;
            req.ContentLength = declared;
            int have = (int)Math.Min(buf.Count - bodyStart, Math.Max(declared, 0));
            req.Prefix = buf.GetRange(bodyStart, have).ToArray();
            return req;
        }

        if (declared < 0 || declared > 65_536) return null;
        int length = (int)declared;

        while (buf.Count - bodyStart < length)
        {
            int n = await stream.ReadAsync(chunk, ct);
            if (n <= 0) return null;
            buf.AddRange(chunk.AsSpan(0, n).ToArray());
        }
        req.Body = buf.GetRange(bodyStart, length).ToArray();
        return req;
    }

    private static int IndexOfCrlfCrlf(List<byte> b)
    {
        for (int i = 0; i + 3 < b.Count; i++)
            if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
        return -1;
    }

    private static async Task Send(NetworkStream stream, SyncResponse response)
    {
        switch (response)
        {
            case JsonResponse j:
            {
                var head = $"HTTP/1.1 {j.Status} {Reason(j.Status)}\r\nContent-Type: application/json\r\n" +
                           $"Content-Length: {j.Body.Length}\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
                await stream.WriteAsync(j.Body);
                break;
            }
            case FileResponse f:
            {
                try
                {
                    await using var fs = new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 18, true);
                    var head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n" +
                               $"Content-Length: {fs.Length}\r\nConnection: close\r\n\r\n";
                    await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
                    await fs.CopyToAsync(stream, 256 * 1024);   // streamed, so big files never sit in memory
                }
                catch (FileNotFoundException)
                {
                    await Send(stream, new JsonResponse(404, Encoding.UTF8.GetBytes("{\"error\":\"File is gone\"}")));
                }
                finally
                {
                    if (f.Temporary) { try { File.Delete(f.Path); } catch { } }
                }
                break;
            }
        }
        await stream.FlushAsync();
    }

    private static string Reason(int s) => s switch
    {
        200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
        404 => "Not Found", 413 => "Payload Too Large", 502 => "Bad Gateway", _ => "Internal Server Error",
    };
}
