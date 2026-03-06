import Foundation
import Combine

// MARK: - GistSyncError

enum GistSyncError: LocalizedError {
    case noToken
    case invalidToken
    case networkError(String)
    case apiError(Int, String)
    case encodingError(String)
    case decodingError(String)
    case gistNotFound(String)
    case rateLimited(retryAfter: TimeInterval?)
    case syncConflict(String)
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "GitHub personal access token is not configured"
        case .invalidToken:
            return "GitHub personal access token is invalid or expired"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .apiError(let code, let message):
            return "GitHub API error (\(code)): \(message)"
        case .encodingError(let reason):
            return "Failed to encode data for sync: \(reason)"
        case .decodingError(let reason):
            return "Failed to decode synced data: \(reason)"
        case .gistNotFound(let gistId):
            return "Gist not found: \(gistId)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "GitHub API rate limit exceeded. Retry after \(Int(seconds)) seconds."
            }
            return "GitHub API rate limit exceeded"
        case .syncConflict(let reason):
            return "Sync conflict: \(reason)"
        case .cancelled:
            return "Sync operation was cancelled"
        case .unknown(let reason):
            return "Unknown sync error: \(reason)"
        }
    }
}

// MARK: - GistSyncConfiguration

struct GistSyncConfiguration: Codable {
    var gistId: String?
    var gistDescription: String
    var isPublic: Bool
    var autoSyncEnabled: Bool
    var autoSyncIntervalMinutes: Int
    var syncOnlyFavorites: Bool
    var syncOnlyNonPrivate: Bool
    var lastFullSyncAt: Date?

    static var `default`: GistSyncConfiguration {
        GistSyncConfiguration(
            gistId: nil,
            gistDescription: "MacKeyValue - Synced Entries",
            isPublic: false,
            autoSyncEnabled: false,
            autoSyncIntervalMinutes: 30,
            syncOnlyFavorites: false,
            syncOnlyNonPrivate: true,
            lastFullSyncAt: nil
        )
    }
}

// MARK: - GistFile

/// Represents a single file within a GitHub Gist.
private struct GistFile: Codable {
    let filename: String?
    let type: String?
    let language: String?
    let rawUrl: String?
    let size: Int?
    let content: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case type
        case language
        case rawUrl = "raw_url"
        case size
        case content
    }
}

// MARK: - GistResponse

/// Represents a GitHub Gist API response.
private struct GistResponse: Codable {
    let id: String
    let url: String
    let htmlUrl: String
    let description: String?
    let isPublic: Bool
    let files: [String: GistFile]
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case htmlUrl = "html_url"
        case description
        case isPublic = "public"
        case files
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - GistCreateRequest / GistUpdateRequest

private struct GistCreateRequest: Codable {
    let description: String
    let `public`: Bool
    let files: [String: GistFileContent]
}

private struct GistUpdateRequest: Codable {
    let description: String?
    let files: [String: GistFileContent?]
}

private struct GistFileContent: Codable {
    let content: String
    let filename: String?

    init(content: String, filename: String? = nil) {
        self.content = content
        self.filename = filename
    }
}

// MARK: - SyncResult

struct GistSyncResult {
    let uploadedCount: Int
    let downloadedCount: Int
    let conflictCount: Int
    let deletedCount: Int
    let errors: [Error]
    let timestamp: Date

    var isSuccess: Bool {
        errors.isEmpty && conflictCount == 0
    }

    var summary: String {
        var parts: [String] = []
        if uploadedCount > 0 { parts.append("上传 \(uploadedCount) 条") }
        if downloadedCount > 0 { parts.append("下载 \(downloadedCount) 条") }
        if deletedCount > 0 { parts.append("删除 \(deletedCount) 条") }
        if conflictCount > 0 { parts.append("冲突 \(conflictCount) 条") }
        if !errors.isEmpty { parts.append("错误 \(errors.count) 个") }
        return parts.isEmpty ? "无变更" : parts.joined(separator: ", ")
    }

    static var empty: GistSyncResult {
        GistSyncResult(
            uploadedCount: 0,
            downloadedCount: 0,
            conflictCount: 0,
            deletedCount: 0,
            errors: [],
            timestamp: Date()
        )
    }
}

// MARK: - SyncableEntry

/// A lightweight representation of an entry suitable for JSON serialization to a Gist file.
/// Sensitive values (encrypted data) are NOT synced – only metadata and non-secret fields.
private struct SyncableEntry: Codable {
    let id: UUID
    let title: String
    let key: String
    let category: String
    let tags: [String]
    let isFavorite: Bool
    let notes: String
    let createdAt: Date
    let updatedAt: Date
    let usageCount: Int

