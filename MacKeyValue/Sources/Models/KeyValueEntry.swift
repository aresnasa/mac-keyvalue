import Foundation

// MARK: - KeyValueEntry

/// Represents a single key-value entry that can store passwords, snippets, or clipboard content.
struct KeyValueEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var key: String        // username / account  / shortcut key
    var url: String        // website URL or host address (optional)
    var encryptedValue: Data
    var category: Category
    var tags: [String]
    var isPrivate: Bool
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var usageCount: Int
    var notes: String

    // MARK: - Category

    enum Category: String, Codable, CaseIterable, Identifiable {
        case password = "password"
        case snippet = "snippet"
        case clipboard = "clipboard"
        case command = "command"
        case other = "other"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .password: return "密码"
            case .snippet: return "代码片段"
            case .clipboard: return "剪贴板"
            case .command: return "命令"
            case .other: return "其他"
            }
        }

        var iconName: String {
            switch self {
            case .password: return "lock.fill"
            case .snippet: return "doc.text.fill"
            case .clipboard: return "doc.on.clipboard.fill"
            case .command: return "terminal.fill"
            case .other: return "square.grid.2x2.fill"
            }
        }
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        title: String,
        key: String,
        url: String = "",
        encryptedValue: Data = Data(),
        category: Category = .other,
        tags: [String] = [],
        isPrivate: Bool = false,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        usageCount: Int = 0,
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.key = key
        self.url = url
        self.encryptedValue = encryptedValue
        self.category = category
        self.tags = tags
        self.isPrivate = isPrivate
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
        self.usageCount = usageCount
        self.notes = notes
    }

    // MARK: - Mutating Helpers

    /// Records a usage event, incrementing the counter and updating the timestamp.
    mutating func recordUsage() {
        usageCount += 1
        lastUsedAt = Date()
        updatedAt = Date()
    }

    /// Returns a copy with an updated encrypted value and timestamp.
    func withUpdatedValue(_ newEncryptedValue: Data) -> KeyValueEntry {
        var copy = self
        copy.encryptedValue = newEncryptedValue
        copy.updatedAt = Date()
        return copy
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: KeyValueEntry, rhs: KeyValueEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - GistSyncMetadata

/// Metadata attached to entries that have been synced to GitHub Gist.
struct GistSyncMetadata: Codable {
    let entryId: UUID
    var gistId: String?
    var gistFileId: String?
    var lastSyncedAt: Date?
    var syncStatus: SyncStatus

    enum SyncStatus: String, Codable {
        case notSynced = "not_synced"
        case synced = "synced"
        case pendingUpload = "pending_upload"
        case pendingDelete = "pending_delete"
        case conflict = "conflict"
        case error = "error"
    }

    init(
        entryId: UUID,
        gistId: String? = nil,
        gistFileId: String? = nil,
        lastSyncedAt: Date? = nil,
        syncStatus: SyncStatus = .notSynced
    ) {
        self.entryId = entryId
        self.gistId = gistId
        self.gistFileId = gistFileId
        self.lastSyncedAt = lastSyncedAt
        self.syncStatus = syncStatus
    }
}

// MARK: - EncryptionEnvelope

/// Wraps encrypted data with the nonce and tag needed for AES-GCM decryption.
struct EncryptionEnvelope: Codable {
    let nonce: Data
    let ciphertext: Data
    let tag: Data

    /// Combines nonce + ciphertext + tag into a single `Data` blob for storage.
    var combined: Data {
        var result = Data()
        result.append(nonce)
        result.append(ciphertext)
        result.append(tag)
        return result
    }

    /// Expected nonce size for AES-GCM (12 bytes).
    static let nonceSize = 12
    /// Expected tag size for AES-GCM (16 bytes).
    static let tagSize = 16

    /// Reconstructs an envelope from a combined data blob previously created by `combined`.
    /// Returns `nil` if the data is too short to contain a valid envelope.
    static func fromCombined(_ data: Data) -> EncryptionEnvelope? {
        guard data.count > nonceSize + tagSize else { return nil }

        let nonce = data.prefix(nonceSize)
        let tag = data.suffix(tagSize)
        let ciphertext = data.dropFirst(nonceSize).dropLast(tagSize)

        return EncryptionEnvelope(
            nonce: Data(nonce),
            ciphertext: Data(ciphertext),
            tag: Data(tag)
        )
    }
}

// MARK: - ClipboardHistoryItem

/// A lightweight record of a clipboard event, used for clipboard history tracking.
struct ClipboardHistoryItem: Identifiable, Codable {
    let id: UUID
    let content: String
    let contentType: ContentType
    let sourceApplication: String?
    let capturedAt: Date
    var isPinned: Bool
    var isPrivate: Bool

    enum ContentType: String, Codable {
        case plainText = "plain_text"
        case richText = "rich_text"
        case url = "url"
        case filePath = "file_path"
        case image = "image"
        case other = "other"

        var displayName: String {
            switch self {
            case .plainText: return "纯文本"
            case .richText: return "富文本"
            case .url: return "链接"
            case .filePath: return "文件路径"
            case .image: return "图片"
            case .other: return "其他"
            }
        }
    }

    init(
        id: UUID = UUID(),
        content: String,
        contentType: ContentType = .plainText,
        sourceApplication: String? = nil,
        capturedAt: Date = Date(),
        isPinned: Bool = false,
        isPrivate: Bool = false
    ) {
        self.id = id
        self.content = content
        self.contentType = contentType
        self.sourceApplication = sourceApplication
        self.capturedAt = capturedAt
        self.isPinned = isPinned
        self.isPrivate = isPrivate
    }
}
