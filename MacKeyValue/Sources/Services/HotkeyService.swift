import AppKit
import Carbon
import Combine
import Foundation

// MARK: - HotkeyError

enum HotkeyError: LocalizedError {
    case registrationFailed(String)
    case unregistrationFailed(String)
    case invalidKeyCombo(String)
    case accessibilityNotGranted
    case duplicateHotkey(String)
    case hotkeyNotFound(String)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let reason):
            return "Failed to register hotkey: \(reason)"
        case .unregistrationFailed(let reason):
            return "Failed to unregister hotkey: \(reason)"
        case .invalidKeyCombo(let reason):
            return "Invalid key combination: \(reason)"
        case .accessibilityNotGranted:
            return "Accessibility permission is required for global hotkeys"
        case .duplicateHotkey(let name):
            return "Hotkey '\(name)' is already registered"
        case .hotkeyNotFound(let name):
            return "Hotkey '\(name)' is not registered"
        }
    }
}

// MARK: - KeyCombo

/// Represents a keyboard shortcut combination (modifier flags + key code).
struct KeyCombo: Codable, Hashable, CustomStringConvertible {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Human-readable key name (e.g. "V", "C", "1").
    let keyName: String

    /// Whether Cmd is held.
    var hasCommand: Bool { modifiers & UInt32(cmdKey) != 0 }
    /// Whether Option/Alt is held.
    var hasOption: Bool { modifiers & UInt32(optionKey) != 0 }
    /// Whether Control is held.
    var hasControl: Bool { modifiers & UInt32(controlKey) != 0 }
    /// Whether Shift is held.
    var hasShift: Bool { modifiers & UInt32(shiftKey) != 0 }

    var description: String {
        var parts: [String] = []
        if hasControl { parts.append("⌃") }
        if hasOption { parts.append("⌥") }
        if hasShift { parts.append("⇧") }
        if hasCommand { parts.append("⌘") }
        parts.append(keyName)
        return parts.joined()
    }

    /// Creates a `KeyCombo` from Cocoa-style modifier flags and a virtual key code.
    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// Creates a `KeyCombo` from `NSEvent`-style modifier flags and a virtual key code.
    init(keyCode: UInt16, cocoaModifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = KeyCombo.cocoaToCarbonModifiers(cocoaModifiers)
        self.keyName = keyName
    }

    /// Converts `NSEvent.ModifierFlags` to Carbon modifier mask.
    static func cocoaToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Converts Carbon modifier mask to `NSEvent.ModifierFlags`.
    static func carbonToCocoaModifiers(_ carbonMods: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonMods & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonMods & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonMods & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonMods & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }
}

// MARK: - HotkeyBinding

/// Associates a name, key combo, and action with a registered global hotkey.
struct HotkeyBinding: Identifiable, Codable {
    let id: UUID
    var name: String
    var keyCombo: KeyCombo
    var isEnabled: Bool
    var entryId: UUID?
    var actionType: ActionType

    enum ActionType: String, Codable, CaseIterable {
        case copyPassword         = "copy_password"
        case typePassword         = "type_password"
        case showPopover          = "show_popover"
        case togglePrivacyMode    = "toggle_privacy_mode"
        case showClipboardHistory = "show_clipboard_history"
        case quickSearch          = "quick_search"
        case captureScreenshot    = "capture_screenshot"
        case ocrScreenshot        = "ocr_screenshot"
        case custom               = "custom"

        var displayName: String {
            switch self {
            case .copyPassword:         return "复制密码"
            case .typePassword:         return "键入密码"
            case .showPopover:          return "显示弹窗"
            case .togglePrivacyMode:    return "切换隐私模式"
            case .showClipboardHistory: return "显示剪贴板历史"
            case .quickSearch:          return "快速搜索"
            case .captureScreenshot:    return "截图到剪贴板"
            case .ocrScreenshot:        return "截图 OCR 文字识别"
            case .custom:               return "自定义"
            }
        }

