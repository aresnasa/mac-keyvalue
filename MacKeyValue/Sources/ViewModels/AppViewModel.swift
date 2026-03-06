import AppKit
import Combine
import Foundation

// MARK: - AppState

/// Represents the high-level navigation / UI state of the application.
enum AppState: Equatable {
    case locked
    case unlocked
    case onboarding
}

// MARK: - UIMode

/// Controls which layout the main window uses.
///
/// - `compact`:  A slim, paste-focused list.  Shows a search bar and a flat
///   list of entries with one-tap **Copy / Paste / Type** buttons.  No sidebar,
///   no detail pane — designed for quick daily use.
/// - `full`:  The original three-column management view with sidebar, entry
///   list, and detail pane — used to create, edit, and organise entries.
enum UIMode: String, CaseIterable {
    case compact = "compact"
    case full = "full"

    var displayName: String {
        switch self {
        case .compact: return "精简模式"
        case .full: return "管理模式"
        }
    }

    var iconName: String {
        switch self {
        case .compact: return "rectangle.compress.vertical"
        case .full: return "rectangle.expand.vertical"
        }
    }
}

/// Represents which panel or sheet is currently visible.
enum ActiveSheet: Identifiable, Equatable {
    case addEntry
    case editEntry(UUID)
    case entryDetail(UUID)
    case clipboardHistory
    case settings
    case gistSync
    case hotkeySettings
    case quickSearch
    case about

    var id: String {
        switch self {
        case .addEntry: return "addEntry"
        case .editEntry(let id): return "editEntry-\(id)"
        case .entryDetail(let id): return "entryDetail-\(id)"
        case .clipboardHistory: return "clipboardHistory"
        case .settings: return "settings"
        case .gistSync: return "gistSync"
        case .hotkeySettings: return "hotkeySettings"
        case .quickSearch: return "quickSearch"
        case .about: return "about"
        }
    }
}

// MARK: - SortOrder

enum EntrySortOrder: String, CaseIterable, Identifiable {
    case titleAsc = "title_asc"
    case titleDesc = "title_desc"
    case dateCreatedDesc = "date_created_desc"
    case dateCreatedAsc = "date_created_asc"
    case dateUpdatedDesc = "date_updated_desc"
    case dateUpdatedAsc = "date_updated_asc"
    case usageDesc = "usage_desc"
    case usageAsc = "usage_asc"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .titleAsc: return "标题 A→Z"
        case .titleDesc: return "标题 Z→A"
        case .dateCreatedDesc: return "创建时间（最新）"
        case .dateCreatedAsc: return "创建时间（最早）"
        case .dateUpdatedDesc: return "更新时间（最新）"
        case .dateUpdatedAsc: return "更新时间（最早）"
        case .usageDesc: return "使用次数（最多）"
        case .usageAsc: return "使用次数（最少）"
        }
    }
}

// MARK: - FilterState

struct EntryFilterState: Equatable {
    var searchQuery: String = ""
    var selectedCategory: KeyValueEntry.Category? = nil
    var showFavoritesOnly: Bool = false
    var showPrivateOnly: Bool = false
    var sortOrder: EntrySortOrder = .dateUpdatedDesc

    var isActive: Bool {
        !searchQuery.isEmpty
            || selectedCategory != nil
            || showFavoritesOnly
            || showPrivateOnly
    }

    mutating func reset() {
        searchQuery = ""
        selectedCategory = nil
        showFavoritesOnly = false
        showPrivateOnly = false
        sortOrder = .dateUpdatedDesc
    }
}

// MARK: - AppViewModel

