using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;

namespace DropHop;

/// <summary>
/// The shelf: items, groups, and everything that can be done to them.
/// All members are used from the UI thread (the sync server hops over to it first).
/// </summary>
public sealed class ShelfStore
{
    public ObservableCollection<ShelfItem> Items { get; } = new();
    public ObservableCollection<ShelfGroup> Groups { get; } = new();

    /// <summary>Raised after anything changed (items, groups, links, …).</summary>
    public event Action? Changed;

    public static readonly string Root = MakeRoot();

    private static string MakeRoot()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DropHop");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static string ManifestPath => Path.Combine(Root, "items.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public ShelfStore() => Load();

    // ---------- paths / lookups ----------

    public string FilePath(ShelfItem item) => Path.Combine(Root, item.Id.ToString(), item.Name);

    public string? GroupName(Guid? id) =>
        id == null ? null : Groups.FirstOrDefault(g => g.Id == id)?.Name;

    public List<string> PathsInGroup(Guid id) =>
        Items.Where(i => i.GroupId == id).Select(FilePath).ToList();

    // ---------- items ----------

    /// <summary>
    /// Copies dropped files into the shelf's own storage so they stay available even if the
    /// original is moved or deleted. Folders are zipped on the way in, so the shelf only ever
    /// holds single files.
    /// </summary>
    public async void Add(IEnumerable<string> paths, Guid? group)
    {
        foreach (var path in paths.ToList())
        {
            var id = Guid.NewGuid();
            var dir = Path.Combine(Root, id.ToString());
            try
            {
                bool isDir = Directory.Exists(path);
                string name = isDir
                    ? new DirectoryInfo(path).Name + ".zip"
                    : Path.GetFileName(path);
                string dest = Path.Combine(dir, name);

                long size = await Task.Run(() =>
                {
                    Directory.CreateDirectory(dir);
                    if (isDir) ZipFile.CreateFromDirectory(path, dest, CompressionLevel.Fastest, includeBaseDirectory: true);
                    else File.Copy(path, dest);
                    return new FileInfo(dest).Length;
                });

                var item = new ShelfItem { Id = id, Name = name, Size = size, GroupId = group };
                item.Icon = IconHelper.For(dest);
                Items.Insert(0, item);
                Save();
            }
            catch
            {
                TryDelete(dir);
                System.Media.SystemSounds.Beep.Play();
            }
        }
    }

    public void Remove(ShelfItem item)
    {
        DeleteFiles(item);
        Items.Remove(item);
        Save();
    }

    public void Clear(IEnumerable<ShelfItem> list)
    {
        foreach (var item in list.ToList())
        {
            DeleteFiles(item);
            Items.Remove(item);
        }
        Save();
    }

    public void Move(ShelfItem item, Guid? group)
    {
        item.GroupId = group;
        Save();
    }

    private void DeleteFiles(ShelfItem item) => TryDelete(Path.Combine(Root, item.Id.ToString()));

    private static void TryDelete(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch { }
    }

    // ---------- groups ----------

    public ShelfGroup AddGroup(string name)
    {
        var g = new ShelfGroup { Name = name };
        Groups.Add(g);
        Save();
        return g;
    }

    public void RenameGroup(Guid id, string name)
    {
        var n = name.Trim();
        var g = Groups.FirstOrDefault(x => x.Id == id);
        if (n.Length == 0 || g == null) return;
        g.Name = n;
        Save();
    }

    public void DeleteGroup(Guid id, bool deleteFiles)
    {
        if (deleteFiles) Clear(Items.Where(i => i.GroupId == id));
        else foreach (var i in Items.Where(i => i.GroupId == id)) i.GroupId = null;
        var g = Groups.FirstOrDefault(x => x.Id == id);
        if (g != null) Groups.Remove(g);
        Save();
    }

    // ---------- links ----------

