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

    public static string EntriesPath => Path.Combine(AppDir, "entries.json");

    /// <summary>
    /// Data directory exposed for UI (open-in-explorer, recovery diagnostics).
    /// </summary>
    public static string DataDirectory => AppDir;

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

    /// <summary>
    /// Set to <c>true</c> ONLY after all caches are successfully loaded from
    /// disk. Any <see cref="Save"/> call while this is <c>false</c> is silently
    /// skipped to prevent an empty / partial in-memory state from overwriting
    /// valid on-disk data.
    /// </summary>
    private bool _isDataLoaded;

    // ── Public helpers ────────────────────────────────────────────────────────

    /// <summary>
    /// Returns <c>true</c> if the entries JSON file already exists on disk.
    /// Used by higher layers to detect "key lost but data present" scenarios.
    /// </summary>
    public bool HasExistingEntriesFile => File.Exists(EntriesPath);

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    /// <summary>
    /// Loads entries from disk into the in-memory cache.
    /// Throws on unrecoverable parse failure (callers should show DataRecovery UI).
    /// </summary>
    /// <exception cref="StorageLoadException">
    /// Thrown when the primary file and all backups cannot be decoded.
    /// </exception>
    public void Load()
    {
        Directory.CreateDirectory(AppDir);
        // Load into a temporary so a failure never leaves _entries partially written.
        var loaded = LoadWithFallback(EntriesPath);
        lock (_lock)
        {
            _entries = loaded;
            _isDataLoaded = true;
        }
    }

    public void Save()
    {
        lock (_lock)
        {
            // Safety guard: never write if data was never successfully loaded.
            if (!_isDataLoaded)
            {
                Console.Error.WriteLine("[StorageService] Save skipped — data not yet loaded (_isDataLoaded=false)");
                return;
            }
            WriteJsonRotating(EntriesPath, _entries);
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

    /// <summary>
    /// Deletes ALL data files (all backups included) and resets the in-memory
    /// cache.  Called only from the confirmed data-reset flow.
    /// </summary>
    public void DeleteAllFiles()
    {
        lock (_lock)
        {
            _entries = [];
            _isDataLoaded = false;
        }
        var candidates = new[]
        {
            EntriesPath,
            EntriesPath + ".backup",
            EntriesPath + ".backup.2",
            EntriesPath + ".backup.3",
        };
        foreach (var f in candidates)
            if (File.Exists(f)) File.Delete(f);
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /// <summary>
    /// Loads the primary JSON file; on parse failure tries up to 3 backup
    /// copies (newest first).  Returns an empty list when no file exists yet.
    /// Throws <see cref="StorageLoadException"/> only when every copy is corrupt.
    /// </summary>
    private static List<KeyValueEntry> LoadWithFallback(string path)
    {
        if (!File.Exists(path)) return [];

        var candidates = new[]
        {
            path,
            path + ".backup",
            path + ".backup.2",
            path + ".backup.3",
        };

        Exception? lastEx = null;
        foreach (var candidate in candidates)
        {
            if (!File.Exists(candidate)) continue;
            try
            {
                var json = File.ReadAllText(candidate);
                if (string.IsNullOrWhiteSpace(json)) continue;

                List<KeyValueEntry>? result = null;
                if (json.TrimStart().StartsWith('['))
                    result = JsonSerializer.Deserialize<List<KeyValueEntry>>(json, JsonOpts);
                else
                {
                    var bundle = JsonSerializer.Deserialize<NativeExportBundle>(json, JsonOpts);
                    if (bundle?.Entries is List<KeyValueEntry> bundleEntries)
                        result = bundleEntries;
                }

                if (result is not null)
                {
                    // Restore the primary file from a backup so future saves work normally.
                    if (candidate != path)
                    {
                        Console.Error.WriteLine($"[StorageService] Recovered from backup: {Path.GetFileName(candidate)}");
                        File.Copy(candidate, path, overwrite: true);
                    }
                    return result;
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[StorageService] Failed to parse {Path.GetFileName(candidate)}: {ex.Message}");
                lastEx = ex;
            }
        }

        throw new StorageLoadException(
            $"All data files are unreadable. Last error: {lastEx?.Message}", lastEx);
    }

    /// <summary>
    /// Writes JSON with a 3-level rotating backup:
    ///   .backup.2 ← .backup.1 ← .backup (newest) ← current
    /// Preserves the last 3 states beyond the current live file.
    /// </summary>
    private static void WriteJsonRotating<T>(string path, T value)
    {
        // Rotate existing backups before overwriting.
        var b1 = path + ".backup";
        var b2 = path + ".backup.2";
        var b3 = path + ".backup.3";

        if (File.Exists(b2)) { if (File.Exists(b3)) File.Delete(b3); File.Move(b2, b3); }
        if (File.Exists(b1)) File.Move(b1, b2);
        if (File.Exists(path)) File.Copy(path, b1, overwrite: false);

        // Write atomically via a temp file then rename.
        var tmp = path + ".tmp";
        var bundle = new NativeExportBundle { Entries = (List<KeyValueEntry>)(object)value! };
        File.WriteAllText(tmp, JsonSerializer.Serialize(bundle, JsonOpts));
        File.Move(tmp, path, overwrite: true);
    }
}

/// <summary>Raised when <see cref="StorageService.Load"/> cannot decode any data copy.</summary>
public sealed class StorageLoadException(string message, Exception? inner = null)
    : Exception(message, inner);