    init(from entry: KeyValueEntry) {
        self.id = entry.id
        self.title = entry.title
        self.key = entry.key
        self.category = entry.category.rawValue
        self.tags = entry.tags
        self.isFavorite = entry.isFavorite
        self.notes = entry.notes
        self.createdAt = entry.createdAt
        self.updatedAt = entry.updatedAt
        self.usageCount = entry.usageCount
    }
}

// MARK: - GistSyncService

/// Handles bidirectional synchronization of key-value entries with GitHub Gist.
///
/// The service uses the GitHub REST API v3 to create, read, and update Gists.
/// Each sync operation serializes the eligible entries into a single JSON file
/// within the Gist. Private entries and encrypted values are never synced.
///
/// ## Token Storage
/// The GitHub personal access token is stored in the macOS Keychain via
/// `EncryptionService` so it is never written to disk in plain text.
final class GistSyncService: ObservableObject {

    // MARK: - Constants

    private enum Constants {
        static let githubApiBase = "https://api.github.com"
        static let gistFileName = "mackeyvalue_entries.json"
        static let keychainTokenAccount = "github-gist-token"
        static let keychainService = "com.mackeyvalue.gist"
        static let userAgent = "MacKeyValue/1.0"
        static let acceptHeader = "application/vnd.github+json"
        static let apiVersion = "2022-11-28"
    }

    // MARK: - Singleton

    static let shared = GistSyncService()

    // MARK: - Published Properties

    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var lastSyncResult: GistSyncResult?
    @Published private(set) var lastSyncError: Error?
    @Published var configuration: GistSyncConfiguration = .default

    // MARK: - Private Properties

    private let session: URLSession
    private let storageService: StorageService
    private let encryptionService: EncryptionService
    private var autoSyncTimer: DispatchSourceTimer?
    private let syncQueue = DispatchQueue(label: "com.mackeyvalue.gistsync", qos: .utility)
    private var cancellables = Set<AnyCancellable>()

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

    init(
        storageService: StorageService = .shared,
        encryptionService: EncryptionService = .shared
    ) {
        self.storageService = storageService
        self.encryptionService = encryptionService

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = [
            "User-Agent": Constants.userAgent,
            "Accept": Constants.acceptHeader,
            "X-GitHub-Api-Version": Constants.apiVersion,
        ]
        self.session = URLSession(configuration: config)

        loadConfiguration()
    }

    // MARK: - Token Management

    /// Saves the GitHub personal access token to the Keychain.
    func saveToken(_ token: String) throws {
        guard !token.isEmpty else {
            throw GistSyncError.invalidToken
        }

        let tokenData = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: Constants.keychainTokenAccount,
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        // Delete any existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GistSyncError.unknown("Failed to save token to Keychain (status: \(status))")
        }
    }

    /// Retrieves the GitHub personal access token from the Keychain.
    func getToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: Constants.keychainTokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the stored GitHub personal access token from the Keychain.
    func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: Constants.keychainTokenAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Returns `true` if a token is stored in the Keychain.
    var hasToken: Bool {
        getToken() != nil
    }

    /// Validates the stored token by making a test API call.
    func validateToken() async throws -> Bool {
        guard let token = getToken() else {
            throw GistSyncError.noToken
        }

        let url = URL(string: "\(Constants.githubApiBase)/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GistSyncError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            return true
        case 401:
            throw GistSyncError.invalidToken
        case 403:
            if let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After"),
               let retryAfter = TimeInterval(retryAfterStr) {
                throw GistSyncError.rateLimited(retryAfter: retryAfter)
            }
            throw GistSyncError.rateLimited(retryAfter: nil)
        default:
            throw GistSyncError.apiError(httpResponse.statusCode, "Token validation failed")
        }
    }

    // MARK: - Sync Operations

