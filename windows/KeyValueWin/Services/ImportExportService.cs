using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using KeyValueWin.Models;

namespace KeyValueWin.Services;

public sealed class ImportExportService
{
    public static readonly ImportExportService Shared = new();
    private ImportExportService() { }

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    // ── Import ────────────────────────────────────────────────────────────────

    public (List<KeyValueEntry> entries, string summary) ImportFromFile(
        string path, string? password = null)
    {
        var ext  = Path.GetExtension(path).ToLowerInvariant();
        var data = File.ReadAllBytes(path);
        var text = Encoding.UTF8.GetString(data);

        if (ext == ".mkve")
        {
            if (string.IsNullOrEmpty(password))
                throw new InvalidOperationException("Password required for .mkve files");
            var json = Encoding.UTF8.GetString(
                EncryptionService.Shared.Decrypt(data, password));
            return ParseNativeJson(json);
        }

        if (ext == ".json")
        {
            if (text.Contains("\"encrypted\"") && text.Contains("\"items\""))
                return ParseBitwardenJson(text);
            return ParseNativeJson(text);
        }

        if (ext is ".csv" or ".txt")
            return ParseCsv(text);

        throw new NotSupportedException($"Unsupported file type: {ext}");
    }

    // ── Export ────────────────────────────────────────────────────────────────

    public byte[] ExportToJson(IEnumerable<KeyValueEntry> entries) =>
        Encoding.UTF8.GetBytes(JsonSerializer.Serialize(
            new NativeExportBundle { Entries = entries.ToList() }, JsonOpts));

    public byte[] ExportToEncryptedJson(IEnumerable<KeyValueEntry> entries, string password) =>
        EncryptionService.Shared.Encrypt(ExportToJson(entries), password);

    public byte[] ExportToCsv(IEnumerable<KeyValueEntry> entries, bool decryptValues = true)
    {
        var sb = new StringBuilder();
        sb.AppendLine("name,username,password,url,notes,category,tags,favorite,created");
        foreach (var e in entries)
        {
            var pw = string.Empty;
            if (decryptValues && e.EncryptedValue.Length >= 28)
            {
                try { pw = EncryptionService.Shared.DecryptToString(e.EncryptedValue); }
                catch { pw = "[decrypt failed]"; }
            }
            sb.AppendLine(string.Join(",",
                CsvEscape(e.Title), CsvEscape(e.Key), CsvEscape(pw),
                CsvEscape(e.Url),   CsvEscape(e.Notes), e.Category,
                CsvEscape(string.Join(";", e.Tags)),
                e.IsFavorite ? "1" : "0", e.CreatedAt));
        }
        return Encoding.UTF8.GetBytes(sb.ToString());
    }

    // ── Parsers ───────────────────────────────────────────────────────────────

    private static (List<KeyValueEntry>, string) ParseNativeJson(string json)
    {
        List<KeyValueEntry>? entries = null;
        if (json.TrimStart().StartsWith('['))
            entries = JsonSerializer.Deserialize<List<KeyValueEntry>>(json, JsonOpts);
        else
        {
            var bundle = JsonSerializer.Deserialize<NativeExportBundle>(json, JsonOpts);
            entries = bundle?.Entries;
        }
        entries ??= [];
        return (entries, $"Imported {entries.Count} entries");
    }

    private (List<KeyValueEntry>, string) ParseBitwardenJson(string json)
    {
        var entries = new List<KeyValueEntry>();
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("items", out var items)) return (entries, "No items");