/// The central view-model that coordinates all services and drives the SwiftUI views.
///
/// ### Design – no Combine `$property` → sink → write-`@Published` chains
///
/// Every `@Published` property that previously was kept in sync via a Combine
/// pipeline is now either:
///
///   * a **computed property** that reads directly from the service (the service
///     itself is an `ObservableObject` injected into the environment or held
///     via `let`),
///   * driven by an explicit **`didSet`** on the source property, or
///   * updated through an explicit **method call** triggered by user actions.
///
/// This eliminates all re-entrant `objectWillChange` notifications that cause
/// the SwiftUI runtime warning:
///
///     "Publishing changes from within view updates is not allowed,
///      this will cause undefined behavior."
///
@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - Published – App State

    @Published var appState: AppState = .locked
    @Published var activeSheet: ActiveSheet? = nil
    @Published var statusMessage: String = ""
    @Published var isStatusMessageVisible: Bool = false

    // MARK: - Published – Data

    @Published private(set) var entries: [KeyValueEntry] = []
    @Published private(set) var filteredEntries: [KeyValueEntry] = []
    @Published private(set) var clipboardHistory: [ClipboardHistoryItem] = []
    @Published private(set) var favoriteEntries: [KeyValueEntry] = []
    @Published var selectedEntryId: UUID? = nil

    // MARK: - Published – Filter State
    //
    // `filterState` uses `didSet` to immediately (and synchronously)
    // recompute `filteredEntries`.  Because the write to `filteredEntries`
    // happens inside the *same* `objectWillChange` cycle that SwiftUI
    // already expects (it was triggered by the view writing to
    // `filterState`), there is no re-entrant publish.

    @Published var filterState = EntryFilterState() {
        didSet {
            guard filterState != oldValue else { return }
            recomputeFilteredEntries()
        }
    }

    // MARK: - Published – Status Flags

    @Published private(set) var isLoading: Bool = false

    // `isSyncing` is driven by an explicit method, not a Combine sink.
    @Published private(set) var isSyncing: Bool = false

    // `isAccessibilityGranted` is driven by explicit method calls and the
    // polling timer callback — never by a Combine `$` observation chain.
    @Published private(set) var isAccessibilityGranted: Bool = false

    /// Controls visibility of the full-screen animated Accessibility permission guide.
    /// Set to `true` when a stale TCC entry is detected or when the user needs
    /// step-by-step guidance to grant Accessibility permission.
    @Published var showAccessibilityGuide: Bool = false

    /// The current UI layout mode.  Persisted to UserDefaults so the user's
    /// choice survives across launches.
    @Published var uiMode: UIMode = {
        if let raw = UserDefaults.standard.string(forKey: "uiMode"),
           let mode = UIMode(rawValue: raw) {
            return mode
        }
        return .compact  // Default to compact — efficiency-first tool
    }() {
        didSet {
            guard uiMode != oldValue else { return }
            UserDefaults.standard.set(uiMode.rawValue, forKey: "uiMode")
        }
    }

    /// Quick search text used in compact mode (separate from the full-mode filter).
    @Published var compactSearchText: String = ""

    // Privacy mode: the `didSet` pushes the value *out* to
    // `ClipboardService` (one-way).  We never observe the service's
    // property back via Combine, breaking the potential cycle.
    @Published var isPrivacyMode: Bool = false {
        didSet {
            guard isPrivacyMode != oldValue else { return }
            clipboardService.setPrivacyMode(isPrivacyMode)
        }
    }

    // MARK: - Published – Entry Editor State

    @Published var editingTitle: String = ""
    @Published var editingKey: String = ""
    @Published var editingValue: String = ""
    @Published var editingCategory: KeyValueEntry.Category = .other
    @Published var editingTags: String = ""
    @Published var editingNotes: String = ""
    @Published var editingIsPrivate: Bool = false
    @Published var editingIsFavorite: Bool = false

    // MARK: - Services

    let encryptionService: EncryptionService
    let storageService: StorageService
    let clipboardService: ClipboardService
    let hotkeyService: HotkeyService
    let gistSyncService: GistSyncService
    let biometricService: BiometricService

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var statusMessageTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        encryptionService: EncryptionService = .shared,
        storageService: StorageService = .shared,
        clipboardService: ClipboardService = .shared,
        hotkeyService: HotkeyService = .shared,
        gistSyncService: GistSyncService = .shared,
        biometricService: BiometricService = .shared
    ) {
        self.encryptionService = encryptionService
        self.storageService = storageService
        self.clipboardService = clipboardService
        self.hotkeyService = hotkeyService
        self.gistSyncService = gistSyncService
        self.biometricService = biometricService

        // Seed the accessibility flag from the current system state.
        // This is safe because no SwiftUI view is observing us yet
        // (we are still inside `init`).
        isAccessibilityGranted = clipboardService.checkAccessibilityPermission()

        // Read the current privacy mode from the service so we start in sync.
        isPrivacyMode = clipboardService.isPrivacyMode

        setupCallbacks()
    }

    // MARK: - Lifecycle

    /// Call once at app launch to bootstrap all services.
    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }

        do {
            // 1. Ensure encryption master key exists
            let isNewKey = try encryptionService.ensureMasterKeyExists()
            if isNewKey {
                appState = .onboarding
            } else {
                appState = .unlocked
            }

            // 2. Set up local storage
            try storageService.setup()

            // 3. Load data
            reloadEntries()
            reloadClipboardHistory()

            // 4. Start clipboard monitoring
            clipboardService.startMonitoring()

            // 5. Start hotkey listening
            hotkeyService.registerDefaultBindingsIfNeeded()
            hotkeyService.start()

            // 6. Start auto-sync if configured
            if gistSyncService.configuration.autoSyncEnabled {
                gistSyncService.startAutoSync()
            }

            showStatusMessage("应用已就绪")

        } catch {
            showStatusMessage("启动失败: \(error.localizedDescription)")
            print("[AppViewModel] Bootstrap failed: \(error)")
        }
    }

    /// Call when the app is about to terminate.
    func shutdown() {
        clipboardService.stopMonitoring()
        clipboardService.stopAccessibilityPolling()
        hotkeyService.stop()
        gistSyncService.stopAutoSync()
        storageService.teardown()
    }

    // MARK: - Callback Setup (replaces all Combine `$prop` sinks)

    private func setupCallbacks() {
        // 1. Clipboard changes → reload history.
        //    We subscribe to the *event* subject (not a `$` property publisher)
        //    so there is no initial-value emission and no risk of re-entrance.
        clipboardService.clipboardChanged
            .sink { [weak self] _ in
                // `clipboardChanged` fires from a background queue; hop to main
                // via Task to avoid synchronous view-update conflicts.
                Task { @MainActor [weak self] in
                    self?.reloadClipboardHistory()
                }
            }
            .store(in: &cancellables)

        // 2. Accessibility granted one-shot.
        clipboardService.accessibilityGranted
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.isAccessibilityGranted = true
                    self.showAccessibilityGuide = false     // Dismiss the guide overlay

                    let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
                    if isAppBundle {
                        // .app bundles usually pick up TCC changes immediately.
                        self.showStatusMessage("✅ 辅助功能权限已授予，键盘模拟功能已可用", duration: 5)
                    } else {
                        // Bare executables may need a restart for TCC to take effect.
                        self.showStatusMessage("✅ 辅助功能权限已授予，请重启应用使权限完全生效", duration: 10)
                    }
                }
            }
            .store(in: &cancellables)

        // 3. Hotkey callback.
        hotkeyService.onHotkeyTriggered = { [weak self] binding in
            Task { @MainActor [weak self] in
                self?.handleHotkeyTriggered(binding)
            }
        }
    }

    // MARK: - Data Loading

    /// Reloads entries from storage and re-applies filters.
    func reloadEntries() {
        entries = storageService.getAllEntries()
        favoriteEntries = storageService.getFavoriteEntries()
        recomputeFilteredEntries()
    }

    /// Reloads clipboard history from storage.
    func reloadClipboardHistory() {
        clipboardHistory = storageService.getClipboardHistory()
    }

    // MARK: - Filter / Sort

    /// Recomputes `filteredEntries` from `entries` + `filterState`.
    ///
    /// Called from `filterState.didSet` and `reloadEntries()`.
    /// Because it only writes to `filteredEntries` — which is part of the
    /// *same* `ObservableObject` whose `objectWillChange` has already been
    /// fired by the trigger — SwiftUI coalesces the notification and
    /// never sees a re-entrant publish.
    private func recomputeFilteredEntries() {
        var result = entries

        // Search query
        if !filterState.searchQuery.isEmpty {
            result = storageService.searchEntries(query: filterState.searchQuery)
        }

        // Category filter
        if let category = filterState.selectedCategory {
            result = result.filter { $0.category == category }
        }

        // Favorites only
        if filterState.showFavoritesOnly {
            result = result.filter { $0.isFavorite }
        }

        // Private only
        if filterState.showPrivateOnly {
            result = result.filter { $0.isPrivate }
        }

        // Sort
        result = sortEntries(result, by: filterState.sortOrder)

        filteredEntries = result
    }

    private func sortEntries(_ entries: [KeyValueEntry], by order: EntrySortOrder) -> [KeyValueEntry] {
        switch order {
        case .titleAsc:
            return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc:
            return entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .dateCreatedDesc:
            return entries.sorted { $0.createdAt > $1.createdAt }
        case .dateCreatedAsc:
            return entries.sorted { $0.createdAt < $1.createdAt }
        case .dateUpdatedDesc:
            return entries.sorted { $0.updatedAt > $1.updatedAt }
        case .dateUpdatedAsc:
            return entries.sorted { $0.updatedAt < $1.updatedAt }
        case .usageDesc:
            return entries.sorted { $0.usageCount > $1.usageCount }
        case .usageAsc:
            return entries.sorted { $0.usageCount < $1.usageCount }
        }
    }

    // MARK: - Entry CRUD

    /// Resets the editing state for a new entry.
    func prepareNewEntry() {
        editingTitle = ""
        editingKey = ""
        editingValue = ""
        editingCategory = .other
        editingTags = ""
        editingNotes = ""
        editingIsPrivate = false
        editingIsFavorite = false
        activeSheet = .addEntry
    }

    /// Populates the editing state from an existing entry for editing.
    func prepareEditEntry(_ entry: KeyValueEntry) {
        editingTitle = entry.title
        editingKey = entry.key
        editingCategory = entry.category
        editingTags = entry.tags.joined(separator: ", ")
        editingNotes = entry.notes
        editingIsPrivate = entry.isPrivate
        editingIsFavorite = entry.isFavorite

        // Decrypt the value for editing
        do {
            editingValue = try encryptionService.decryptToString(entry.encryptedValue)
        } catch {
            editingValue = ""
            showStatusMessage("无法解密条目: \(error.localizedDescription)")
        }

        activeSheet = .editEntry(entry.id)
    }

    /// Saves a new entry from the current editing state.
    func saveNewEntry() {
        guard !editingTitle.isEmpty else {
            showStatusMessage("标题不能为空")
            return
        }

        guard !editingKey.isEmpty else {
            showStatusMessage("键名不能为空")
            return
        }

        do {
            let encryptedValue = try encryptionService.encrypt(editingValue)
            let tags = editingTags
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let entry = KeyValueEntry(
                title: editingTitle,
                key: editingKey,
                encryptedValue: encryptedValue,
                category: editingCategory,
                tags: tags,
                isPrivate: editingIsPrivate,
                isFavorite: editingIsFavorite,
                notes: editingNotes
            )

            try storageService.addEntry(entry)
            reloadEntries()
            activeSheet = nil
            showStatusMessage("条目「\(entry.title)」已创建")

        } catch {
            showStatusMessage("保存失败: \(error.localizedDescription)")
        }
    }

    /// Updates an existing entry from the current editing state.
    func updateEntry(id: UUID) {
        guard var entry = storageService.getEntry(byId: id) else {
            showStatusMessage("找不到条目")
            return
        }

        do {
            let encryptedValue = try encryptionService.encrypt(editingValue)
            let tags = editingTags
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            entry.title = editingTitle
            entry.key = editingKey
            entry.encryptedValue = encryptedValue
            entry.category = editingCategory
            entry.tags = tags
            entry.notes = editingNotes
            entry.isPrivate = editingIsPrivate
            entry.isFavorite = editingIsFavorite
            entry.updatedAt = Date()

            try storageService.updateEntry(entry)
            reloadEntries()
            activeSheet = nil
            showStatusMessage("条目「\(entry.title)」已更新")

        } catch {
            showStatusMessage("更新失败: \(error.localizedDescription)")
        }
    }

    /// Deletes an entry by its ID.
    func deleteEntry(id: UUID) {
        do {
            let entry = try storageService.deleteEntry(byId: id)
            // Also remove any associated hotkey binding
            if let binding = hotkeyService.binding(forEntryId: id) {
                try? hotkeyService.removeBinding(id: binding.id)
            }
            // Also remove sync metadata
            storageService.deleteSyncMetadata(forEntryId: id)

            reloadEntries()

            if selectedEntryId == id {
                selectedEntryId = nil
            }

            showStatusMessage("条目「\(entry.title)」已删除")

        } catch {
            showStatusMessage("删除失败: \(error.localizedDescription)")
        }
    }

    /// Toggles the favorite flag on an entry.
    func toggleFavorite(id: UUID) {
        guard var entry = storageService.getEntry(byId: id) else { return }
        entry.isFavorite.toggle()
        entry.updatedAt = Date()
        storageService.saveEntry(entry)
        reloadEntries()
    }

    /// Toggles the private flag on an entry.
    func togglePrivate(id: UUID) {
        guard var entry = storageService.getEntry(byId: id) else { return }
        entry.isPrivate.toggle()
        entry.updatedAt = Date()
        storageService.saveEntry(entry)
        reloadEntries()
    }

    // MARK: - Clipboard Operations

    /// Copies the decrypted value of an entry to the system clipboard.
    ///
    /// The user can then switch to the target application and press ⌘V to
    /// paste normally.  The clipboard is automatically cleared after a
    /// configurable timeout (default 120 seconds).
    ///
    /// The clipboard is automatically cleared after `clearAfter` seconds
    /// (default **120 s** — long enough to switch apps comfortably).
    func copyEntryValue(id: UUID, clearAfter: TimeInterval = 120) {
        guard let entry = storageService.getEntry(byId: id) else {
            showStatusMessage("找不到条目")
            return
        }

        // Authenticate via Touch ID / password with session caching.
        Task { @MainActor in
            let authenticated = await biometricService.authenticate(reason: "复制密码「\(entry.title)」")
            guard authenticated else {
                showStatusMessage("认证已取消")
                return
            }

            do {
                // Plain copy — no event tap interception.
                // The user presses ⌘V themselves in the target app,
                // which performs a standard system paste.
                try clipboardService.copyDecryptedValue(
                    entry.encryptedValue,
                    clearAfter: clearAfter
                )
                try storageService.recordEntryUsage(id: id)
                reloadEntries()
                showStatusMessage(
                    "已复制「\(entry.title)」— 请切换到目标窗口按 ⌘V 粘贴，\(Int(clearAfter))秒后自动清除"
                )
            } catch {
                showStatusMessage("复制失败: \(error.localizedDescription)")
            }
        }
    }

    /// Copies the decrypted value to the clipboard, then automatically
    /// simulates ⌘V to paste into the **current frontmost application**.
    ///
    /// ### Flow
    /// 1. Authenticate via Touch ID / password.
    /// 2. Decrypt and copy to clipboard.
    /// 3. Hide MacKeyValue's window.
    /// 4. **Wait for the user to switch to the target window and click the
    ///    input field** (configurable countdown, default 3 seconds).
    /// 5. Detect whichever application is frontmost at that moment.
    /// 6. Simulate ⌘V into that application.
    ///
    /// - Parameters:
    ///   - id: The entry to paste.
    ///   - clearAfter: Seconds before auto-clearing the clipboard.
    ///   - countdownSeconds: Seconds to wait for the user to focus the target window.
    func pasteEntryValue(id: UUID, clearAfter: TimeInterval = 120, countdownSeconds: Int = 3) {
        guard let entry = storageService.getEntry(byId: id) else {
            showStatusMessage("找不到条目")
            return
        }

        guard clipboardService.checkAccessibilityPermission() else {
            autoGrantAccessibility()
            return
        }

        Task { @MainActor in
            // 1. Authenticate
            let authenticated = await biometricService.authenticate(reason: "粘贴密码「\(entry.title)」")
            guard authenticated else {
                showStatusMessage("认证已取消")
                return
            }

            // 2. Decrypt and copy to clipboard
            do {
                try clipboardService.copyDecryptedValue(
                    entry.encryptedValue,
                    clearAfter: clearAfter
                )
            } catch {
                showStatusMessage("粘贴失败: \(error.localizedDescription)")
                return
            }

            // 3. Hide MacKeyValue
            NSApp.hide(nil)

            // 4. Countdown
            for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
                showStatusMessage("⏳ \(remaining) 秒后将粘贴到当前焦点窗口，请点击目标输入框…")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            // 5. Detect the current frontmost app
            let targetApp = NSWorkspace.shared.frontmostApplication
            let targetName = targetApp?.localizedName ?? "未知应用"
            let targetPID = targetApp?.processIdentifier ?? -1
            let myPID = ProcessInfo.processInfo.processIdentifier

            if targetPID == myPID {
                showStatusMessage("⚠️ 当前焦点是 MacKeyValue 自身，已复制到剪贴板，请手动 ⌘V 粘贴")
                return
            }

            showStatusMessage("正在粘贴到「\(targetName)」…")

            // 6. Paste on a background thread
            nonisolated(unsafe) let clipSvc = self.clipboardService
            let storageSvc = self.storageService
            let entryTitle = entry.title

            let pasteResult: Result<Void, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    Thread.sleep(forTimeInterval: 0.15)

                    let currentApp = NSWorkspace.shared.frontmostApplication
                    print("[pasteEntryValue] Pasting into: \(currentApp?.localizedName ?? "?") (pid=\(currentApp?.processIdentifier ?? -1))")

                    do {
                        try clipSvc.simulatePaste()
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }

            switch pasteResult {
            case .success:
                try? storageSvc.recordEntryUsage(id: id)
                reloadEntries()
                showStatusMessage("✅ 已粘贴「\(entryTitle)」到「\(targetName)」，\(Int(clearAfter))秒后自动清除剪贴板")
            case .failure(let error):
                showStatusMessage("❌ 粘贴失败: \(error.localizedDescription)")
            }
        }
    }

    /// Types the decrypted value of an entry character-by-character into the
    /// **current frontmost application** using simulated HID keystrokes.
    ///
    /// ### Flow
    /// 1. Authenticate via Touch ID / password.
    /// 2. Decrypt the value.
    /// 3. Hide MacKeyValue's window.
    /// 4. **Wait for the user to switch to the target window and click the
    ///    input field** (configurable countdown, default 3 seconds).
    /// 5. Detect whichever application is frontmost at that moment.
    /// 6. Type into that application character-by-character via CGEvent.
    ///
    /// This approach never assumes which application the user wants to type
    /// into — it dynamically reads the frontmost app at the moment of typing.
    /// Works with PVE/noVNC, KVM/SPICE, terminals, browsers, etc.
    ///
    /// - Parameters:
    ///   - id: The entry to type.
    ///   - delayBetweenKeys: Inter-keystroke delay in seconds.
    ///   - countdownSeconds: Seconds to wait for the user to focus the
    ///     target window.  Default is 3.
    func typeEntryValue(
        id: UUID,
        delayBetweenKeys: TimeInterval = 0.05,
        countdownSeconds: Int = 3
    ) {
        guard let entry = storageService.getEntry(byId: id) else {
            showStatusMessage("找不到条目")
            return
        }

        guard clipboardService.checkAccessibilityPermission() else {
            autoGrantAccessibility()
            return
        }

        Task { @MainActor in
            // 1. Authenticate
            let authenticated = await biometricService.authenticate(reason: "键入密码「\(entry.title)」")
            guard authenticated else {
                showStatusMessage("认证已取消")
                return
            }

            // 2. Decrypt
            let plainText: String
            do {
                plainText = try encryptionService.decryptToString(entry.encryptedValue)
            } catch {
                showStatusMessage("解密失败: \(error.localizedDescription)")
                return
            }

            // 3. Hide MacKeyValue to get out of the way
            NSApp.hide(nil)

            // 4. Countdown — give the user time to click the target input field
            for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
                showStatusMessage("⏳ \(remaining) 秒后将键入到当前焦点窗口，请点击目标输入框…")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            // 5. Detect the current frontmost app (whatever the user focused)
            let targetApp = NSWorkspace.shared.frontmostApplication
            let targetName = targetApp?.localizedName ?? "未知应用"
            let targetPID = targetApp?.processIdentifier ?? -1
            let myPID = ProcessInfo.processInfo.processIdentifier

            // Safety check: don't type into ourselves
            if targetPID == myPID {
                showStatusMessage("⚠️ 当前焦点是 MacKeyValue 自身，请先切换到目标窗口再重试")
                return
            }

            showStatusMessage("正在键入到「\(targetName)」…（\(plainText.count) 字符）")

            // 6. Type on a background thread
            nonisolated(unsafe) let clipSvc = self.clipboardService
            let storageSvc = self.storageService
            let entryTitle = entry.title

            let typeResult: Result<Void, Error> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    // Give the system a moment to stabilize focus after our
                    // status message overlay may have briefly flickered.
                    Thread.sleep(forTimeInterval: 0.15)

                    // Log what we're about to do
                    let currentApp = NSWorkspace.shared.frontmostApplication
                    print("[typeEntryValue] Typing \(plainText.count) chars into: \(currentApp?.localizedName ?? "?") (pid=\(currentApp?.processIdentifier ?? -1))")

                    do {
                        try clipSvc.simulateTyping(plainText, delayBetweenKeys: delayBetweenKeys)
                        continuation.resume(returning: .success(()))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }

            switch typeResult {
            case .success:
                try? storageSvc.recordEntryUsage(id: id)
                reloadEntries()
                showStatusMessage("✅ 已键入「\(entryTitle)」到「\(targetName)」（\(plainText.count) 字符）")
            case .failure(let error):
                showStatusMessage("❌ 键入失败: \(error.localizedDescription)")
            }
        }
    }

    /// Opens System Settings → Privacy & Security → Accessibility directly.
    /// Useful as a standalone action from settings UI or menu bar.
    func openAccessibilitySettings() {
        clipboardService.openAccessibilitySystemSettings()
        clipboardService.startAccessibilityPolling()
        showStatusMessage("正在打开系统设置 → 辅助功能，请为 MacKeyValue 开启开关...")
    }

    /// One-shot accessibility grant flow — shows an in-app animated guide
    /// that walks the user through the permission grant process.
    ///
    /// **First call**: shows the accessibility guide overlay with animated steps.
    /// **Subsequent calls**: re-shows the guide if permission is still not granted.
    func autoGrantAccessibility() {
        // Re-check in case permission was granted in the meantime.
        if clipboardService.checkAccessibilityPermission() {
            isAccessibilityGranted = true
            showAccessibilityGuide = false
            showStatusMessage("✅ 辅助功能权限已生效，请重试操作")
            return
        }

        // Show the animated accessibility guide overlay.
        showAccessibilityGuide = true

        // Ensure polling is running so the guide auto-dismisses when granted.
        clipboardService.startAccessibilityPolling(timeoutSeconds: 300)
    }

    /// Manually refreshes the cached accessibility permission state.
    /// Safe to call from button actions — never call from within a view body.
    ///
    /// Also performs a practical CGEvent test. If `AXIsProcessTrusted()` is
    /// `true` but the event source can't be created, it likely means the
    /// kernel still has a stale cdhash and the app needs to be restarted.
    func refreshAccessibilityPermission() {
        let axTrusted = AXIsProcessTrusted()
        let canPost = clipboardService.canActuallyPostEvents()
        print("[RefreshPermission] AXIsProcessTrusted=\(axTrusted), canActuallyPostEvents=\(canPost), cached=\(isAccessibilityGranted)")

        if axTrusted && canPost {
            if !isAccessibilityGranted {
                isAccessibilityGranted = true
                ClipboardService.resetEventSource()
                clipboardService.stopAccessibilityPolling()
                showAccessibilityGuide = false
            }
            return
        }

        if axTrusted && !canPost {
            // AXIsProcessTrusted says yes but practical test fails —
            // the kernel likely has a stale cdhash. Need restart.
            print("[RefreshPermission] ⚠️  AXIsProcessTrusted=true but CGEventSource unavailable — need restart")
            showStatusMessage("⚠️ 权限已授予但尚未生效，请点击「重启应用」", duration: 10)
        }
        // If !axTrusted, the user still needs to grant permission.
    }

    /// Copies a clipboard history item's content to the current clipboard.
    func pasteFromHistory(_ item: ClipboardHistoryItem) {
        clipboardService.copyToClipboard(item.content)
        showStatusMessage("已复制历史记录到剪贴板")
    }

    /// Deletes a clipboard history item.
    func deleteClipboardHistoryItem(id: UUID) {
        storageService.deleteClipboardHistoryItem(id: id)
        reloadClipboardHistory()
    }

    /// Clears clipboard history (optionally keeping pinned items).
    func clearClipboardHistory(keepPinned: Bool = true) {
        storageService.clearClipboardHistory(keepPinned: keepPinned)
        reloadClipboardHistory()
        showStatusMessage(keepPinned ? "已清除未固定的剪贴板历史" : "已清除全部剪贴板历史")
    }

    /// Toggles the pinned state of a clipboard history item.
    func toggleClipboardItemPin(id: UUID) {
        storageService.toggleClipboardItemPin(id: id)
        reloadClipboardHistory()
    }

    /// Clears the current system clipboard.
    func clearClipboard() {
        clipboardService.clearClipboard()
        showStatusMessage("剪贴板已清除")
    }

    // MARK: - Gist Sync

    /// Performs a full sync with GitHub Gist.
    func performGistSync() async {
        guard gistSyncService.hasToken else {
            showStatusMessage("请先配置 GitHub Token")
            activeSheet = .gistSync
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            let result = try await gistSyncService.performFullSync()
            reloadEntries()
            showStatusMessage("同步完成: \(result.summary)")
        } catch {
            showStatusMessage("同步失败: \(error.localizedDescription)")
        }
    }

    /// Pushes local entries to the Gist (upload only).
    func pushToGist() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let result = try await gistSyncService.pushToGist()
            showStatusMessage("上传完成: \(result.summary)")
        } catch {
            showStatusMessage("上传失败: \(error.localizedDescription)")
        }
    }

    /// Pulls entries from the Gist (download only).
    func pullFromGist() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let result = try await gistSyncService.pullFromGist()
            reloadEntries()
            showStatusMessage("下载完成: \(result.summary)")
        } catch {
            showStatusMessage("下载失败: \(error.localizedDescription)")
        }
    }

    /// Saves a GitHub personal access token.
    func saveGistToken(_ token: String) {
        do {
            try gistSyncService.saveToken(token)
            showStatusMessage("GitHub Token 已保存")
        } catch {
            showStatusMessage("保存 Token 失败: \(error.localizedDescription)")
        }
    }

    /// Validates the stored GitHub token.
    func validateGistToken() async -> Bool {
        do {
            let valid = try await gistSyncService.validateToken()
            if valid {
                showStatusMessage("GitHub Token 验证通过")
            }
            return valid
        } catch {
            showStatusMessage("Token 验证失败: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Hotkey Handling

    /// Called when a global hotkey is triggered.
    private func handleHotkeyTriggered(_ binding: HotkeyBinding) {
        switch binding.actionType {
        case .showPopover:
            toggleMainWindow()
        case .quickSearch:
            activeSheet = .quickSearch
        case .showClipboardHistory:
            activeSheet = .clipboardHistory
        case .togglePrivacyMode:
            isPrivacyMode.toggle()
            showStatusMessage(isPrivacyMode ? "隐私模式已开启" : "隐私模式已关闭")
        case .copyPassword:
            if let entryId = binding.entryId {
                copyEntryValue(id: entryId)
            }
        case .typePassword:
            if let entryId = binding.entryId {
                if !clipboardService.checkAccessibilityPermission() {
                    autoGrantAccessibility()
                } else {
                    typeEntryValue(id: entryId)
                }
            }
        case .custom:
            break
        }
    }

    // MARK: - Window Management

    /// Toggles visibility of the main application window.
    func toggleMainWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    /// Activates the app and brings its windows to front.
    func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: - Import / Export

    /// Exports all non-private entries to a JSON file at the given URL.
    func exportEntries(to url: URL, includePrivate: Bool = false) {
        do {
            let data = try storageService.exportEntries(includePrivate: includePrivate)
            try data.write(to: url, options: .atomic)
            showStatusMessage("已导出 \(entries.count) 条记录到 \(url.lastPathComponent)")
        } catch {
            showStatusMessage("导出失败: \(error.localizedDescription)")
        }
    }

    /// Imports entries from a JSON file at the given URL.
    func importEntries(from url: URL, overwriteExisting: Bool = false) {
        do {
            let data = try Data(contentsOf: url)
            let count = try storageService.importEntries(from: data, overwriteExisting: overwriteExisting)
            reloadEntries()
            showStatusMessage("已导入 \(count) 条记录")
        } catch {
            showStatusMessage("导入失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Utility

    /// Returns the decrypted value of an entry (for display in detail view).
    /// NOTE: This synchronous variant does not require biometric auth — use it
    /// only when the user has already been authenticated via another flow.
    func decryptedValue(for entry: KeyValueEntry) -> String? {
        do {
            return try encryptionService.decryptToString(entry.encryptedValue)
        } catch {
            return nil
        }
    }

    /// Authenticates via Touch ID / password and then decrypts the value.
    /// Uses session caching so only the first call within `sessionDuration`
    /// prompts the user.
    func decryptedValueWithAuth(for entry: KeyValueEntry) async -> String? {
        let authenticated = await biometricService.authenticate(reason: "查看密码「\(entry.title)」")
        guard authenticated else { return nil }
        do {
            return try encryptionService.decryptToString(entry.encryptedValue)
        } catch {
            return nil
        }
    }

    /// Returns the selected entry, if any.
    var selectedEntry: KeyValueEntry? {
        guard let id = selectedEntryId else { return nil }
        return storageService.getEntry(byId: id)
    }

    /// Returns the total number of entries.
    var totalEntryCount: Int {
        entries.count
    }

    /// Entries filtered by the compact-mode search text.
    ///
    /// Supports **regex** search when the query is wrapped in `/pattern/`.
    /// Returns all entries when the search text is empty, sorted by
    /// most-recently-used first.
    var compactFilteredEntries: [KeyValueEntry] {
        let base = entries.sorted { a, b in
            let aDate = a.lastUsedAt ?? a.updatedAt
            let bDate = b.lastUsedAt ?? b.updatedAt
            return aDate > bDate
        }
        guard !compactSearchText.isEmpty else { return base }

        // Delegate to StorageService which already supports /regex/ syntax.
        return storageService.searchEntries(query: compactSearchText)
            .sorted { a, b in
                let aDate = a.lastUsedAt ?? a.updatedAt
                let bDate = b.lastUsedAt ?? b.updatedAt
                return aDate > bDate
            }
    }

    /// Toggles between compact and full UI mode and resizes the window
    /// to fit the new layout.
    func toggleUIMode() {
        uiMode = (uiMode == .compact) ? .full : .compact
        resizeWindowForCurrentMode()
    }

    /// Resizes the main window to fit the current `uiMode`.
    func resizeWindowForCurrentMode() {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.isVisible && $0.contentView?.subviews.isEmpty == false
        }) else { return }

        let targetSize: NSSize
        switch uiMode {
        case .compact:
            targetSize = NSSize(width: 420, height: 520)
        case .full:
            targetSize = NSSize(width: 1000, height: 650)
        }

        // Animate the window frame change, keeping the top-left corner pinned.
        let oldFrame = window.frame
        let newOriginY = oldFrame.origin.y + oldFrame.size.height - targetSize.height
        let newFrame = NSRect(
            origin: NSPoint(x: oldFrame.origin.x, y: newOriginY),
            size: targetSize
        )
        window.setFrame(newFrame, display: true, animate: true)

        // Update min size so the user can't shrink below reasonable bounds.
        switch uiMode {
        case .compact:
            window.minSize = NSSize(width: 380, height: 300)
        case .full:
            window.minSize = NSSize(width: 800, height: 500)
        }
    }

    /// Returns a human-readable storage size string.
    var storageSizeFormatted: String {
        storageService.formattedStorageSize()
    }

    // MARK: - Status Messages

    /// Displays a transient status message that auto-dismisses after a few seconds.
    func showStatusMessage(_ message: String, duration: TimeInterval = 3.0) {
        statusMessage = message
        isStatusMessageVisible = true

        // Cancel any previous auto-dismiss
        statusMessageTask?.cancel()

        statusMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isStatusMessageVisible = false
        }
    }

    /// Dismisses the current status message immediately.
    func dismissStatusMessage() {
        statusMessageTask?.cancel()
        isStatusMessageVisible = false
    }

    // MARK: - Onboarding

    /// Completes the onboarding flow and transitions to the unlocked state.
    func completeOnboarding() {
        appState = .unlocked
        showStatusMessage("欢迎使用 MacKeyValue！")
    }
}
