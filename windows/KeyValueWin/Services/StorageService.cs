using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using KeyValueWin.Models;

namespace KeyValueWin.Services;

public sealed class StorageService
{
    // ── Singleton ────────────────────────────────────────────────────────────

    public static readonly StorageService Shared = new();
    private StorageService() { }

    // ── Paths ────────────────────────────────────────────────────────────────

    private static readonly string AppDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MacKeyValue");

    private static string EntriesPath => Path.Combine(AppDir, "entries.json");

    // ── JSON options ─────────────────────────────────────────────────────────

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented      = true,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter() }
    };

    // ── In-memory cache ───────────────────────────────────────────────────────

    private List<KeyValueEntry> _entries = [];
    private readonly object _lock = new();

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    public void Load()
    {
        Directory.CreateDirectory(AppDir);
        lock (_lock)
        {
            _entries = LoadList<KeyValueEntry>(EntriesPath);
        }
    }

    public void Save()
    {
        lock (_lock)
        {
            WriteJson(EntriesPath, _entries);
        }
    }

    // ── CRUD ──────────────────────────────────────────────────────────────────

    public IReadOnlyList<KeyValueEntry> GetAll()
    {
        lock (_lock) { return [.. _entries]; }
    }

    public KeyValueEntry? GetById(Guid id)
    {
        lock (_lock) { return _entries.FirstOrDefault(e => e.Id == id); }
    }

    public IReadOnlyList<KeyValueEntry> Search(string query)
    {
        if (string.IsNullOrWhiteSpace(query)) return GetAll();
        var q = query.ToLowerInvariant();
        lock (_lock)
        {
            return _entries.Where(e =>
                e.Title.Contains(q, StringComparison.OrdinalIgnoreCase)
                || e.Key.Contains(q, StringComparison.OrdinalIgnoreCase)
                || e.Url.Contains(q, StringComparison.OrdinalIgnoreCase)
                || e.Notes.Contains(q, StringComparison.OrdinalIgnoreCase)
                || e.Tags.Any(t => t.Contains(q, StringComparison.OrdinalIgnoreCase))
            ).ToList();
        }
    }

    public void Upsert(KeyValueEntry entry)
    {
        lock (_lock)
        {
            var idx = _entries.FindIndex(e => e.Id == entry.Id);
            entry.UpdatedAt = DateTime.UtcNow.ToString("O");
            if (idx >= 0) _entries[idx] = entry;
            else           _entries.Add(entry);
        }
        Save();
    }

    public bool Delete(Guid id)
    {
        lock (_lock)
        {
            var count = _entries.RemoveAll(e => e.Id == id);
            if (count > 0) { Save(); return true; }
            return false;
        }
    }

    public void BulkInsert(IEnumerable<KeyValueEntry> entries, bool overwrite = false)
    {
        lock (_lock)
        {
            foreach (var entry in entries)
            {
                var idx = _entries.FindIndex(e => e.Id == entry.Id);
                if (idx >= 0 && overwrite) _entries[idx] = entry;
                else if (idx < 0)          _entries.Add(entry);
            }
        }
        Save();
    }

    public int Count { get { lock (_lock) { return _entries.Count; } } }

    // ── Internals ────────────────────────────────────────────────────────────

    private static List<T> LoadList<T>(string path)
    {
        if (!File.Exists(path)) return [];
        try
        {
            var json = File.ReadAllText(path);
            if (string.IsNullOrWhiteSpace(json)) return [];
            // Handle both wrapped bundle and bare array
            if (json.TrimStart().StartsWith('['))
                return JsonSerializer.Deserialize<List<T>>(json, JsonOpts) ?? [];
            var bundle = JsonSerializer.Deserialize<NativeExportBundle>(json, JsonOpts);
            if (bundle?.Entries is List<KeyValueEntry> entries)
                return (List<T>)(object)entries;
            return [];
        }
        catch { return []; }
    }

    private static void WriteJson<T>(string path, T value)
    {
        var backup = path + ".backup";
        if (File.Exists(path)) File.Copy(path, backup, overwrite: true);
        var bundle = new NativeExportBundle { Entries = (List<KeyValueEntry>)(object)value! };
        File.WriteAllText(path, JsonSerializer.Serialize(bundle, JsonOpts));
    }
}
