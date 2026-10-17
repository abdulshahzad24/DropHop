using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace DropHop;

public sealed record UploadResult(string Link, int Hours);   // Hours = how long the link will really live

/// <summary>
/// Free, account-less, auto-expiring hosts, tried in order.
/// (0x0.st used to be the middle one; it has switched uploads off, so it is gone.)
/// </summary>
public static class Uploader
{
    private enum Host { Litterbox, Tmpfiles }

    /// <summary>The host answered but said no (HTML error page, bad status, no link). Retrying won't help.</summary>
    private sealed class HostRefused : Exception
    {
        public HostRefused(string message) : base(message) { }
    }

    private static string NameOf(Host h) => h switch
    {
        Host.Litterbox => "litterbox",
        _ => "tmpfiles",
    };

    private static long MaxBytes(Host h) => h switch
    {
        Host.Litterbox => 1_000_000_000,
        _ => 100_000_000,
    };

    // Free hosts refuse programs, so these are sent inside a zip instead.
    private static readonly HashSet<string> WrapInZip = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".msi", ".scr", ".bat", ".cmd", ".com", ".cpl", ".dll", ".jar", ".vbs", ".ps1",
    };

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(20) };

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
        if (!File.Exists(src)) throw new Exception("The file is no longer on the shelf");

        if (WrapInZip.Contains(Path.GetExtension(src)))
        {
            var wrapped = Path.Combine(Path.GetTempPath(), "drophop-" + Guid.NewGuid().ToString("N") + ".zip");
            try
            {
                await Task.Run(() =>
                {
                    using var za = ZipFile.Open(wrapped, ZipArchiveMode.Create);
                    za.CreateEntryFromFile(src, Path.GetFileName(src), CompressionLevel.Fastest);
                });
                return await SendToAnyHost(wrapped, Path.GetFileName(src) + ".zip", hours);
            }
            finally { TryDelete(wrapped); }
        }
        return await SendToAnyHost(src, Path.GetFileName(src), hours);
    }

    // If one host refuses (blocks us, is down, file too big) use the next.
    private static async Task<UploadResult> SendToAnyHost(string file, string uploadName, int hours)
    {
        long size = ShelfStore.SizeOf(file);
        var failures = new List<string>();
        foreach (Host host in new[] { Host.Litterbox, Host.Tmpfiles })
        {
            if (size > MaxBytes(host)) { failures.Add(NameOf(host) + ": file too large"); continue; }

            // Big uploads sometimes get cut off mid-way, so a dropped connection gets one more try.
            for (int attempt = 1; attempt <= 2; attempt++)
            {
                try { return await Send(file, uploadName, host, hours); }
                catch (HostRefused e) { failures.Add(NameOf(host) + ": " + e.Message); break; }
                catch (Exception e) when (attempt == 1 && IsTransient(e)) { await Task.Delay(1500); }
                catch (Exception e) { failures.Add(NameOf(host) + ": " + Describe(e)); break; }
            }
        }
        var msg = failures.Count == 0 ? "Upload failed" : string.Join(" · ", failures);
        throw new Exception(msg);
    }

    private static bool IsTransient(Exception e) =>
        e is HttpRequestException || e is IOException || e is TaskCanceledException;

    private static string Describe(Exception e)
    {
        if (e is TaskCanceledException) return "timed out";
        var m = e.InnerException?.Message ?? e.Message;
        return m.Length > 70 ? m[..70] : m;
    }

    /// <summary>Plain ASCII file name: servers and .NET disagree about how to encode anything else.</summary>
    private static string AsciiName(string name)
    {
        var sb = new StringBuilder(name.Length);
        foreach (var c in name)
            sb.Append(c < 32 || c > 126 || c == '"' || c == '\\' || c == ';' ? '_' : c);
        return sb.Length == 0 ? "file" : sb.ToString();
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
                fields.Add(("time", hours + "h"));            // litterbox only knows 1h, 12h, 24h, 72h
                break;
            default:
                endpoint = "https://tmpfiles.org/api/v1/upload";
                fileField = "file";
                break;
        }

        // Build the multipart body the way curl does: quoted field names and an UNquoted boundary.
        // .NET's defaults (unquoted names, quoted boundary) are rejected by some upload hosts.
        var boundary = "----DropHop" + Guid.NewGuid().ToString("N");
        using var form = new MultipartFormDataContent(boundary);
        form.Headers.Remove("Content-Type");
        form.Headers.TryAddWithoutValidation("Content-Type", "multipart/form-data; boundary=" + boundary);

        foreach (var (k, v) in fields)
        {
            var part = new StringContent(v);
            part.Headers.ContentType = null;
            part.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data") { Name = "\"" + k + "\"" };
            form.Add(part);
        }

        await using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, true);
        var filePart = new StreamContent(stream, 1 << 16);
        filePart.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        filePart.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data")
        {
            Name = "\"" + fileField + "\"",
            FileName = "\"" + AsciiName(uploadName) + "\"",
        };
        form.Add(filePart);

        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = form };
        req.Version = HttpVersion.Version11;
        req.VersionPolicy = HttpVersionPolicy.RequestVersionOrLower;
        req.Headers.ExpectContinue = false;
        // Some hosts reject the default .NET user agent with an HTML error page.
        req.Headers.UserAgent.ParseAdd("DropHop/1.0 (Windows)");
        req.Headers.Accept.ParseAdd("*/*");

        using var resp = await Http.SendAsync(req);
        int code = (int)resp.StatusCode;
        var text = (await resp.Content.ReadAsStringAsync()).Trim();

        // An HTML page instead of a link means the host blocked or rejected us.
        var lower = text.ToLowerInvariant();
        if (lower.StartsWith("<") || lower.Contains("<html"))
            throw new HostRefused($"blocked it (HTTP {code})");

        if (host == Host.Tmpfiles)
        {
            string? url = null;
            try
            {
                using var doc = JsonDocument.Parse(text);
                url = doc.RootElement.GetProperty("data").GetProperty("url").GetString();
            }
            catch { }
            if (string.IsNullOrWhiteSpace(url)) throw new HostRefused("HTTP " + code);
            url = url.Replace("http://", "https://").Replace("tmpfiles.org/", "tmpfiles.org/dl/");
            return new UploadResult(url, 1);              // tmpfiles keeps files for 1 hour
        }

        if (code < 200 || code >= 300 || !text.StartsWith("http"))
            throw new HostRefused(text.Length == 0 ? "HTTP " + code : (text.Length > 80 ? text[..80] : text));
        return new UploadResult(text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)[0], hours);
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