        var icon: String {
            switch self {
            case .copyPassword:         return "doc.on.doc"
            case .typePassword:         return "keyboard"
            case .showPopover:          return "rectangle.on.rectangle"
            case .togglePrivacyMode:    return "eye.slash"
            case .showClipboardHistory: return "doc.on.clipboard"
            case .quickSearch:          return "magnifyingglass"
            case .captureScreenshot:    return "camera.viewfinder"
            case .ocrScreenshot:        return "doc.text.viewfinder"
            case .custom:               return "wand.and.stars"
            }
        }

        /// Whether this action type requires an associated entry (entryId).
        var requiresEntry: Bool {
            self == .copyPassword || self == .typePassword
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        keyCombo: KeyCombo,
        isEnabled: Bool = true,
        entryId: UUID? = nil,
        actionType: ActionType = .custom
    ) {
        self.id = id
        self.name = name
        self.keyCombo = keyCombo
        self.isEnabled = isEnabled
        self.entryId = entryId
        self.actionType = actionType
    }
}

// MARK: - HotkeyService

/// Manages global keyboard shortcuts using the Carbon Event API.
///
/// Each registered hotkey is backed by a Carbon `EventHotKeyRef`. When the user
/// presses the corresponding key combination anywhere in the system, the service
/// looks up the associated `HotkeyBinding` and executes its action (e.g. copy
/// a password to the clipboard, simulate keyboard typing, show the app popover).
///
/// Hotkey bindings are persisted to disk so they survive app restarts.
final class HotkeyService: ObservableObject {

    // MARK: - Constants

    private enum Constants {
        static let hotkeySignature: FourCharCode = {
            let chars = "MKVL".unicodeScalars
            let a = chars[chars.startIndex]
            let b = chars[chars.index(after: chars.startIndex)]
            let c = chars[chars.index(chars.startIndex, offsetBy: 2)]
            let d = chars[chars.index(chars.startIndex, offsetBy: 3)]
            return FourCharCode(a.value) << 24 | FourCharCode(b.value) << 16 | FourCharCode(c.value) << 8 | FourCharCode(d.value)
        }()
        static let bindingsFileName = "hotkey_bindings.json"
    }

    // MARK: - Singleton

    static let shared = HotkeyService()

    // MARK: - Published Properties

    @Published private(set) var bindings: [HotkeyBinding] = []
    @Published private(set) var isListening: Bool = false

    // MARK: - Callbacks

    /// Called when a hotkey action should be executed. The service consumer (e.g.
    /// the main ViewModel) should set this to handle the action.
    var onHotkeyTriggered: ((HotkeyBinding) -> Void)?

    // MARK: - Private Properties

    /// Maps a hotkey ID (Int) to its registered Carbon ref and binding info.
    private var registeredHotkeys: [UInt32: (ref: EventHotKeyRef, binding: HotkeyBinding)] = [:]

    /// Next available hotkey ID counter.
    private var nextHotkeyId: UInt32 = 1

    /// Reference to the installed Carbon event handler.
    private var eventHandlerRef: EventHandlerRef?

    private let persistenceQueue = DispatchQueue(label: "com.mackeyvalue.hotkey.persistence")

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

    private init() {
        loadBindings()
    }

    deinit {
        unregisterAll()
        removeEventHandler()
    }

    // MARK: - Setup & Teardown

    /// Installs the Carbon event handler and registers all persisted bindings.
    func start() {
        guard !isListening else { return }
        installEventHandler()
        registerAllPersistedBindings()
        isListening = true
    }

    /// Unregisters all hotkeys and removes the Carbon event handler.
    func stop() {
        unregisterAll()
        removeEventHandler()
        isListening = false
    }

    // MARK: - Public API – Binding Management

    /// Registers a new hotkey binding. Returns the created binding.
    @discardableResult
    func addBinding(_ binding: HotkeyBinding) throws -> HotkeyBinding {
        // Check for duplicates (same key combo)
        if bindings.contains(where: { $0.keyCombo == binding.keyCombo && $0.isEnabled }) {
            throw HotkeyError.duplicateHotkey(binding.name)
        }

        var mutableBinding = binding
        if mutableBinding.isEnabled {
            try registerCarbonHotkey(&mutableBinding)
        }

        bindings.append(mutableBinding)
        saveBindings()
        return mutableBinding
    }

