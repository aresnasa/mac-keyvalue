import Foundation

// MARK: - StorageError

enum StorageError: LocalizedError {
    case directoryCreationFailed(String)
    case fileWriteFailed(String)
    case fileReadFailed(String)
    case fileDeleteFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case entryNotFound(UUID)
    case dataCorrupted(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let reason):
            return "Failed to create storage directory: \(reason)"
        case .fileWriteFailed(let reason):
            return "Failed to write file: \(reason)"
        case .fileReadFailed(let reason):
            return "Failed to read file: \(reason)"
        case .fileDeleteFailed(let reason):
            return "Failed to delete file: \(reason)"
        case .encodingFailed(let reason):
            return "Failed to encode data: \(reason)"
        case .decodingFailed(let reason):
            return "Failed to decode data: \(reason)"
        case .entryNotFound(let id):
            return "Entry not found: \(id)"
        case .dataCorrupted(let reason):
            return "Data corrupted: \(reason)"
        case .migrationFailed(let reason):
            return "Migration failed: \(reason)"
        }
    }
}

// MARK: - StorageConfiguration

struct StorageConfiguration {
    let baseDirectory: URL
    let entriesFileName: String
    let clipboardHistoryFileName: String
    let syncMetadataFileName: String
    let settingsFileName: String
    let maxClipboardHistoryCount: Int
    let autoSaveInterval: TimeInterval

    static var `default`: StorageConfiguration {
        // Resolve ~/Library/Application Support.
        //
        // On bare executables (swift run / Xcode SPM) the system's internal
        // FSFindFolder may print a harmless warning about missing bundle
        // directories.  Using NSHomeDirectory-based fallback silences this.
        let appSupport: URL = {
            if let dir = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first {
                return dir
            }
            // Fallback: construct the path manually.
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        }()

        let baseDir = appSupport.appendingPathComponent("MacKeyValue", isDirectory: true)

        // Pre-create the directory so later file operations don't fail.
        try? FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true
        )

        return StorageConfiguration(
            baseDirectory: baseDir,
            entriesFileName: "entries.json",
            clipboardHistoryFileName: "clipboard_history.json",
            syncMetadataFileName: "sync_metadata.json",
            settingsFileName: "settings.json",
            maxClipboardHistoryCount: 500,
            autoSaveInterval: 5.0
        )
    }
}

// MARK: - StorageService

/// Manages local persistence of key-value entries, clipboard history, and sync metadata.
///
/// All data is stored as JSON files in the Application Support directory. Writes are
/// serialized through a dedicated dispatch queue to prevent data races. An in-memory
/// cache is maintained for fast reads, with periodic auto-save to disk.
final class StorageService {

    // MARK: - Singleton

    static let shared = StorageService()

    // MARK: - Properties

    private let configuration: StorageConfiguration
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.mackeyvalue.storage", qos: .userInitiated)

    /// In-memory caches
    private var entriesCache: [KeyValueEntry] = []
    private var clipboardHistoryCache: [ClipboardHistoryItem] = []
    private var syncMetadataCache: [GistSyncMetadata] = []

    /// Dirty flags to avoid unnecessary disk writes
    private var entriesDirty = false
    private var clipboardHistoryDirty = false
    private var syncMetadataDirty = false

    /// Auto-save timer
    private var autoSaveTimer: DispatchSourceTimer?

    /// JSON encoder / decoder configured for pretty-printing and ISO-8601 dates
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    // MARK: - Initialization