    /// <summary>Uploads one item to a temporary public host and copies the link to the clipboard.</summary>
    public async void MakeLink(ShelfItem item, int hours)
    {
        if (item.Uploading) return;
        item.Uploading = true;
        item.Error = null;
        try
        {
            var r = await Uploader.Upload(FilePath(item), hours);
            item.Link = r.Link;
            item.LinkExpiry = DateTime.Now.AddHours(r.Hours);
            Save();
            Clipboard.Copy(r.Link);
        }
        catch (Exception e)
        {
            item.Error = e.Message;
        }
        item.Uploading = false;
        Changed?.Invoke();
    }

    private readonly HashSet<Guid> _uploadingGroups = new();
    public bool IsUploading(Guid group) => _uploadingGroups.Contains(group);
    public Dictionary<Guid, string> GroupErrors { get; } = new();

    /// <summary>Uploads a whole group as ONE zip file with ONE link.</summary>
    public async void MakeGroupLink(ShelfGroup group, int hours)
    {
        var files = PathsInGroup(group.Id);
        if (files.Count == 0 || !_uploadingGroups.Add(group.Id)) return;
        GroupErrors.Remove(group.Id);
        Changed?.Invoke();
        var name = group.Name.Replace('/', '-').Replace('\\', '-');
        try
        {
            var r = await Uploader.UploadBundle(files, name, hours);
            group.Link = r.Link;
            group.LinkExpiry = DateTime.Now.AddHours(r.Hours);
            Save();
            Clipboard.Copy(r.Link);
        }
        catch (Exception e)
        {
            GroupErrors[group.Id] = e.Message;
        }
        _uploadingGroups.Remove(group.Id);
        Changed?.Invoke();
    }

    /// <summary>Used by phone sync: a public link for the item (reusing a still-valid one), no clipboard.</summary>
    public async Task<string> LinkForSync(Guid itemId, int hours = 24)
    {
        var item = Items.FirstOrDefault(i => i.Id == itemId) ?? throw new InvalidOperationException("No such file");
        if (item.Link != null && item.LinkExpiry is DateTime exp && exp > DateTime.Now.AddMinutes(5))
            return item.Link;

        item.Uploading = true;
        item.Error = null;
        try
        {
            var r = await Uploader.Upload(FilePath(item), hours);
            item.Link = r.Link;
            item.LinkExpiry = DateTime.Now.AddHours(r.Hours);
            Save();
            return r.Link;
        }
        catch (Exception e)
        {
            item.Error = e.Message;
            throw;
        }
        finally
        {
            item.Uploading = false;
            Changed?.Invoke();
        }
    }

    // ---------- persistence ----------

    public void Save()
    {
        try
        {
            var m = new ShelfManifest { Items = Items.ToList(), Groups = Groups.ToList() };
            var tmp = ManifestPath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(m, Json));
            File.Move(tmp, ManifestPath, overwrite: true);
        }
        catch { }
        Changed?.Invoke();
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(ManifestPath)) return;
            var m = JsonSerializer.Deserialize<ShelfManifest>(File.ReadAllText(ManifestPath), Json);
            if (m == null) return;
            foreach (var g in m.Groups) Groups.Add(g);
            foreach (var i in m.Items)
            {
                var path = FilePath(i);
                if (!File.Exists(path)) continue;       // file vanished — drop the entry
                i.Icon = IconHelper.For(path);
                Items.Add(i);
            }
        }
        catch { }
    }

    public static long SizeOf(string path)
    {
        if (File.Exists(path)) return new FileInfo(path).Length;
        if (!Directory.Exists(path)) return 0;
        return new DirectoryInfo(path).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length);
    }
}

public static class Clipboard
{
    /// <summary>The clipboard can be briefly locked by another app, so retry a few times.</summary>
    public static void Copy(string text)
    {
        for (int i = 0; i < 5; i++)
        {
            try { System.Windows.Clipboard.SetText(text); return; }
            catch { System.Threading.Thread.Sleep(40); }
        }
    }

    public static void CopyFiles(IEnumerable<string> paths)
    {
        var list = new System.Collections.Specialized.StringCollection();
        foreach (var p in paths) list.Add(p);
        for (int i = 0; i < 5; i++)
        {
            try { System.Windows.Clipboard.SetFileDropList(list); return; }
            catch { System.Threading.Thread.Sleep(40); }
        }
    }
}