    /// Updates an existing hotkey binding. The old Carbon hotkey is unregistered and
    /// a new one is registered with the updated key combo (if enabled).
    @discardableResult
    func updateBinding(_ binding: HotkeyBinding) throws -> HotkeyBinding {
        guard let index = bindings.firstIndex(where: { $0.id == binding.id }) else {
            throw HotkeyError.hotkeyNotFound(binding.name)
        }

        // Unregister the old Carbon hotkey
        unregisterCarbonHotkey(for: bindings[index])

        var mutableBinding = binding
        if mutableBinding.isEnabled {
            // Check for duplicates (same key combo, different binding)
            if bindings.contains(where: { $0.keyCombo == mutableBinding.keyCombo && $0.id != mutableBinding.id && $0.isEnabled }) {
                throw HotkeyError.duplicateHotkey(mutableBinding.name)
            }
            try registerCarbonHotkey(&mutableBinding)
        }

        bindings[index] = mutableBinding
        saveBindings()
        return mutableBinding
    }

    /// Removes a hotkey binding by its ID.
    func removeBinding(id: UUID) throws {
        guard let index = bindings.firstIndex(where: { $0.id == id }) else {
            throw HotkeyError.hotkeyNotFound(id.uuidString)
        }

        unregisterCarbonHotkey(for: bindings[index])
        bindings.remove(at: index)
        saveBindings()
    }

    /// Enables or disables a specific binding.
    func setBindingEnabled(id: UUID, enabled: Bool) throws {
        guard let index = bindings.firstIndex(where: { $0.id == id }) else {
            throw HotkeyError.hotkeyNotFound(id.uuidString)
        }

        if enabled && !bindings[index].isEnabled {
            // Register the Carbon hotkey
            var binding = bindings[index]
            binding.isEnabled = true
            try registerCarbonHotkey(&binding)
            bindings[index] = binding
        } else if !enabled && bindings[index].isEnabled {
            // Unregister the Carbon hotkey
            unregisterCarbonHotkey(for: bindings[index])
            bindings[index].isEnabled = false
        }

        saveBindings()
    }

    /// Returns the binding associated with a specific entry, if any.
    func binding(forEntryId entryId: UUID) -> HotkeyBinding? {
        bindings.first(where: { $0.entryId == entryId })
    }

    /// Returns all bindings of a given action type.
    func bindings(forActionType actionType: HotkeyBinding.ActionType) -> [HotkeyBinding] {
        bindings.filter { $0.actionType == actionType }
    }

    // MARK: - Default Bindings

    /// Registers the default set of hotkeys if no bindings exist yet.
    func registerDefaultBindingsIfNeeded() {
        guard bindings.isEmpty else { return }

        let defaults: [HotkeyBinding] = [
            HotkeyBinding(
                name: "显示/隐藏主窗口",
                keyCombo: KeyCombo(
                    keyCode: UInt32(kVK_ANSI_K),
                    modifiers: UInt32(cmdKey) | UInt32(shiftKey),
                    keyName: "K"
                ),
                actionType: .showPopover
            ),
            HotkeyBinding(
                name: "快速搜索",
                keyCombo: KeyCombo(
                    keyCode: UInt32(kVK_Space),
                    modifiers: UInt32(cmdKey) | UInt32(optionKey),
                    keyName: "Space"
                ),
                actionType: .quickSearch
            ),
            HotkeyBinding(
                name: "剪贴板历史",
                keyCombo: KeyCombo(
                    keyCode: UInt32(kVK_ANSI_V),
                    modifiers: UInt32(cmdKey) | UInt32(shiftKey),
                    keyName: "V"
                ),
                actionType: .showClipboardHistory
            ),
            HotkeyBinding(
                name: "切换隐私模式",
                keyCombo: KeyCombo(
                    keyCode: UInt32(kVK_ANSI_P),
                    modifiers: UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey),
                    keyName: "P"
                ),
                actionType: .togglePrivacyMode
            ),
            HotkeyBinding(
                name: "截图到剪贴板",
                keyCombo: KeyCombo(
                    keyCode: UInt32(kVK_ANSI_4),
                    modifiers: UInt32(cmdKey) | UInt32(shiftKey),
                    keyName: "4"
                ),
                actionType: .captureScreenshot
            ),
            HotkeyBinding(
                name: "截图 OCR",
                keyCombo: KeyCombo(
                    keyCode: UInt32(kVK_ANSI_5),
                    modifiers: UInt32(cmdKey) | UInt32(shiftKey),
                    keyName: "5"
                ),
                actionType: .ocrScreenshot
            ),
        ]

