import SwiftUI
import UniformTypeIdentifiers

// MARK: - ImportSheet

struct ImportSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    // File picker
    @State private var showFilePicker = false
    @State private var selectedURL: URL? = nil
    @State private var detectedFormat: ImportFormat? = nil
    @State private var needsPassword = false
    @State private var password = ""

    // Preview
    @State private var previewEntries: [KeyValueEntry] = []
    @State private var previewSkipped = 0
    @State private var previewErrors: [String] = []
    @State private var isPreviewing = false
    @State private var isParsing = false

    // Result
    @State private var importResult: ImportResult? = nil
    @State private var errorMessage: String? = nil

    private var service: ImportExportService { .shared }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SheetHeader(title: "Import Entries", subtitle: "Supports CSV, Bitwarden, 1Password, Chrome, LastPass, KeePass", icon: "square.and.arrow.down")

            Divider()

            if let result = importResult {
                // ── Done State ──
                importDoneView(result)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Step 1: File selection
                        stepCard(number: 1, title: "Select File") {
                            fileSelectionArea
                        }

                        // Step 2: Format & password
                        if selectedURL != nil {
                            stepCard(number: 2, title: "Format") {
                                formatArea
                            }
                        }

                        // Step 3: Preview
                        if isPreviewing && !previewEntries.isEmpty {
                            stepCard(number: 3, title: "Preview (\(previewEntries.count) entries will be imported\(previewSkipped > 0 ? ", \(previewSkipped) skipped" : ""))") {
                                previewArea
                            }
                        }

                        if let err = errorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(err)
                                    .foregroundColor(.red)
                                    .font(.callout)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Bottom bar
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if importResult == nil {
                    if isPreviewing && !previewEntries.isEmpty {
                        Button {
                            performImport()
                        } label: {
                            Label("Import \(previewEntries.count) Entries", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    } else if selectedURL != nil && !isPreviewing {
                        Button {
                            loadPreview()
                        } label: {
                            if isParsing {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Label("Load Preview", systemImage: "eye")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isParsing || (needsPassword && password.isEmpty))
                    }
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 580, height: 520)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json, .commaSeparatedText, .plainText,
                                  UTType(filenameExtension: "mkve") ?? .data,
                                  UTType(filenameExtension: "csv") ?? .commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    // MARK: - File Selection

    private var fileSelectionArea: some View {
        VStack(spacing: 10) {
            if let url = selectedURL {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .fontWeight(.medium)
                        if let fmt = detectedFormat {
                            Text("Detected: \(fmt.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Change File") {
                        resetState()
                        showFilePicker = true
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .cornerRadius(8)
            } else {
                Button {
                    showFilePicker = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                            .font(.largeTitle)
                            .foregroundColor(.accentColor.opacity(0.7))
                        Text("Click to choose a file")
                            .font(.callout)
                        Text("JSON, CSV, .mkve")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(Color.secondary.opacity(0.07))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Format Area

    private var formatArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Format", selection: Binding(
                get: { detectedFormat ?? .csvGeneric },
                set: { detectedFormat = $0; isPreviewing = false; previewEntries = [] }
            )) {
                ForEach(ImportFormat.allCases) { fmt in
                    Text(fmt.rawValue).tag(fmt)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if needsPassword || detectedFormat == .macKeyValueEncrypted {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.secondary)
                    SecureField("Export password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Preview Area

    private var previewArea: some View {
        VStack(spacing: 0) {
            if !previewErrors.isEmpty {
                Text("\(previewErrors.count) row(s) could not be parsed")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(previewEntries.prefix(50)) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.category.iconName)
                                .frame(width: 16)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text(entry.key.isEmpty ? (entry.url.isEmpty ? "—" : entry.url) : entry.key)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if !entry.url.isEmpty {
                                Text(entry.url)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: 120)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        Divider().padding(.leading, 30)
                    }
                    if previewEntries.count > 50 {
                        Text("… and \(previewEntries.count - 50) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(8)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
    }

    // MARK: - Done View

    private func importDoneView(_ result: ImportResult) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: result.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(result.errors.isEmpty ? .green : .orange)
            Text("Import Complete")
                .font(.title2.bold())
            VStack(spacing: 6) {
                statRow(label: "Imported", value: "\(result.imported)", color: .green)
                if result.skipped > 0 {
                    statRow(label: "Skipped (duplicate)", value: "\(result.skipped)", color: .orange)
                }
                if !result.errors.isEmpty {
                    statRow(label: "Errors", value: "\(result.errors.count)", color: .red)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.07))
            .cornerRadius(10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func statRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).foregroundColor(color)
        }
        .frame(width: 200)
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            selectedURL = url
            detectedFormat = service.detectFormat(url: url)
            needsPassword = detectedFormat == .macKeyValueEncrypted
            isPreviewing = false
            previewEntries = []
            errorMessage = nil
        case .failure:
            break
        }
    }

    private func loadPreview() {
        guard let url = selectedURL else { return }
        let format = detectedFormat
        let passwordValue = password.isEmpty ? nil : password
        isParsing = true
        errorMessage = nil
        Task.detached {
            do {
                let existing = Set(StorageService.shared.getAllEntries().map { $0.id })
                let result = try ImportExportService.shared.importEntries(
                    from: url,
                    format: format,
                    password: passwordValue,
                    existingIds: existing
                )
                await MainActor.run {
                    previewEntries = result.entries
                    previewSkipped = result.skipped
                    previewErrors = result.errors
                    isPreviewing = true
                    isParsing = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isParsing = false
                }
            }
        }
    }

    private func performImport() {
        let entries = previewEntries
        let skipped = previewSkipped
        let errors = previewErrors
        Task.detached {
            for entry in entries {
                _ = StorageService.shared.saveEntry(entry)
            }
            try? StorageService.shared.saveAllDirty()
            let importedCount = entries.count
            await MainActor.run {
                viewModel.reloadEntries()
                importResult = ImportResult(
                    imported: importedCount,
                    skipped: skipped,
                    errors: errors,
                    entries: entries
                )
            }
        }
    }

    private func resetState() {
        selectedURL = nil
        detectedFormat = nil
        needsPassword = false
        password = ""
        isPreviewing = false
        previewEntries = []
        errorMessage = nil
    }
}

// MARK: - ExportSheet

struct ExportSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .macKeyValueJSON
    @State private var exportScope: ExportScope = .all
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isExporting = false
    @State private var showSavePanel = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    @State private var decryptValues = true

    private enum ExportScope: String, CaseIterable, Identifiable {
        case all        = "All Entries"
        case favorites  = "Favorites Only"
        case passwords  = "Passwords Only"
        case nonPrivate = "Exclude Private"
        var id: String { rawValue }
    }

    private var passwordsMatch: Bool { password == confirmPassword }
    private var canExport: Bool {
        !isExporting && (!format.requiresPassword || (!password.isEmpty && passwordsMatch))
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Export Entries", subtitle: "Save a backup or migrate to another password manager", icon: "square.and.arrow.up")

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Format
                    settingsCard(title: "Export Format") {
                        Picker("", selection: $format) {
                            ForEach(ExportFormat.allCases) { f in
                                VStack(alignment: .leading) {
                                    Text(f.rawValue)
                                    if f.requiresPassword {
                                        Text("Password protected").font(.caption).foregroundColor(.secondary)
                                    }
                                }
                                .tag(f)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)

                        if format == .csvPlaintext || format == .csvEncrypted {
                            Toggle("Include decrypted passwords", isOn: $decryptValues)
                                .padding(.top, 4)
                                .help("Uncheck to export entries without decrypting passwords (encrypted values only)")
                        }
                    }

                    // Scope
                    settingsCard(title: "What to Export") {
                        Picker("Scope", selection: $exportScope) {
                            ForEach(ExportScope.allCases) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)

                        Text("\(entriesForExport.count) entries selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Password (if required)
                    if format.requiresPassword {
                        settingsCard(title: "Encryption Password") {
                            VStack(spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.fill").foregroundColor(.secondary)
                                    SecureField("Password", text: $password)
                                        .textFieldStyle(.roundedBorder)
                                }
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.rotation").foregroundColor(.secondary)
                                    SecureField("Confirm Password", text: $confirmPassword)
                                        .textFieldStyle(.roundedBorder)
                                }
                                if !confirmPassword.isEmpty && !passwordsMatch {
                                    Text("Passwords do not match")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }

                    // Warning for plaintext CSV
                    if format == .csvPlaintext && decryptValues {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Plaintext CSV exports are unencrypted. Keep the file secure and delete it after use.")
                                .font(.callout)
                                .foregroundColor(.orange)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }

                    // Status
                    if let err = errorMessage {
                        Label(err, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.callout)
                    }
                    if let ok = successMessage {
                        Label(ok, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.callout)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    triggerExport()
                } label: {
                    if isExporting {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Label("Export \(entriesForExport.count) Entries", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canExport)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Helpers

    private var entriesForExport: [KeyValueEntry] {
        let all = StorageService.shared.getAllEntries()
        switch exportScope {
        case .all:        return all
        case .favorites:  return all.filter { $0.isFavorite }
        case .passwords:  return all.filter { $0.category == .password }
        case .nonPrivate: return all.filter { !$0.isPrivate }
        }
    }

    private func triggerExport() {
        isExporting = true
        errorMessage = nil
        successMessage = nil
        let entries = entriesForExport
        let fmt = format
        let pwd = password.isEmpty ? nil : password
        let decrypt = decryptValues

        Task.detached {
            do {
                let data = try ImportExportService.shared.exportEntries(
                    entries, format: fmt, password: pwd, decryptValues: decrypt
                )
                await MainActor.run {
                    isExporting = false
                    saveFile(data: data, ext: fmt.fileExtension)
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveFile(data: Data, ext: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = ext == "json" ? [.json]
            : ext == "csv" ? [.commaSeparatedText]
            : [UTType(filenameExtension: ext) ?? .data]
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "mackeyvalue-export-\(df.string(from: Date())).\(ext)"
        panel.title = "Save Export"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                successMessage = "Saved to \(url.lastPathComponent)"
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(.primary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }
}

// MARK: - Shared Sub-Views

private struct SheetHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}

private struct stepCard<Content: View>: View {
    let number: Int
    let title: String
    let content: () -> Content

    init(number: Int, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.number = number
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 22, height: 22)
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.subheadline.bold())
            }
            content()
                .padding(.leading, 30)
        }
    }
}