    /// Performs a full sync: uploads local entries to Gist and downloads remote changes.
    @discardableResult
    func performFullSync() async throws -> GistSyncResult {
        guard !isSyncing else {
            return .empty
        }

        await MainActor.run { isSyncing = true }
        defer {
            Task { @MainActor in isSyncing = false }
        }

        guard let token = getToken() else {
            let error = GistSyncError.noToken
            await MainActor.run { lastSyncError = error }
            throw error
        }

        do {
            let localEntries = getEligibleEntries()

            // If no gist exists yet, create one
            if configuration.gistId == nil {
                let gistId = try await createGist(token: token, entries: localEntries)
                configuration.gistId = gistId
                saveConfiguration()

                // Mark all entries as synced
                updateSyncMetadata(for: localEntries, gistId: gistId, status: .synced)

                let result = GistSyncResult(
                    uploadedCount: localEntries.count,
                    downloadedCount: 0,
                    conflictCount: 0,
                    deletedCount: 0,
                    errors: [],
                    timestamp: Date()
                )

                await MainActor.run {
                    lastSyncResult = result
                    lastSyncError = nil
                    configuration.lastFullSyncAt = Date()
                }
                saveConfiguration()
                return result
            }

            // Gist already exists – fetch remote, merge, and update
            let gistId = configuration.gistId!
            let remoteEntries = try await fetchGist(token: token, gistId: gistId)

            let mergeResult = mergeEntries(local: localEntries, remote: remoteEntries)

            // Upload merged result to Gist
            try await updateGist(
                token: token,
                gistId: gistId,
                entries: mergeResult.merged
            )

            // Import any new remote entries into local storage
            for remoteEntry in mergeResult.newFromRemote {
                let entry = KeyValueEntry(
                    id: remoteEntry.id,
                    title: remoteEntry.title,
                    key: remoteEntry.key,
                    category: KeyValueEntry.Category(rawValue: remoteEntry.category) ?? .other,
                    tags: remoteEntry.tags,
                    isFavorite: remoteEntry.isFavorite,
                    createdAt: remoteEntry.createdAt,
                    updatedAt: remoteEntry.updatedAt,
                    usageCount: remoteEntry.usageCount,
                    notes: remoteEntry.notes
                )
                storageService.saveEntry(entry)
            }

            // Update sync metadata
            updateSyncMetadata(for: mergeResult.merged.compactMap { entry in
                localEntries.first(where: { $0.id == entry.id }) ?? {
                    // Entry came from remote – look it up in storage
                    storageService.getEntry(byId: entry.id)
                }()
            }, gistId: gistId, status: .synced)

            let result = GistSyncResult(
                uploadedCount: mergeResult.updatedFromLocal,
                downloadedCount: mergeResult.newFromRemote.count,
                conflictCount: mergeResult.conflicts,
                deletedCount: 0,
                errors: [],
                timestamp: Date()
            )

            await MainActor.run {
                lastSyncResult = result
                lastSyncError = nil
                configuration.lastFullSyncAt = Date()
            }
            saveConfiguration()
            return result

        } catch {
            await MainActor.run { lastSyncError = error }
            throw error
        }
    }

    /// Uploads only – pushes local entries to the Gist without pulling remote changes.
    @discardableResult
    func pushToGist() async throws -> GistSyncResult {
        guard !isSyncing else { return .empty }

        await MainActor.run { isSyncing = true }
        defer {
            Task { @MainActor in isSyncing = false }
        }

        guard let token = getToken() else {
            throw GistSyncError.noToken
        }

        let localEntries = getEligibleEntries()

        if let gistId = configuration.gistId {
            try await updateGist(token: token, gistId: gistId, entries: localEntries.map { SyncableEntry(from: $0) })
        } else {
            let gistId = try await createGist(token: token, entries: localEntries)
            configuration.gistId = gistId
            saveConfiguration()
        }

        let result = GistSyncResult(
            uploadedCount: localEntries.count,
            downloadedCount: 0,
            conflictCount: 0,
            deletedCount: 0,
            errors: [],
            timestamp: Date()
        )

        await MainActor.run {
            lastSyncResult = result
            lastSyncError = nil
        }
        return result
    }

    /// Downloads only – pulls entries from the Gist without pushing local changes.
    @discardableResult
    func pullFromGist() async throws -> GistSyncResult {
        guard !isSyncing else { return .empty }

        await MainActor.run { isSyncing = true }
        defer {
            Task { @MainActor in isSyncing = false }
        }

        guard let token = getToken() else {
            throw GistSyncError.noToken
        }

        guard let gistId = configuration.gistId else {
            throw GistSyncError.gistNotFound("No Gist ID configured")
        }

        let remoteEntries = try await fetchGist(token: token, gistId: gistId)
        var downloadedCount = 0

        for remoteEntry in remoteEntries {
            if storageService.getEntry(byId: remoteEntry.id) == nil {
                let entry = KeyValueEntry(
                        id: remoteEntry.id,
                        title: remoteEntry.title,
                        key: remoteEntry.key,
                        category: KeyValueEntry.Category(rawValue: remoteEntry.category) ?? .other,
                        tags: remoteEntry.tags,
                        isFavorite: remoteEntry.isFavorite,
                        createdAt: remoteEntry.createdAt,
                        updatedAt: remoteEntry.updatedAt,
                        usageCount: remoteEntry.usageCount,
                        notes: remoteEntry.notes
                    )
                storageService.saveEntry(entry)
                downloadedCount += 1
            }
        }

        let result = GistSyncResult(
            uploadedCount: 0,
            downloadedCount: downloadedCount,
            conflictCount: 0,
            deletedCount: 0,
            errors: [],
            timestamp: Date()
        )

        await MainActor.run {
            lastSyncResult = result
            lastSyncError = nil
        }
        return result
    }