    init(configuration: StorageConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Setup

    /// Prepares the storage layer: creates directories, loads caches, starts auto-save.
    func setup() throws {
        try ensureDirectoryExists()
        try loadAllCaches()
        startAutoSave()
    }

    /// Tears down the storage layer: saves pending changes and stops auto-save.
    func teardown() {
        stopAutoSave()
        try? saveAllDirty()
    }

    // MARK: - Directory Management

    private func ensureDirectoryExists() throws {
        let dir = configuration.baseDirectory
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw StorageError.directoryCreationFailed(error.localizedDescription)
            }
        }
    }

    private func fileURL(for fileName: String) -> URL {
        configuration.baseDirectory.appendingPathComponent(fileName)
    }

    // MARK: - Entries CRUD

    /// Returns all stored entries.
    func getAllEntries() -> [KeyValueEntry] {
        queue.sync { entriesCache }
    }

    /// Returns a single entry by its `id`, or `nil` if not found.
    func getEntry(byId id: UUID) -> KeyValueEntry? {
        queue.sync { entriesCache.first(where: { $0.id == id }) }
    }

    /// Returns entries matching a search query against title, key, tags, and notes.
    ///
    /// If the query starts with `/` and ends with `/`, it is treated as a
    /// **regular expression** (case-insensitive).  For example `/vm-.*pass/`
    /// matches any entry whose title/key/tags/notes contain "vm-" followed by
    /// "pass".  If the regex is invalid, falls back to literal substring search.
    func searchEntries(query: String) -> [KeyValueEntry] {
        // ── Regex mode: /pattern/ ──
        if query.count >= 2 && query.hasPrefix("/") && query.hasSuffix("/") {
            let pattern = String(query.dropFirst().dropLast())
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                return queue.sync {
                    entriesCache.filter { entry in
                        let fields = [
                            entry.title,
                            entry.key,
                            entry.notes,
                        ] + entry.tags
                        return fields.contains { field in
                            let range = NSRange(field.startIndex..., in: field)
                            return regex.firstMatch(in: field, range: range) != nil
                        }
                    }
                }
            }
            // Invalid regex — fall through to literal search.
        }

        // ── Literal substring search ──
        let lowered = query.lowercased()
        return queue.sync {
            entriesCache.filter { entry in
                entry.title.lowercased().contains(lowered)
                    || entry.key.lowercased().contains(lowered)
                    || entry.tags.contains(where: { $0.lowercased().contains(lowered) })
                    || entry.notes.lowercased().contains(lowered)
            }
        }
    }

    /// Returns entries filtered by category.
    func getEntries(byCategory category: KeyValueEntry.Category) -> [KeyValueEntry] {
        queue.sync { entriesCache.filter { $0.category == category } }
    }

    /// Returns entries filtered by privacy mode.
    func getEntries(isPrivate: Bool) -> [KeyValueEntry] {
        queue.sync { entriesCache.filter { $0.isPrivate == isPrivate } }
    }

    /// Returns favorite entries sorted by usage count (descending).
    func getFavoriteEntries() -> [KeyValueEntry] {
        queue.sync {
            entriesCache
                .filter { $0.isFavorite }
                .sorted { $0.usageCount > $1.usageCount }
        }
    }

    /// Adds a new entry. Throws if an entry with the same `id` already exists.
    @discardableResult
    func addEntry(_ entry: KeyValueEntry) throws -> KeyValueEntry {
        try queue.sync {
            guard !entriesCache.contains(where: { $0.id == entry.id }) else {
                throw StorageError.encodingFailed("Entry with id \(entry.id) already exists")
            }
            entriesCache.append(entry)
            entriesDirty = true
            return entry
        }
    }

    /// Updates an existing entry. Throws `entryNotFound` if the entry doesn't exist.
    @discardableResult
    func updateEntry(_ entry: KeyValueEntry) throws -> KeyValueEntry {
        try queue.sync {
            guard let index = entriesCache.firstIndex(where: { $0.id == entry.id }) else {
                throw StorageError.entryNotFound(entry.id)
            }
            entriesCache[index] = entry
            entriesDirty = true
            return entry
        }
    }

    /// Saves an entry – inserts it if new, updates it if it already exists.
    @discardableResult
    func saveEntry(_ entry: KeyValueEntry) -> KeyValueEntry {
        queue.sync {
            if let index = entriesCache.firstIndex(where: { $0.id == entry.id }) {
                entriesCache[index] = entry
            } else {
                entriesCache.append(entry)
            }
            entriesDirty = true
            return entry
        }
    }

    /// Deletes an entry by `id`. Returns the deleted entry, or throws if not found.
    @discardableResult
    func deleteEntry(byId id: UUID) throws -> KeyValueEntry {
        try queue.sync {
            guard let index = entriesCache.firstIndex(where: { $0.id == id }) else {
                throw StorageError.entryNotFound(id)
            }
            let removed = entriesCache.remove(at: index)
            entriesDirty = true
            return removed
        }
    }

    /// Deletes all entries. Returns the count of entries that were removed.
    @discardableResult
    func deleteAllEntries() -> Int {
        queue.sync {
            let count = entriesCache.count
            entriesCache.removeAll()
            entriesDirty = true
            return count
        }
    }

    /// Records a usage event on an entry (increments counter, updates timestamp).
    func recordEntryUsage(id: UUID) throws {
        try queue.sync {
            guard let index = entriesCache.firstIndex(where: { $0.id == id }) else {
                throw StorageError.entryNotFound(id)
            }
            entriesCache[index].recordUsage()
            entriesDirty = true
        }
    }

    // MARK: - Clipboard History

    /// Returns the full clipboard history, newest first.
    func getClipboardHistory() -> [ClipboardHistoryItem] {
        queue.sync {
            clipboardHistoryCache.sorted { $0.capturedAt > $1.capturedAt }
        }
    }

    /// Returns clipboard history items that match a text query.
    func searchClipboardHistory(query: String) -> [ClipboardHistoryItem] {
        let lowered = query.lowercased()
        return queue.sync {
            clipboardHistoryCache
                .filter { $0.content.lowercased().contains(lowered) }
                .sorted { $0.capturedAt > $1.capturedAt }
        }
    }

    /// Adds a new clipboard history item, trimming the oldest non-pinned entries if over limit.
    func addClipboardHistoryItem(_ item: ClipboardHistoryItem) {
        queue.sync {
            // Deduplicate: remove previous identical content (keep the newest)
            clipboardHistoryCache.removeAll { $0.content == item.content && !$0.isPinned }
            clipboardHistoryCache.append(item)

            // Trim if over the maximum
            trimClipboardHistory()
            clipboardHistoryDirty = true
        }
    }

    /// Toggles the `isPinned` flag on a clipboard history item.
    func toggleClipboardItemPin(id: UUID) {
        queue.sync {
            guard let index = clipboardHistoryCache.firstIndex(where: { $0.id == id }) else { return }
            clipboardHistoryCache[index].isPinned.toggle()
            clipboardHistoryDirty = true
        }
    }

    /// Deletes a clipboard history item by `id`.
    func deleteClipboardHistoryItem(id: UUID) {
        queue.sync {
            clipboardHistoryCache.removeAll { $0.id == id }
            clipboardHistoryDirty = true
        }
    }

    /// Clears all non-pinned clipboard history items.
    func clearClipboardHistory(keepPinned: Bool = true) {
        queue.sync {
            if keepPinned {
                clipboardHistoryCache.removeAll { !$0.isPinned }
            } else {
                clipboardHistoryCache.removeAll()
            }
            clipboardHistoryDirty = true
        }
    }

    private func trimClipboardHistory() {
        let pinnedCount = clipboardHistoryCache.filter { $0.isPinned }.count
        let maxUnpinned = configuration.maxClipboardHistoryCount - pinnedCount

        let unpinned = clipboardHistoryCache
            .filter { !$0.isPinned }
            .sorted { $0.capturedAt > $1.capturedAt }

        if unpinned.count > maxUnpinned {
            let overflow = unpinned.count - maxUnpinned
            let toRemove = Set(unpinned.suffix(overflow).map { $0.id })
            clipboardHistoryCache.removeAll { toRemove.contains($0.id) }
        }
    }

    // MARK: - Sync Metadata

    /// Returns all sync metadata records.
    func getAllSyncMetadata() -> [GistSyncMetadata] {
        queue.sync { syncMetadataCache }
    }

    /// Returns sync metadata for a specific entry.
    func getSyncMetadata(forEntryId entryId: UUID) -> GistSyncMetadata? {
        queue.sync { syncMetadataCache.first(where: { $0.entryId == entryId }) }
    }

    /// Saves or updates sync metadata for an entry.
    func saveSyncMetadata(_ metadata: GistSyncMetadata) {
        queue.sync {
            if let index = syncMetadataCache.firstIndex(where: { $0.entryId == metadata.entryId }) {
                syncMetadataCache[index] = metadata
            } else {
                syncMetadataCache.append(metadata)
            }
            syncMetadataDirty = true
        }
    }

    /// Deletes sync metadata for a specific entry.
    func deleteSyncMetadata(forEntryId entryId: UUID) {
        queue.sync {
            syncMetadataCache.removeAll { $0.entryId == entryId }
            syncMetadataDirty = true
        }
    }

    // MARK: - Persistence – Load

    private func loadAllCaches() throws {
        try queue.sync {
            entriesCache = try loadFromFile(
                fileName: configuration.entriesFileName,
                type: [KeyValueEntry].self
            ) ?? []

            clipboardHistoryCache = try loadFromFile(
                fileName: configuration.clipboardHistoryFileName,
                type: [ClipboardHistoryItem].self
            ) ?? []

            syncMetadataCache = try loadFromFile(
                fileName: configuration.syncMetadataFileName,
                type: [GistSyncMetadata].self
            ) ?? []
        }
    }

    private func loadFromFile<T: Decodable>(fileName: String, type: T.Type) throws -> T? {
        let url = fileURL(for: fileName)

        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return nil }
            return try decoder.decode(T.self, from: data)
        } catch let decodingError as DecodingError {
            // Attempt to read the backup
            let backupURL = url.appendingPathExtension("backup")
            if fileManager.fileExists(atPath: backupURL.path),
               let backupData = try? Data(contentsOf: backupURL),
               let decoded = try? decoder.decode(T.self, from: backupData) {
                // Restore from backup
                try? backupData.write(to: url, options: .atomic)
                return decoded
            }
            throw StorageError.decodingFailed(
                "Failed to decode \(fileName): \(decodingError.localizedDescription)"
            )
        } catch {
            throw StorageError.fileReadFailed(error.localizedDescription)
        }
    }

    // MARK: - Persistence – Save

    /// Forces an immediate save of all dirty caches to disk.
    func saveAllDirty() throws {
        try queue.sync {
            if entriesDirty {
                try saveToFile(entriesCache, fileName: configuration.entriesFileName)
                entriesDirty = false
            }
            if clipboardHistoryDirty {
                try saveToFile(clipboardHistoryCache, fileName: configuration.clipboardHistoryFileName)
                clipboardHistoryDirty = false
            }
            if syncMetadataDirty {
                try saveToFile(syncMetadataCache, fileName: configuration.syncMetadataFileName)
                syncMetadataDirty = false
            }
        }
    }

    /// Forces an immediate save of entries to disk, regardless of dirty flag.
    func forceSaveEntries() throws {
        try queue.sync {
            try saveToFile(entriesCache, fileName: configuration.entriesFileName)
            entriesDirty = false
        }
    }

    private func saveToFile<T: Encodable>(_ value: T, fileName: String) throws {
        let url = fileURL(for: fileName)

        do {
            let data = try encoder.encode(value)

            // Create a backup of the existing file before overwriting
            if fileManager.fileExists(atPath: url.path) {
                let backupURL = url.appendingPathExtension("backup")
                try? fileManager.removeItem(at: backupURL)
                try? fileManager.copyItem(at: url, to: backupURL)
            }

            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch let encodingError as EncodingError {
            throw StorageError.encodingFailed(
                "Failed to encode data for \(fileName): \(encodingError.localizedDescription)"
            )
        } catch {
            throw StorageError.fileWriteFailed(
                "Failed to write \(fileName): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Auto-Save

    private func startAutoSave() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + configuration.autoSaveInterval,
            repeating: configuration.autoSaveInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            try? self?.performAutoSave()
        }
        timer.resume()
        autoSaveTimer = timer
    }

    private func stopAutoSave() {
        autoSaveTimer?.cancel()
        autoSaveTimer = nil
    }

    /// Called by the auto-save timer. Must be invoked on `queue`.
    private func performAutoSave() throws {
        if entriesDirty {
            try saveToFile(entriesCache, fileName: configuration.entriesFileName)
            entriesDirty = false
        }
        if clipboardHistoryDirty {
            try saveToFile(clipboardHistoryCache, fileName: configuration.clipboardHistoryFileName)
            clipboardHistoryDirty = false
        }
        if syncMetadataDirty {
            try saveToFile(syncMetadataCache, fileName: configuration.syncMetadataFileName)
            syncMetadataDirty = false
        }
    }

    // MARK: - Import / Export

    /// Exports all non-private entries as a JSON `Data` blob (for Gist sync, etc.).
    func exportEntries(includePrivate: Bool = false) throws -> Data {
        let entries = queue.sync {
            includePrivate ? entriesCache : entriesCache.filter { !$0.isPrivate }
        }
        return try encoder.encode(entries)
    }

    /// Imports entries from a JSON `Data` blob, merging with existing data.
    /// Existing entries with the same `id` are updated; new entries are appended.
    /// Returns the number of entries imported/updated.
    @discardableResult
    func importEntries(from data: Data, overwriteExisting: Bool = false) throws -> Int {
        let incoming: [KeyValueEntry]
        do {
            incoming = try decoder.decode([KeyValueEntry].self, from: data)
        } catch {
            throw StorageError.decodingFailed("Failed to decode imported entries: \(error.localizedDescription)")
        }

        return queue.sync {
            var count = 0
            for entry in incoming {
                if let index = entriesCache.firstIndex(where: { $0.id == entry.id }) {
                    if overwriteExisting {
                        entriesCache[index] = entry
                        count += 1
                    }
                } else {
                    entriesCache.append(entry)
                    count += 1
                }
            }
            if count > 0 {
                entriesDirty = true
            }
            return count
        }
    }

    // MARK: - Storage Info

    /// Returns the total disk usage of all storage files in bytes.
    func storageSize() -> UInt64 {
        let fileNames = [
            configuration.entriesFileName,
            configuration.clipboardHistoryFileName,
            configuration.syncMetadataFileName,
            configuration.settingsFileName,
        ]

        var total: UInt64 = 0
        for name in fileNames {
            let url = fileURL(for: name)
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? UInt64 {
                total += size
            }
        }
        return total
    }

    /// Returns a human-readable string of the storage size.
    func formattedStorageSize() -> String {
        let bytes = storageSize()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Returns the base storage directory URL.
    var storageDirectory: URL {
        configuration.baseDirectory
    }

    /// Returns the total number of entries in the store.
    var entryCount: Int {
        queue.sync { entriesCache.count }
    }

    /// Returns the total number of clipboard history items.
    var clipboardHistoryCount: Int {
        queue.sync { clipboardHistoryCache.count }
    }
}
