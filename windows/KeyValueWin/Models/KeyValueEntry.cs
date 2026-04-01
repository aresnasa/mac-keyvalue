using System.Text.Json.Serialization;

namespace KeyValueWin.Models;

// ── Category ──────────────────────────────────────────────────────────────────

public enum EntryCategory
{
    [JsonPropertyName("password")]  Password,
    [JsonPropertyName("snippet")]   Snippet,
    [JsonPropertyName("clipboard")] Clipboard,
    [JsonPropertyName("command")]   Command,
    [JsonPropertyName("other")]     Other
}

// ── KeyValueEntry ─────────────────────────────────────────────────────────────

/// Data model – byte-for-byte compatible with the Swift MacKeyValue model.
public class KeyValueEntry
{
    [JsonPropertyName("id")]             public Guid   Id             { get; set; } = Guid.NewGuid();
    [JsonPropertyName("title")]          public string Title          { get; set; } = string.Empty;
    [JsonPropertyName("key")]            public string Key            { get; set; } = string.Empty;
    [JsonPropertyName("url")]            public string Url            { get; set; } = string.Empty;
    [JsonPropertyName("encryptedValue")] public byte[] EncryptedValue { get; set; } = [];
    [JsonPropertyName("category")]       public string Category       { get; set; } = "other";
    [JsonPropertyName("tags")]           public List<string> Tags     { get; set; } = [];
    [JsonPropertyName("isPrivate")]      public bool   IsPrivate      { get; set; }
    [JsonPropertyName("isFavorite")]     public bool   IsFavorite     { get; set; }
    [JsonPropertyName("createdAt")]      public string CreatedAt      { get; set; } = DateTime.UtcNow.ToString("O");
    [JsonPropertyName("updatedAt")]      public string UpdatedAt      { get; set; } = DateTime.UtcNow.ToString("O");
    [JsonPropertyName("lastUsedAt")]     public string? LastUsedAt    { get; set; }
    [JsonPropertyName("usageCount")]     public int    UsageCount     { get; set; }
    [JsonPropertyName("notes")]          public string Notes          { get; set; } = string.Empty;

    // ── Display helpers ──────────────────────────────────────────────────────

    public string CategoryIcon => Category switch
    {
        "password"  => "🔒",
        "snippet"   => "📄",
        "clipboard" => "📋",
        "command"   => "⌨",
        _           => "📦"
    };

    public string CategoryDisplayName => Category switch
    {
        "password"  => "Password",
        "snippet"   => "Snippet",
        "clipboard" => "Clipboard",
        "command"   => "Command",
        _           => "Other"
    };

    public bool HasValue => EncryptedValue.Length >= 28;
}

// ── Export bundle (mirrors Swift NativeExportBundle) ─────────────────────────

public class NativeExportBundle
{
    [JsonPropertyName("version")]    public int              Version    { get; set; } = 1;
    [JsonPropertyName("format")]     public string           Format     { get; set; } = "mackeyvalue";
    [JsonPropertyName("exportedAt")] public string           ExportedAt { get; set; } = DateTime.UtcNow.ToString("O");
    [JsonPropertyName("entries")]    public List<KeyValueEntry> Entries { get; set; } = [];
}