        foreach (var item in items.EnumerateArray())
        {
            var title = item.TryGetProperty("name", out var n) ? n.GetString() ?? "Untitled" : "Untitled";
            var notes = item.TryGetProperty("notes", out var no) ? no.GetString() ?? "" : "";
            var username = "";
            var password = "";
            var url = "";

            if (item.TryGetProperty("login", out var login))
            {
                username = login.TryGetProperty("username", out var u) ? u.GetString() ?? "" : "";
                password = login.TryGetProperty("password", out var p) ? p.GetString() ?? "" : "";
                if (login.TryGetProperty("uris", out var uris) && uris.GetArrayLength() > 0)
                    url = uris[0].TryGetProperty("uri", out var uri) ? uri.GetString() ?? "" : "";
            }

            var entry = MakeEntry(title, username, password, url, notes);
            if (entry is not null) entries.Add(entry);
        }
        return (entries, $"Imported {entries.Count} entries from Bitwarden");
    }

    private (List<KeyValueEntry>, string) ParseCsv(string text)
    {
        var rows = ParseCsvRows(text);
        if (rows.Count == 0) return ([], "Empty file");

        var header = rows[0].Select(h => h.ToLowerInvariant()).ToList();
        int? iTitle = FindCol(header, "name", "title", "account");
        int? iUser  = FindCol(header, "username", "login", "email", "login name");
        int? iPass  = FindCol(header, "password", "pass");
        int? iUrl   = FindCol(header, "url", "website", "web site", "uri");
        int? iNotes = FindCol(header, "notes", "extra", "comment");

        var entries = new List<KeyValueEntry>();
        foreach (var row in rows.Skip(1))
        {
            if (row.All(string.IsNullOrWhiteSpace)) continue;
            string Get(int? i) => i.HasValue && i.Value < row.Count ? row[i.Value] : "";
            var entry = MakeEntry(
                title:    Get(iTitle).DefaultIfEmpty("Untitled"),
                username: Get(iUser),
                password: Get(iPass),
                url:      Get(iUrl),
                notes:    Get(iNotes));
            if (entry is not null) entries.Add(entry);
        }
        return (entries, $"Imported {entries.Count} entries from CSV");
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static int? FindCol(List<string> header, params string[] candidates)
    {
        foreach (var c in candidates)
        {
            var i = header.FindIndex(h => h.Contains(c, StringComparison.OrdinalIgnoreCase));
            if (i >= 0) return i;
        }
        return null;
    }

    private static KeyValueEntry? MakeEntry(string title, string username,
        string password, string url = "", string notes = "",
        string category = "password")
    {
        try
        {
            var encrypted = string.IsNullOrEmpty(password)
                ? []
                : EncryptionService.Shared.Encrypt(password);
            return new KeyValueEntry
            {
                Title          = title,
                Key            = username,
                Url            = url,
                EncryptedValue = encrypted,
                Category       = category,
                Notes          = notes
            };
        }
        catch { return null; }
    }

    /// RFC 4180-compliant CSV tokeniser.
    private static List<List<string>> ParseCsvRows(string text)
    {
        var rows = new List<List<string>>();
        var row  = new List<string>();
        var field = new StringBuilder();
        bool inQuotes = false;
        int i = 0;

        while (i < text.Length)
        {
            char c = text[i];
            if (inQuotes)
            {
                if (c == '"')
                {
                    if (i + 1 < text.Length && text[i + 1] == '"') { field.Append('"'); i++; }
                    else inQuotes = false;
                }
                else field.Append(c);
            }
            else
            {
                if      (c == '"') inQuotes = true;
                else if (c == ',') { row.Add(field.ToString()); field.Clear(); }
                else if (c is '\n' or '\r')
                {
                    row.Add(field.ToString()); field.Clear();
                    if (row.Count > 0) rows.Add(row);
                    row = [];
                    if (c == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                }
                else field.Append(c);
            }
            i++;
        }
        row.Add(field.ToString());
        if (row.Any(f => !string.IsNullOrEmpty(f))) rows.Add(row);
        return rows;
    }

    private static string CsvEscape(string s)
    {
        if (s.Contains(',') || s.Contains('"') || s.Contains('\n'))
            return '"' + s.Replace("\"", "\"\"") + '"';
        return s;
    }
}

internal static class StringExtensions
{
    public static string DefaultIfEmpty(this string s, string def) =>
        string.IsNullOrWhiteSpace(s) ? def : s;
}