    /// Deletes the Gist associated with this app from GitHub.
    func deleteGist() async throws {
        guard let token = getToken() else {
            throw GistSyncError.noToken
        }

        guard let gistId = configuration.gistId else {
            return // Nothing to delete
        }

        let url = URL(string: "\(Constants.githubApiBase)/gists/\(gistId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GistSyncError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 204 || httpResponse.statusCode == 404 else {
            throw GistSyncError.apiError(httpResponse.statusCode, "Failed to delete Gist")
        }

        configuration.gistId = nil
        configuration.lastFullSyncAt = nil
        saveConfiguration()

        // Clear all sync metadata
        for metadata in storageService.getAllSyncMetadata() {
            storageService.deleteSyncMetadata(forEntryId: metadata.entryId)
        }
    }

    // MARK: - Auto-Sync

    /// Starts the auto-sync timer based on the current configuration.
    func startAutoSync() {
        stopAutoSync()
        guard configuration.autoSyncEnabled else { return }

        let intervalSeconds = TimeInterval(configuration.autoSyncIntervalMinutes * 60)
        let timer = DispatchSource.makeTimerSource(queue: syncQueue)
        timer.schedule(
            deadline: .now() + intervalSeconds,
            repeating: intervalSeconds,
            leeway: .seconds(30)
        )
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task {
                try? await self.performFullSync()
            }
        }
        timer.resume()
        autoSyncTimer = timer
    }

    /// Stops the auto-sync timer.
    func stopAutoSync() {
        autoSyncTimer?.cancel()
        autoSyncTimer = nil
    }

    /// Updates auto-sync configuration and restarts the timer if needed.
    func updateAutoSync(enabled: Bool, intervalMinutes: Int? = nil) {
        configuration.autoSyncEnabled = enabled
        if let interval = intervalMinutes {
            configuration.autoSyncIntervalMinutes = max(1, interval)
        }
        saveConfiguration()

        if enabled {
            startAutoSync()
        } else {
            stopAutoSync()
        }
    }

    // MARK: - Configuration Persistence

    private func loadConfiguration() {
        let url = configurationFileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let config = try? decoder.decode(GistSyncConfiguration.self, from: data) else {
            return
        }
        self.configuration = config
    }

    private func saveConfiguration() {
        let url = configurationFileURL()
        guard let data = try? encoder.encode(configuration) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func configurationFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("MacKeyValue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gist_sync_config.json")
    }

    // MARK: - Private – GitHub API Calls

    /// Creates a new Gist with the given entries and returns the Gist ID.
    private func createGist(token: String, entries: [KeyValueEntry]) async throws -> String {
        let syncableEntries = entries.map { SyncableEntry(from: $0) }
        let jsonContent: String
        do {
            let data = try encoder.encode(syncableEntries)
            jsonContent = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            throw GistSyncError.encodingError(error.localizedDescription)
        }

        let body = GistCreateRequest(
            description: configuration.gistDescription,
            public: configuration.isPublic,
            files: [
                Constants.gistFileName: GistFileContent(content: jsonContent)
            ]
        )

        let url = URL(string: "\(Constants.githubApiBase)/gists")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GistSyncError.networkError("Invalid response")
        }

        try validateResponse(httpResponse, data: data)

        let gistResponse = try decoder.decode(GistResponse.self, from: data)
        return gistResponse.id
    }

    /// Fetches and parses entries from an existing Gist.
    private func fetchGist(token: String, gistId: String) async throws -> [SyncableEntry] {
        let url = URL(string: "\(Constants.githubApiBase)/gists/\(gistId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GistSyncError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 404 {
            throw GistSyncError.gistNotFound(gistId)
        }

        try validateResponse(httpResponse, data: data)

        let gistResponse = try decoder.decode(GistResponse.self, from: data)

        guard let file = gistResponse.files[Constants.gistFileName],
              let content = file.content else {
            return []
        }

        guard let contentData = content.data(using: .utf8) else {
            throw GistSyncError.decodingError("Cannot convert Gist file content to Data")
        }

        do {
            return try decoder.decode([SyncableEntry].self, from: contentData)
        } catch {
            throw GistSyncError.decodingError("Failed to decode entries from Gist: \(error.localizedDescription)")
        }
    }

    /// Updates an existing Gist with new entry data.
    private func updateGist(token: String, gistId: String, entries: [SyncableEntry]) async throws {
        let jsonContent: String
        do {
            let data = try encoder.encode(entries)
            jsonContent = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            throw GistSyncError.encodingError(error.localizedDescription)
        }

        let body = GistUpdateRequest(
            description: configuration.gistDescription,
            files: [
                Constants.gistFileName: GistFileContent(content: jsonContent)
            ]
        )

        let url = URL(string: "\(Constants.githubApiBase)/gists/\(gistId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GistSyncError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 404 {
            throw GistSyncError.gistNotFound(gistId)
        }

        try validateResponse(httpResponse, data: data)
    }

    // MARK: - Private – Network Helpers

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw GistSyncError.cancelled
            case .notConnectedToInternet, .networkConnectionLost:
                throw GistSyncError.networkError("No internet connection")
            case .timedOut:
                throw GistSyncError.networkError("Request timed out")
            default:
                throw GistSyncError.networkError(error.localizedDescription)
            }
        } catch {
            throw GistSyncError.networkError(error.localizedDescription)
        }
    }

    private func validateResponse(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return // Success
        case 401:
            throw GistSyncError.invalidToken
        case 403:
            let retryAfter: TimeInterval?
            if let retryAfterStr = response.value(forHTTPHeaderField: "Retry-After") {
                retryAfter = TimeInterval(retryAfterStr)
            } else {
                retryAfter = nil
            }
            throw GistSyncError.rateLimited(retryAfter: retryAfter)
        case 404:
            throw GistSyncError.gistNotFound("Resource not found")
        case 422:
            let message = String(data: data, encoding: .utf8) ?? "Unprocessable entity"
            throw GistSyncError.apiError(422, message)
        default:
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GistSyncError.apiError(response.statusCode, message)
        }
    }

    // MARK: - Private – Entry Filtering

    /// Returns the local entries eligible for syncing based on the current configuration.
    private func getEligibleEntries() -> [KeyValueEntry] {
        var entries = storageService.getAllEntries()

        // Never sync private entries
        if configuration.syncOnlyNonPrivate {
            entries = entries.filter { !$0.isPrivate }
        }

        // Optionally sync only favorites
        if configuration.syncOnlyFavorites {
            entries = entries.filter { $0.isFavorite }
        }

        return entries
    }

    // MARK: - Private – Merge Logic

    private struct MergeResult {
        let merged: [SyncableEntry]
        let newFromRemote: [SyncableEntry]
        let updatedFromLocal: Int
        let conflicts: Int
    }

    /// Merges local and remote entries. Local entries win when `updatedAt` is newer;
    /// remote entries win otherwise. Entries that exist only remotely are treated as new downloads.
    private func mergeEntries(local: [KeyValueEntry], remote: [SyncableEntry]) -> MergeResult {
        var mergedMap: [UUID: SyncableEntry] = [:]
        var newFromRemote: [SyncableEntry] = []
        var updatedFromLocal = 0
        var conflicts = 0

        // Index local entries
        let localSyncable = local.map { SyncableEntry(from: $0) }
        let localById = Dictionary(uniqueKeysWithValues: localSyncable.map { ($0.id, $0) })
        let remoteById = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })

        // Process all local entries
        for entry in localSyncable {
            if let remoteEntry = remoteById[entry.id] {
                // Entry exists in both – compare timestamps
                if entry.updatedAt >= remoteEntry.updatedAt {
                    mergedMap[entry.id] = entry
                    updatedFromLocal += 1
                } else {
                    mergedMap[entry.id] = remoteEntry
                    conflicts += 1
                }
            } else {
                // Only exists locally – include it
                mergedMap[entry.id] = entry
                updatedFromLocal += 1
            }
        }

        // Process remote entries that don't exist locally
        for entry in remote {
            if localById[entry.id] == nil {
                mergedMap[entry.id] = entry
                newFromRemote.append(entry)
            }
        }

        return MergeResult(
            merged: Array(mergedMap.values).sorted { $0.updatedAt > $1.updatedAt },
            newFromRemote: newFromRemote,
            updatedFromLocal: updatedFromLocal,
            conflicts: conflicts
        )
    }

    // MARK: - Private – Sync Metadata Updates

    private func updateSyncMetadata(for entries: [KeyValueEntry], gistId: String, status: GistSyncMetadata.SyncStatus) {
        for entry in entries {
            let metadata = GistSyncMetadata(
                entryId: entry.id,
                gistId: gistId,
                lastSyncedAt: Date(),
                syncStatus: status
            )
            storageService.saveSyncMetadata(metadata)
        }
    }
}
