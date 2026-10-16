using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading.Tasks;

namespace DropHop;

public sealed record UploadResult(string Link, int Hours);   // Hours = how long the link will really live

/// <summary>Free, account-less, auto-expiring hosts — tried in order, same as the Mac app.</summary>
public static class Uploader
{
    private enum Host { Litterbox, ZeroX, Tmpfiles }

    private static string NameOf(Host h) => h switch
    {
        Host.Litterbox => "litterbox",
        Host.ZeroX => "0x0.st",
        _ => "tmpfiles",
    };

    private static long MaxBytes(Host h) => h switch
    {
        Host.Litterbox => 1_000_000_000,
        Host.ZeroX => 500_000_000,
        _ => 100_000_000,
    };

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(15) };

    /// <summary>Several files → one zip → one link.</summary>
    public static async Task<UploadResult> UploadBundle(IEnumerable<string> files, string name, int hours)
    {
        var folderName = string.IsNullOrWhiteSpace(name) ? "DropHop" : name;
        var zip = Path.Combine(Path.GetTempPath(), "drophop-" + Guid.NewGuid().ToString("N") + ".zip");
        try
        {
            await Task.Run(() =>
            {
                using var za = ZipFile.Open(zip, ZipArchiveMode.Create);
                var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                int i = 0;
                foreach (var f in files)
                {
                    var n = Path.GetFileName(f);
                    if (!used.Add(n)) { n = i + "-" + n; used.Add(n); }
                    za.CreateEntryFromFile(f, folderName + "/" + n, CompressionLevel.Fastest);
                    i++;
                }
            });
            return await SendToAnyHost(zip, folderName + ".zip", hours);
        }
        finally { TryDelete(zip); }
    }

    public static async Task<UploadResult> Upload(string src, int hours)
    {
        if (Directory.Exists(src))
        {
            var zip = Path.Combine(Path.GetTempPath(), new DirectoryInfo(src).Name + ".zip");
            TryDelete(zip);
            try
            {
                await Task.Run(() => ZipFile.CreateFromDirectory(src, zip, CompressionLevel.Fastest, true));
                return await SendToAnyHost(zip, Path.GetFileName(zip), hours);
            }
            finally { TryDelete(zip); }
        }
        return await SendToAnyHost(src, Path.GetFileName(src), hours);
    }

    // If one host refuses (blocks us, is down, file too big) use the next.
    private static async Task<UploadResult> SendToAnyHost(string file, string uploadName, int hours)
    {
        long size = ShelfStore.SizeOf(file);
        var failures = new List<string>();
        foreach (Host host in Enum.GetValues(typeof(Host)))
        {
            if (size > MaxBytes(host)) { failures.Add(NameOf(host) + ": file too large"); continue; }
            try { return await Send(file, uploadName, host, hours); }
            catch (Exception e) { failures.Add(NameOf(host) + ": " + e.Message); }
        }
        var msg = failures.Count == 0 ? "Upload failed" : string.Join(" · ", failures);
        throw new Exception(msg.Length > 160 ? msg[..160] : msg);
    }

    private static async Task<UploadResult> Send(string file, string uploadName, Host host, int hours)
    {
        string endpoint, fileField;
        var fields = new List<(string, string)>();
        switch (host)
        {
            case Host.Litterbox:
                endpoint = "https://litterbox.catbox.moe/resources/internals/api.php";
                fileField = "fileToUpload";
                fields.Add(("reqtype", "fileupload"));
                fields.Add(("time", hours + "h"));
                break;
            case Host.ZeroX:
                endpoint = "https://0x0.st";
                fileField = "file";
                fields.Add(("expires", hours.ToString()));
                break;
            default:
                endpoint = "https://tmpfiles.org/api/v1/upload";
                fileField = "file";
                break;
        }

        using var form = new MultipartFormDataContent("Boundary-" + Guid.NewGuid());
        foreach (var (k, v) in fields) form.Add(new StringContent(v), k);
        await using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, true);
        var filePart = new StreamContent(stream);
        filePart.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        form.Add(filePart, fileField, uploadName.Replace('"', '_'));

        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = form };
        // Some hosts reject the default .NET user agent with an HTML error page.
        req.Headers.UserAgent.ParseAdd("DropHop/1.0 (Windows)");
        req.Headers.Accept.ParseAdd("*/*");

        using var resp = await Http.SendAsync(req);
        int code = (int)resp.StatusCode;
        var text = (await resp.Content.ReadAsStringAsync()).Trim();

        // An HTML page instead of a link means the host blocked or rejected us.
        var lower = text.ToLowerInvariant();
        if (lower.StartsWith("<") || lower.Contains("<html"))
            throw new Exception($"refused the upload (HTTP {code})");

        if (host == Host.Tmpfiles)
        {
            try
            {
                using var doc = JsonDocument.Parse(text);
                var url = doc.RootElement.GetProperty("data").GetProperty("url").GetString()!;
                url = url.Replace("http://", "https://").Replace("tmpfiles.org/", "tmpfiles.org/dl/");
                return new UploadResult(url, 1);          // tmpfiles keeps files for 1 hour
            }
            catch { throw new Exception("HTTP " + code); }
        }

        if (code < 200 || code >= 300 || !text.StartsWith("http"))
            throw new Exception(text.Length == 0 ? "HTTP " + code : (text.Length > 80 ? text[..80] : text));
        return new UploadResult(text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)[0], hours);
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