        for binding in defaults {
            _ = try? addBinding(binding)
        }
    }

    // MARK: - Private – Carbon Event Handler

    /// Installs a Carbon event handler that listens for `kEventHotKeyPressed`.
    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // We need a C function pointer; use an `@convention(c)` closure isn't possible
        // directly, so we use a global function pointer via `Unmanaged` + `userData`.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                return service.handleCarbonHotkeyEvent(event)
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        if status != noErr {
            print("[HotkeyService] Failed to install event handler: \(status)")
        }
    }

    /// Removes the Carbon event handler.
    private func removeEventHandler() {
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    /// Called by the Carbon event handler when a registered hotkey is pressed.
    private func handleCarbonHotkeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event = event else { return OSStatus(eventNotHandledErr) }

        var hotkeyId = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyId
        )

        guard status == noErr else {
            return status
        }

        guard hotkeyId.signature == Constants.hotkeySignature else {
            return OSStatus(eventNotHandledErr)
        }

        let id = hotkeyId.id
        guard let entry = registeredHotkeys[id] else {
            return OSStatus(eventNotHandledErr)
        }

        // Dispatch the action on the main queue
        DispatchQueue.main.async { [weak self] in
            self?.executeAction(for: entry.binding)
        }

        return noErr
    }

    // MARK: - Private – Carbon Hotkey Registration

    /// Registers a Carbon hotkey for the given binding and stores the ref.
    private func registerCarbonHotkey(_ binding: inout HotkeyBinding) throws {
        let hotkeyId = nextHotkeyId
        nextHotkeyId += 1

        let carbonHotkeyId = EventHotKeyID(
            signature: Constants.hotkeySignature,
            id: hotkeyId
        )

        var hotkeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCombo.keyCode,
            binding.keyCombo.modifiers,
            carbonHotkeyId,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        guard status == noErr, let ref = hotkeyRef else {
            throw HotkeyError.registrationFailed("Carbon RegisterEventHotKey failed with status \(status)")
        }

        registeredHotkeys[hotkeyId] = (ref: ref, binding: binding)
    }

    /// Unregisters the Carbon hotkey associated with a binding.
    private func unregisterCarbonHotkey(for binding: HotkeyBinding) {
        // Find the registered hotkey entry by matching the binding ID
        guard let (id, entry) = registeredHotkeys.first(where: { $0.value.binding.id == binding.id }) else {
            return
        }

        UnregisterEventHotKey(entry.ref)
        registeredHotkeys.removeValue(forKey: id)
    }

    /// Unregisters all Carbon hotkeys.
    private func unregisterAll() {
        for (_, entry) in registeredHotkeys {
            UnregisterEventHotKey(entry.ref)
        }
        registeredHotkeys.removeAll()
    }

    /// Re-registers Carbon hotkeys for all persisted bindings that are enabled.
    private func registerAllPersistedBindings() {
        for i in bindings.indices {
            guard bindings[i].isEnabled else { continue }
            var binding = bindings[i]
            do {
                try registerCarbonHotkey(&binding)
                bindings[i] = binding
            } catch {
                print("[HotkeyService] Failed to register hotkey '\(binding.name)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private – Action Execution

    /// Executes the action associated with a triggered hotkey binding.
    private func executeAction(for binding: HotkeyBinding) {
        // Notify the callback handler (primary way for the app to respond)
        onHotkeyTriggered?(binding)

        // Built-in action handling as fallback
        switch binding.actionType {
        case .copyPassword:
            handleCopyPassword(binding)
        case .typePassword:
            handleTypePassword(binding)
        case .togglePrivacyMode:
            ClipboardService.shared.togglePrivacyMode()
        case .captureScreenshot:
            Task { await ScreenCaptureService.shared.captureToClipboard() }
        case .ocrScreenshot:
            Task { await ScreenCaptureService.shared.captureAndOCR() }
        case .showPopover, .showClipboardHistory, .quickSearch, .custom:
            // These are handled by the onHotkeyTriggered callback in AppViewModel
            break
        }
    }

    /// Copies the decrypted value of the associated entry to the clipboard.
    /// The user can then press ⌘V in any target app to paste normally.
    private func handleCopyPassword(_ binding: HotkeyBinding) {
        guard let entryId = binding.entryId,
              let entry = StorageService.shared.getEntry(byId: entryId) else {
            return
        }

        do {
            try ClipboardService.shared.copyDecryptedValue(entry.encryptedValue, clearAfter: 120)
            try StorageService.shared.recordEntryUsage(id: entryId)
        } catch {
            print("[HotkeyService] Failed to copy password for entry \(entryId): \(error.localizedDescription)")
        }
    }

    /// Simulates typing the decrypted value character-by-character into
    /// **whichever application currently has focus**.
    ///
    /// When triggered via a global hotkey, the user is already in the target
    /// app.  We just need a short delay for the modifier keys to be released,
    /// then we dynamically read `NSWorkspace.shared.frontmostApplication`
    /// and type into it.
    private func handleTypePassword(_ binding: HotkeyBinding) {
        guard let entryId = binding.entryId,
              let entry = StorageService.shared.getEntry(byId: entryId) else {
            return
        }

        let plainText: String
        do {
            plainText = try EncryptionService.shared.decryptToString(entry.encryptedValue)
        } catch {
            print("[HotkeyService] Failed to decrypt entry \(entryId): \(error.localizedDescription)")
            return
        }

        DispatchQueue.global(qos: .userInteractive).async {
            // Wait for the hotkey modifier keys to be physically released.
            Thread.sleep(forTimeInterval: 0.5)

            // Dynamically detect the current frontmost app — do NOT
            // activate a different app; just type into whatever has focus.
            let targetApp = NSWorkspace.shared.frontmostApplication
            let targetName = targetApp?.localizedName ?? "unknown"
            let targetPID = targetApp?.processIdentifier ?? -1
            print("[HotkeyService] Typing \(plainText.count) chars into: \(targetName) (pid=\(targetPID))")

            do {
                try ClipboardService.shared.simulateTyping(plainText, delayBetweenKeys: 0.05)
                try StorageService.shared.recordEntryUsage(id: entryId)
                print("[HotkeyService] ✅ Typed \(plainText.count) chars into \(targetName)")
            } catch {
                print("[HotkeyService] ❌ Failed to type into \(targetName): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    private func bindingsFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("MacKeyValue", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Constants.bindingsFileName)
    }

    private func loadBindings() {
        let url = bindingsFileURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let loaded = try? decoder.decode([HotkeyBinding].self, from: data) else {
            return
        }
        self.bindings = loaded
    }

    private func saveBindings() {
        persistenceQueue.async { [weak self] in
            guard let self = self else { return }
            let url = self.bindingsFileURL()
            guard let data = try? self.encoder.encode(self.bindings) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Key Code Helpers

    /// Returns a human-readable name for a virtual key code.
    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Escape"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        default: return "Key(\(keyCode))"
        }
    }

    /// Creates a `KeyCombo` from an `NSEvent` (useful for hotkey recording UI).
    static func keyCombo(from event: NSEvent) -> KeyCombo? {
        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Require at least one modifier key
        guard !modifiers.isEmpty else { return nil }

        // Ignore modifier-only events (no actual key pressed)
        let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !modifierOnlyKeyCodes.contains(keyCode) else { return nil }

        let name = keyName(for: keyCode)

        return KeyCombo(
            keyCode: keyCode,
            cocoaModifiers: modifiers,
            keyName: name
        )
    }
}

// MARK: - FourCharCode Helper

private extension FourCharCode {
    init(_ string: String) {
        precondition(string.count == 4, "FourCharCode must be exactly 4 characters")
        self = string.utf8.reduce(0) { ($0 << 8) + FourCharCode($1) }
    }
}
