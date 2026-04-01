import Foundation

// MARK: - Import / Export Errors

enum ImportExportError: LocalizedError {
    case unsupportedFormat(String)
    case parseError(String)
    case encryptionRequired
    case wrongPassword
    case emptyFile
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let f): return "Unsupported file format: \(f)"
        case .parseError(let r):        return "Failed to parse file: \(r)"
        case .encryptionRequired:       return "This file is encrypted — please enter the export password"
        case .wrongPassword:            return "Wrong password or corrupted file"
        case .emptyFile:                return "The file appears to be empty"
        case .encodingFailed(let r):    return "Export failed: \(r)"
        }
    }
}

// MARK: - Import Formats

enum ImportFormat: String, CaseIterable, Identifiable {
    case macKeyValueJSON = "MacKeyValue JSON"
    case macKeyValueEncrypted = "MacKeyValue Encrypted"
    case bitwarden = "Bitwarden JSON"
    case csv1Password = "1Password CSV"
    case csvChrome = "Chrome / Edge CSV"
    case csvLastPass = "LastPass CSV"
    case csvGeneric = "Generic CSV"
    case csvKeePass = "KeePass CSV"

    var id: String { rawValue }

    var fileExtensions: [String] {
        switch self {
        case .macKeyValueJSON:    return ["json"]
        case .macKeyValueEncrypted: return ["mkve"]
        case .bitwarden:          return ["json"]
        case .csv1Password, .csvChrome, .csvLastPass, .csvGeneric, .csvKeePass:
            return ["csv", "txt"]
        }
    }
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case macKeyValueJSON = "MacKeyValue JSON"
    case macKeyValueEncrypted = "MacKeyValue Encrypted (.mkve)"
    case csvPlaintext = "CSV (Plaintext)"
    case csvEncrypted  = "CSV (ZIP + Password)"

    var id: String { rawValue }
    var requiresPassword: Bool { self == .macKeyValueEncrypted || self == .csvEncrypted }
    var fileExtension: String {
        switch self {
        case .macKeyValueJSON:       return "json"
        case .macKeyValueEncrypted:  return "mkve"
        case .csvPlaintext:          return "csv"
        case .csvEncrypted:          return "zip"
        }
    }
}

// MARK: - ImportResult

struct ImportResult {
    var imported: Int = 0
    var skipped: Int = 0
    var errors: [String] = []
    var entries: [KeyValueEntry] = []
    var detectedFormat: ImportFormat?

    var summary: String {
        var parts: [String] = []
        if imported > 0 { parts.append("\(imported) imported") }
        if skipped  > 0 { parts.append("\(skipped) skipped (duplicate)") }
        if !errors.isEmpty { parts.append("\(errors.count) error(s)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - ImportExportService

final class ImportExportService {

    static let shared = ImportExportService()
    private init() {}

    // Internal JSON codec
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Detect Format

    func detectFormat(url: URL) -> ImportFormat? {
        let ext = url.pathExtension.lowercased()
        if ext == "mkve" { return .macKeyValueEncrypted }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        if ext == "json" {
            if text.contains("\"format\":\"mackeyvalue\"") || text.contains("\"entries\":[") {
                return .macKeyValueJSON
            }
            if text.contains("\"encrypted\"") && text.contains("\"items\"") {
                return .bitwarden
            }
            return .macKeyValueJSON
        }
        if ext == "csv" || ext == "txt" {
            let firstLine = text.components(separatedBy: "\n").first?.lowercased() ?? ""
            if firstLine.contains("totp") || firstLine.contains("grouping") {
                return .csvLastPass
            }
            if firstLine.contains("notes") && firstLine.contains("type") && firstLine.contains("favorite") {
                return .csv1Password
            }
            if firstLine.contains("\"name\"") || (firstLine.contains("name") && firstLine.contains("url") && !firstLine.contains("website")) {
                return .csvChrome
            }
            if firstLine.contains("account") || firstLine.contains("login name") {
                return .csvKeePass
            }
            return .csvGeneric
        }
        return nil
    }

    // MARK: - Import Entry Point

    /// Import entries from a file URL.  For encrypted files, supply `password`.
    /// Returns `ImportResult` with entries that still need to be saved by the caller.
    func importEntries(from url: URL, format: ImportFormat? = nil, password: String? = nil,
                       existingIds: Set<UUID> = []) throws -> ImportResult {
        let resolved = format ?? detectFormat(url: url) ?? .csvGeneric
        let data = try Data(contentsOf: url)

        switch resolved {
        case .macKeyValueJSON:
            return try importNativeJSON(data: data, existingIds: existingIds)
        case .macKeyValueEncrypted:
            guard let pwd = password, !pwd.isEmpty else { throw ImportExportError.encryptionRequired }
            return try importEncryptedBundle(data: data, password: pwd, existingIds: existingIds)
        case .bitwarden:
            let text = String(data: data, encoding: .utf8) ?? ""
            return try importBitwardenJSON(text: text, existingIds: existingIds)
        case .csv1Password:
            let text = String(data: data, encoding: .utf8) ?? ""
            return try importCSV1Password(text: text, existingIds: existingIds)
        case .csvChrome:
            let text = String(data: data, encoding: .utf8) ?? ""
            return try importCSVChrome(text: text, existingIds: existingIds)
        case .csvLastPass:
            let text = String(data: data, encoding: .utf8) ?? ""
            return try importCSVLastPass(text: text, existingIds: existingIds)
        case .csvKeePass:
            let text = String(data: data, encoding: .utf8) ?? ""
            return try importCSVKeePass(text: text, existingIds: existingIds)
        case .csvGeneric:
            let text = String(data: data, encoding: .utf8) ?? ""
            return try importCSVGeneric(text: text, existingIds: existingIds)
        }
    }

    // MARK: - Native JSON Import

    private func importNativeJSON(data: Data, existingIds: Set<UUID>) throws -> ImportResult {
        var result = ImportResult(detectedFormat: .macKeyValueJSON)
        if data.isEmpty { throw ImportExportError.emptyFile }
        do {
            // Handle both top-level array and wrapped format
            let entries: [KeyValueEntry]
            if let wrapped = try? decoder.decode(NativeExportBundle.self, from: data) {
                entries = wrapped.entries
            } else {
                entries = try decoder.decode([KeyValueEntry].self, from: data)
            }
            for entry in entries {
                if existingIds.contains(entry.id) {
                    result.skipped += 1
                } else {
                    result.entries.append(entry)
                    result.imported += 1
                }
            }
        } catch {
            throw ImportExportError.parseError(error.localizedDescription)
        }
        return result
    }

    // MARK: - Encrypted Bundle Import

    private func importEncryptedBundle(data: Data, password: String, existingIds: Set<UUID>) throws -> ImportResult {
        do {
            let jsonData = try EncryptionService.shared.decrypt(data, withPassword: password)
            return try importNativeJSON(data: jsonData, existingIds: existingIds)
        } catch is EncryptionError {
            throw ImportExportError.wrongPassword
        } catch {
            throw ImportExportError.wrongPassword
        }
    }

    // MARK: - Bitwarden JSON Import

    private func importBitwardenJSON(text: String, existingIds: Set<UUID>) throws -> ImportResult {
        var result = ImportResult(detectedFormat: .bitwarden)
        guard let data = text.data(using: .utf8) else { throw ImportExportError.emptyFile }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportExportError.parseError("Not a valid JSON object")
        }
        guard let items = json["items"] as? [[String: Any]] else {
            throw ImportExportError.parseError("No 'items' array found")
        }
        for item in items {
            guard let type = item["type"] as? Int else { continue }
            let title = (item["name"] as? String) ?? "Untitled"
            let notes = (item["notes"] as? String) ?? ""
            var username = ""
            var password = ""
            var urlString = ""
            if type == 1, let login = item["login"] as? [String: Any] {
                username = (login["username"] as? String) ?? ""
                password = (login["password"] as? String) ?? ""
                if let uris = login["uris"] as? [[String: Any]],
                   let first = uris.first,
                   let uri = first["uri"] as? String {
                    urlString = uri
                }
            } else if type == 3, let card = item["card"] as? [String: Any] {
                username = (card["cardholderName"] as? String) ?? ""
                password = (card["number"] as? String) ?? ""
            }
            guard let entry = makeEntry(
                title: title, username: username, password: password,
                url: urlString, notes: notes, category: type == 1 ? .password : .other
            ) else { result.errors.append("Failed to encrypt '\(title)'"); continue }
            result.entries.append(entry)
            result.imported += 1
        }
        return result
    }

    // MARK: - 1Password CSV Import

    private func importCSV1Password(text: String, existingIds: Set<UUID>) throws -> ImportResult {
        // Columns: Title, Username, Password, Website, Notes, Type, ...
        let rows = parseCSV(text)
        guard let header = rows.first else { throw ImportExportError.emptyFile }
        let h = header.map { $0.lowercased() }
        let iTitle    = h.firstIndex(where: { $0 == "title" })
        let iUser     = h.firstIndex(where: { $0.contains("username") || $0 == "login" })
        let iPass     = h.firstIndex(where: { $0.contains("password") })
        let iURL      = h.firstIndex(where: { $0 == "website" || $0 == "url" || $0.contains("uri") })
        let iNotes    = h.firstIndex(where: { $0 == "notes" || $0 == "notesplain" })
        return buildResult(rows: Array(rows.dropFirst()),
                           iTitle: iTitle, iUser: iUser, iPass: iPass,
                           iURL: iURL, iNotes: iNotes,
                           existingIds: existingIds,
                           format: .csv1Password)
    }

    // MARK: - Chrome / Edge CSV Import

    private func importCSVChrome(text: String, existingIds: Set<UUID>) throws -> ImportResult {
        // Columns: name, url, username, password
        let rows = parseCSV(text)
        guard let header = rows.first else { throw ImportExportError.emptyFile }
        let h = header.map { $0.lowercased() }
        let iTitle = h.firstIndex(where: { $0 == "name" })
        let iURL   = h.firstIndex(where: { $0 == "url" })
        let iUser  = h.firstIndex(where: { $0.contains("username") || $0 == "login" })
        let iPass  = h.firstIndex(where: { $0.contains("password") })
        return buildResult(rows: Array(rows.dropFirst()),
                           iTitle: iTitle, iUser: iUser, iPass: iPass,
                           iURL: iURL, iNotes: nil,
                           existingIds: existingIds,
                           format: .csvChrome)
    }

    // MARK: - LastPass CSV Import

    private func importCSVLastPass(text: String, existingIds: Set<UUID>) throws -> ImportResult {
        // Columns: url, username, password, totp, extra, name, grouping, fav
        let rows = parseCSV(text)
        guard let header = rows.first else { throw ImportExportError.emptyFile }
        let h = header.map { $0.lowercased() }
        let iTitle = h.firstIndex(where: { $0 == "name" })
        let iURL   = h.firstIndex(where: { $0 == "url" })
        let iUser  = h.firstIndex(where: { $0.contains("username") })
        let iPass  = h.firstIndex(where: { $0.contains("password") })
        let iNotes = h.firstIndex(where: { $0 == "extra" || $0 == "notes" })
        return buildResult(rows: Array(rows.dropFirst()),
                           iTitle: iTitle, iUser: iUser, iPass: iPass,
                           iURL: iURL, iNotes: iNotes,
                           existingIds: existingIds,
                           format: .csvLastPass)
    }

    // MARK: - KeePass CSV Import

    private func importCSVKeePass(text: String, existingIds: Set<UUID>) throws -> ImportResult {
        // Columns: "Account","Login Name","Password","Web Site","Comments"
        let rows = parseCSV(text)
        guard let header = rows.first else { throw ImportExportError.emptyFile }
        let h = header.map { $0.lowercased() }
        let iTitle = h.firstIndex(where: { $0 == "account" || $0 == "title" })
        let iUser  = h.firstIndex(where: { $0.contains("login") || $0.contains("username") })
        let iPass  = h.firstIndex(where: { $0.contains("password") })
        let iURL   = h.firstIndex(where: { $0.contains("web") || $0.contains("url") })
        let iNotes = h.firstIndex(where: { $0.contains("comment") || $0 == "notes" })
        return buildResult(rows: Array(rows.dropFirst()),
                           iTitle: iTitle, iUser: iUser, iPass: iPass,
                           iURL: iURL, iNotes: iNotes,
                           existingIds: existingIds,
                           format: .csvKeePass)
    }

    // MARK: - Generic CSV Import

    private func importCSVGeneric(text: String, existingIds: Set<UUID>) throws -> ImportResult {
        // Try common column names in order
        let rows = parseCSV(text)
        guard let header = rows.first else { throw ImportExportError.emptyFile }
        let h = header.map { $0.lowercased() }
        let iTitle = h.firstIndex(where: { $0.contains("name") || $0.contains("title") }) ?? (h.count > 0 ? 0 : nil)
        let iUser  = h.firstIndex(where: { $0.contains("user") || $0.contains("login") || $0.contains("email") || $0.contains("account") })
        let iPass  = h.firstIndex(where: { $0.contains("pass") })
        let iURL   = h.firstIndex(where: { $0.contains("url") || $0.contains("web") || $0.contains("host") || $0.contains("site") })
        let iNotes = h.firstIndex(where: { $0.contains("note") || $0.contains("comment") || $0.contains("extra") })
        return buildResult(rows: Array(rows.dropFirst()),
                           iTitle: iTitle, iUser: iUser, iPass: iPass,
                           iURL: iURL, iNotes: iNotes,
                           existingIds: existingIds,
                           format: .csvGeneric)
    }

    // MARK: - Build Result Helper

    private func buildResult(rows: [[String]], iTitle: Int?, iUser: Int?,
                             iPass: Int?, iURL: Int?, iNotes: Int?,
                             existingIds: Set<UUID>,
                             format: ImportFormat) -> ImportResult {
        var result = ImportResult(detectedFormat: format)
        for row in rows {
            guard !row.isEmpty, row.joined().trimmingCharacters(in: .whitespaces) != "" else { continue }
            let title    = iTitle.flatMap { $0 < row.count ? row[$0] : nil } ?? "Untitled"
            let username = iUser.flatMap  { $0 < row.count ? row[$0] : nil } ?? ""
            let password = iPass.flatMap  { $0 < row.count ? row[$0] : nil } ?? ""
            let url      = iURL.flatMap   { $0 < row.count ? row[$0] : nil } ?? ""
            let notes    = iNotes.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
            guard let entry = makeEntry(
                title: title.isEmpty ? "Untitled" : title,
                username: username, password: password, url: url, notes: notes
            ) else { result.errors.append("Failed to encrypt '\(title)'"); continue }
            result.entries.append(entry)
            result.imported += 1
        }
        return result
    }

    // MARK: - Entry Builder

    private func makeEntry(title: String, username: String, password: String,
                           url: String = "", notes: String = "",
                           category: KeyValueEntry.Category = .password) -> KeyValueEntry? {
        do {
            let encrypted = password.isEmpty
                ? Data()
                : try EncryptionService.shared.encrypt(password)
            return KeyValueEntry(
                title: title,
                key: username,
                url: url,
                encryptedValue: encrypted,
                category: category,
                notes: notes
            )
        } catch {
            return nil
        }
    }

    // MARK: - Export Entry Point

    /// Exports entries as `Data` in the requested format.
    /// For encrypted formats, `password` must be non-nil.
    func exportEntries(_ entries: [KeyValueEntry], format: ExportFormat,
                       password: String? = nil,
                       decryptValues: Bool = true) throws -> Data {
        switch format {
        case .macKeyValueJSON:
            return try exportNativeJSON(entries: entries)
        case .macKeyValueEncrypted:
            guard let pwd = password, !pwd.isEmpty else { throw ImportExportError.encryptionRequired }
            let jsonData = try exportNativeJSON(entries: entries)
            return try EncryptionService.shared.encrypt(jsonData, withPassword: pwd)
        case .csvPlaintext:
            return try exportCSV(entries: entries, decryptValues: decryptValues)
        case .csvEncrypted:
            // Produce CSV, then ZIP-encrypt with the password
            guard let pwd = password, !pwd.isEmpty else { throw ImportExportError.encryptionRequired }
            let csvData = try exportCSV(entries: entries, decryptValues: decryptValues)
            return try EncryptionService.shared.encrypt(csvData, withPassword: pwd)
        }
    }

    // MARK: - Native JSON Export

    private func exportNativeJSON(entries: [KeyValueEntry]) throws -> Data {
        let bundle = NativeExportBundle(
            version: 1,
            format: "mackeyvalue",
            exportedAt: Date(),
            entries: entries
        )
        do {
            return try encoder.encode(bundle)
        } catch {
            throw ImportExportError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: - CSV Export

    func exportCSV(entries: [KeyValueEntry], decryptValues: Bool = true) throws -> Data {
        var lines: [String] = ["name,username,password,url,notes,category,tags,favorite,created"]
        for entry in entries {
            var passwordText = ""
            if decryptValues && !entry.encryptedValue.isEmpty {
                passwordText = (try? EncryptionService.shared.decryptToString(entry.encryptedValue)) ?? ""
            }
            let cols = [
                csvEscape(entry.title),
                csvEscape(entry.key),
                csvEscape(passwordText),
                csvEscape(entry.url),
                csvEscape(entry.notes),
                entry.category.rawValue,
                csvEscape(entry.tags.joined(separator: ";")),
                entry.isFavorite ? "1" : "0",
                ISO8601DateFormatter().string(from: entry.createdAt)
            ]
            lines.append(cols.joined(separator: ","))
        }
        let csv = lines.joined(separator: "\n")
        guard let data = csv.data(using: .utf8) else {
            throw ImportExportError.encodingFailed("UTF-8 encoding failed")
        }
        return data
    }

    // MARK: - CSV Helpers

    /// RFC 4180 compliant CSV parser that handles quoted fields, commas, and newlines.
    func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        // Escaped quote
                        field.append("\"")
                        i = text.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    currentRow.append(field)
                    field = ""
                } else if c == "\n" || c == "\r" {
                    currentRow.append(field)
                    field = ""
                    if !currentRow.isEmpty {
                        rows.append(currentRow)
                        currentRow = []
                    }
                    // Skip \r\n
                    let next = text.index(after: i)
                    if c == "\r", next < text.endIndex, text[next] == "\n" {
                        i = next
                    }
                } else {
                    field.append(c)
                }
            }
            i = text.index(after: i)
        }
        // Last field / row
        currentRow.append(field)
        if currentRow.contains(where: { !$0.isEmpty }) {
            rows.append(currentRow)
        }
        return rows
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

// MARK: - NativeExportBundle

private struct NativeExportBundle: Codable {
    let version: Int
    let format: String
    let exportedAt: Date
    let entries: [KeyValueEntry]
}
