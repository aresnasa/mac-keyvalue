import AppKit
import Carbon
import Combine
import Foundation

// MARK: - ClipboardServiceError

enum ClipboardServiceError: LocalizedError {
    case pasteboardUnavailable
    case contentUnavailable
    case typeSimulationFailed(String)
    case accessibilityNotGranted

    var errorDescription: String? {
        switch self {
        case .pasteboardUnavailable:
            return "System pasteboard is not available"
        case .contentUnavailable:
            return "No content available on the pasteboard"
        case .typeSimulationFailed(let reason):
            return "Failed to simulate keyboard typing: \(reason)"
        case .accessibilityNotGranted:
            return "Accessibility permission is required for keyboard simulation. Please grant access in System Settings → Privacy & Security → Accessibility."
        }
    }
}

// MARK: - ClipboardChangeInfo

/// Information about a clipboard change event.
struct ClipboardChangeInfo {
    let content: String
    let contentType: ClipboardHistoryItem.ContentType
    let sourceApplication: String?
    let timestamp: Date
}

// MARK: - ClipboardService

/// Monitors the macOS system pasteboard for changes, maintains a clipboard history,
/// and provides methods to copy, paste, and simulate keyboard input.
///
/// The service polls the system pasteboard at a configurable interval. When new
/// content is detected it publishes the change through a Combine subject and
/// optionally records the item in `StorageService`.
final class ClipboardService: ObservableObject, @unchecked Sendable {

    // MARK: - Singleton

    static let shared = ClipboardService()

    // MARK: - Published Properties

    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var isPrivacyMode: Bool = false
    @Published private(set) var lastClipboardContent: String = ""

    /// Reflects whether Accessibility permission is currently granted.
    /// UI can observe this to show/hide permission prompts reactively.
    @Published private(set) var isAccessibilityGranted: Bool = false

    // MARK: - Combine

    /// Publishes every clipboard change detected by the polling loop.
    let clipboardChanged = PassthroughSubject<ClipboardChangeInfo, Never>()

    /// Fires once when accessibility permission transitions from denied → granted.
    let accessibilityGranted = PassthroughSubject<Void, Never>()

    // MARK: - Configuration

    /// How often the pasteboard is polled for changes (in seconds).
    var pollingInterval: TimeInterval = 0.5

    /// Maximum length of content to record in history (characters).
    var maxContentLength: Int = 50_000

    // MARK: - Private Properties

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private var pollingTimer: DispatchSourceTimer?
    private let pollingQueue = DispatchQueue(label: "com.mackeyvalue.clipboard.polling", qos: .utility)
    private var cancellables = Set<AnyCancellable>()

    /// Timer that polls for accessibility permission changes after the user
    /// has been sent to System Settings.
    private var accessibilityPollTimer: DispatchSourceTimer?

    /// When privacy mode is active we still copy/paste but do NOT record history.
    private var storageService: StorageService { StorageService.shared }

    // MARK: - Initialization

    private init() {
        lastChangeCount = pasteboard.changeCount
        // Seed the initial accessibility state (no prompt).
        isAccessibilityGranted = checkAccessibilityPermission()
    }

    // MARK: - Monitoring Control

    /// Starts polling the system pasteboard for new content.
    func startMonitoring() {
        guard !isMonitoring else { return }

        lastChangeCount = pasteboard.changeCount
        isMonitoring = true

        let timer = DispatchSource.makeTimerSource(queue: pollingQueue)
        timer.schedule(
            deadline: .now() + pollingInterval,
            repeating: pollingInterval,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.pollPasteboard()
        }
        timer.resume()
        pollingTimer = timer
    }

    /// Stops pasteboard polling.
    func stopMonitoring() {
        pollingTimer?.cancel()
        pollingTimer = nil
        isMonitoring = false
    }

    // MARK: - Privacy Mode

    /// Enables or disables privacy mode.
    /// In privacy mode clipboard changes are NOT recorded to history / storage.
    func setPrivacyMode(_ enabled: Bool) {
        isPrivacyMode = enabled
    }

    func togglePrivacyMode() {
        isPrivacyMode.toggle()
    }

    // MARK: - Copy

    /// Copies the given plain-text string to the system pasteboard.
    func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount

        DispatchQueue.main.async { [weak self] in
            self?.lastClipboardContent = text
        }
    }

    /// Copies the given string to the system pasteboard and records it in history
    /// (unless privacy mode is active).
    func copyToClipboardAndRecord(_ text: String, isPrivate: Bool = false) {
        copyToClipboard(text)

        if !isPrivacyMode && !isPrivate {
            let item = ClipboardHistoryItem(
                content: text,
                contentType: detectContentType(text),
                sourceApplication: NSWorkspace.shared.frontmostApplication?.localizedName,
                isPinned: false,
                isPrivate: isPrivate
            )
            storageService.addClipboardHistoryItem(item)
        }
    }

    // MARK: - Paste

    /// Returns the current string content of the pasteboard, if any.
    func getClipboardContent() -> String? {
        return pasteboard.string(forType: .string)
    }

    /// Simulates a ⌘V paste keystroke via CGEvent.
    func simulatePaste() throws {
        guard checkAccessibilityPermission() else {
            throw ClipboardServiceError.accessibilityNotGranted
        }

        // Brief pause to let the target app's input field settle focus
        // before we inject the paste keystroke.
        Thread.sleep(forTimeInterval: 0.1)

        // Key code 9 = 'V'
        let keyCode: CGKeyCode = 9

        let src = Self.sharedEventSource
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            throw ClipboardServiceError.typeSimulationFailed("Failed to create paste key events")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard Simulation (Type Text)

    /// Simulates typing the given text character by character using CGEvents.
    ///
    /// This is the **primary typing method** — it sends individual keystrokes
    /// at the HID level via `CGEvent`, which is the most universally
    /// compatible approach.  The browser (or any other app) receives these
    /// as real `keydown`/`keyup` JavaScript events, so it works correctly
    /// with:
    ///
    /// - **PVE (Proxmox VE) noVNC** consoles
    /// - **KVM / SPICE** remote desktops
    /// - **Browser-based VNC/RDP** viewers
    /// - **Native macOS** password fields and terminal emulators
    /// - Any application that captures keyboard input
    ///
    /// ### Why NOT clipboard-paste for remote consoles?
    ///
    /// Remote consoles (noVNC, SPICE) run inside a `<canvas>` element that
    /// has no standard text-input handler.  ⌘V paste events are consumed by
    /// the browser but have nowhere to land — noVNC explicitly ignores the
    /// default paste behavior.  Character-by-character HID events, however,
    /// are converted by the browser into JS keyboard events which noVNC
    /// **does** capture and forward to the remote VM.
    ///
    /// ### Prerequisites
    ///
    /// - **Accessibility permission** must be granted (System Settings →
    ///   Privacy & Security → Accessibility).
    /// - The **target application must be frontmost** and its input field
    ///   must have keyboard focus.  Call `activatePreviousFrontmostApp()`
    ///   before invoking this method if your app's window is in the way.
    /// - Must be called from a **background thread** (it uses `Thread.sleep`
    ///   to pace keystrokes).
    ///
    /// - Parameters:
    ///   - text: The text to type.
    ///   - delayBetweenKeys: Delay between each keystroke in seconds.
    ///     The default of 0.05s (50 ms) provides a reliable typing speed.
    ///     Increase for sluggish remote consoles; decrease for fast local apps.
    func simulateTyping(_ text: String, delayBetweenKeys: TimeInterval = 0.05) throws {
        guard checkAccessibilityPermission() else {
            throw ClipboardServiceError.accessibilityNotGranted
        }

        let targetApp = NSWorkspace.shared.frontmostApplication
        let targetName = targetApp?.localizedName ?? "unknown"
        let targetPID = targetApp?.processIdentifier ?? -1
        let hasSrc = Self.sharedEventSource != nil
        print("[ClipboardService] simulateTyping: \(text.count) chars → \(targetName) (pid=\(targetPID)), AXTrusted=\(AXIsProcessTrusted()), eventSource=\(hasSrc ? "ok" : "nil")")

        let bundleId = targetApp?.bundleIdentifier ?? ""
        if bundleId == "com.apple.systempreferences" || bundleId == "com.apple.SystemPreferences" {
            print("[ClipboardService] ⚠️  Target is System Settings — CGEvent keystrokes may not be accepted")
        }

        // ── Switch to US/ABC input source to avoid CJK IME interference ──
        //
        // When a CJK input method is active (e.g. Pinyin, Wubi), it
        // intercepts Shift+digit keystrokes and produces full-width
        // symbols (！＠＃ etc.) instead of the intended ASCII symbols
        // (!@# etc.).  Temporarily switching to a Latin input source
        // ensures CGEvent keystrokes are interpreted as raw US key codes.
        //
        // IMPORTANT: TIS APIs (TISCopyCurrentKeyboardInputSource,
        // TISGetInputSourceProperty, TISSelectInputSource, etc.) MUST be
        // called on the main thread.  HIToolbox enforces this with
        // dispatch_assert_queue and will crash if called from a background
        // queue.  We use DispatchQueue.main.sync to hop to main, which is
        // safe here because simulateTyping runs on a background thread.
        var savedInputSource: TISInputSource?
        var didSwitch = false
        DispatchQueue.main.sync {
            savedInputSource = Self.currentInputSource()
            didSwitch = Self.switchToASCIIInputSource()
        }
        if didSwitch {
            // Give the system a moment to process the input source switch.
            Thread.sleep(forTimeInterval: 0.05)
        }

        defer {
            // Restore original input source after typing.
            if didSwitch, let saved = savedInputSource {
                DispatchQueue.main.sync {
                    Self.restoreInputSource(saved)
                }
            }
        }

        for character in text {
            try typeCharacter(character)
            if delayBetweenKeys > 0 {
                Thread.sleep(forTimeInterval: delayBetweenKeys)
            }
        }

        print("[ClipboardService] simulateTyping: completed \(text.count) chars to \(targetName)")
    }

    /// Simulates typing asynchronously on a background thread and calls the
    /// completion handler on the main queue when finished.
    func simulateTypingAsync(
        _ text: String,
        delayBetweenKeys: TimeInterval = 0.05,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.simulateTyping(text, delayBetweenKeys: delayBetweenKeys)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Clipboard-Paste Typing (⌘V)

    /// Simulates typing by copying text to the clipboard and pressing ⌘V.
    ///
    /// This is an **alternative** to character-by-character typing that works
    /// for standard text fields and some applications.  However, it does
    /// **NOT** work in PVE/noVNC/SPICE consoles because their `<canvas>`
    /// elements have no paste handler.
    ///
    /// The original clipboard content is saved and restored after pasting.
    ///
    /// - Parameters:
    ///   - text: The text to paste.
    ///   - restoreDelay: Seconds to wait before restoring the clipboard.
    func simulateTypingViaPaste(
        _ text: String,
        restoreDelay: TimeInterval = 0.5
    ) throws {
        guard checkAccessibilityPermission() else {
            throw ClipboardServiceError.accessibilityNotGranted
        }

        // 1. Save current clipboard.
        let previousContent = getClipboardContent()

        // 2. Put text on clipboard.
        copyToClipboard(text)
        Thread.sleep(forTimeInterval: 0.05)

        // 3. Simulate ⌘V.
        try simulatePaste()

        // 4. Restore clipboard after delay.
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + restoreDelay
        ) { [weak self] in
            guard let self = self else { return }
            if self.pasteboard.changeCount == self.lastChangeCount {
                if let previous = previousContent {
                    self.copyToClipboard(previous)
                } else {
                    self.clearClipboard()
                }
            }
        }
    }

    // MARK: - Convenience – Decrypt then Type

    /// A combined operation: decrypts a value with `EncryptionService`, then
    /// simulates typing it character-by-character into the frontmost application.
    ///
    /// This is the preferred method for PVE/KVM/noVNC and other remote consoles.
    func typeDecryptedValue(_ encryptedData: Data, delayBetweenKeys: TimeInterval = 0.05) throws {
        let plainText = try EncryptionService.shared.decryptToString(encryptedData)
        try simulateTyping(plainText, delayBetweenKeys: delayBetweenKeys)
    }

    /// Decrypts a value and copies it to the clipboard (auto-clears after `clearAfter` seconds).
    ///
    /// The default retention is **120 seconds** to give users enough time to
    /// switch to the target application and press ⌘V.
    func copyDecryptedValue(_ encryptedData: Data, clearAfter: TimeInterval = 120) throws {
        let plainText = try EncryptionService.shared.decryptToString(encryptedData)
        copyToClipboard(plainText)

        if clearAfter > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) { [weak self] in
                // Only clear if the clipboard still contains the copied value.
                if self?.getClipboardContent() == plainText {
                    self?.clearClipboard()
                }
            }
        }
    }

    // MARK: - Clear

    /// Clears the system pasteboard.
    func clearClipboard() {
        pasteboard.clearContents()
        lastChangeCount = pasteboard.changeCount
        DispatchQueue.main.async { [weak self] in
            self?.lastClipboardContent = ""
        }
    }

    // MARK: - Accessibility

    /// Returns `true` if the app has been granted sufficient permission to
    /// post keyboard events **to other processes**.
    ///
    /// `CGEvent.post(tap: .cghidEventTap)` requires the calling process to
    /// be in the system's **Accessibility** TCC allow-list, which is gated
    /// by `AXIsProcessTrusted()`.
    ///
    /// ### Why NOT IOHIDCheckAccess?
    ///
    /// On macOS 26+ (Tahoe), `IOHIDCheckAccess(kIOHIDRequestTypePostEvent)`
    /// can return `true` even when `AXIsProcessTrusted()` returns `false`.
    /// However, `IOHIDCheckAccess` only governs whether the process can
    /// **create** HID event objects — it does NOT govern whether
    /// `CGEvent.post()` can deliver those events **across process
    /// boundaries** to the frontmost application.  Cross-process event
    /// posting (which is what keyboard simulation requires) still needs
    /// the full Accessibility TCC entry.
    ///
    /// Relying on `IOHIDCheckAccess` as a fallback causes a silent failure:
    /// `checkAccessibilityPermission()` returns `true`, the code skips the
    /// permission prompt, CGEvents are created successfully, but
    /// `CGEvent.post()` silently drops them — nothing gets typed.
    ///
    /// This is a **pure, side-effect-free** check — it never prompts the
    /// user, opens System Settings, or mutates any `@Published` property.
    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Performs a **practical** test of whether `CGEvent.post()` actually
    /// delivers keystrokes, beyond what `AXIsProcessTrusted()` reports.
    ///
    /// `AXIsProcessTrusted()` can return `true` even when the TCC subsystem's
    /// kernel-level posting check still considers the process untrusted
    /// (stale cdhash cached in the kernel from a previous process launch).
    /// In that case, `CGEvent.post()` silently drops the events.
    ///
    /// This method creates a harmless "null" CGEvent (a flagsChanged event
    /// with no flags — no visible effect) and attempts to post it.  If
    /// creation succeeds but posting doesn't crash or error, we can't fully
    /// verify delivery (post() is void), but we CAN verify creation works.
    ///
    /// The real test is combined: `AXIsProcessTrusted() == true` AND
    /// `CGEvent creation works` AND `CGEventSource is valid`.
    ///
    /// Returns `true` if all three conditions hold.  If `false`, the process
    /// likely needs a restart to pick up the newly-granted TCC entry.
    func canActuallyPostEvents() -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let src = Self.sharedEventSource
        // Try creating a test keyboard event
        guard let testEvent = CGEvent(keyboardEventSource: src, virtualKey: 0xFF, keyDown: true) else {
            print("[canActuallyPostEvents] CGEvent creation failed — need restart")
            return false
        }
        // The event was created.  If AXIsProcessTrusted is true and event
        // creation succeeds, posting SHOULD work. But if the kernel has a
        // stale cdhash, it still might not.  Unfortunately there is no API
        // to test this without side effects.
        _ = testEvent  // suppress unused warning
        return src != nil
    }

    /// Checks `IOHIDCheckAccess(kIOHIDRequestTypePostEvent)` using dynamic lookup.
    /// Returns `true` if the system grants HID event posting permission.
    private static func checkIOHIDPostEventAccess() -> Bool {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return false
        }
        defer { dlclose(iokit) }

        guard let sym = dlsym(iokit, "IOHIDCheckAccess") else {
            return false
        }
        typealias IOHIDCheckAccessFn = @convention(c) (Int32) -> Bool
        let fn = unsafeBitCast(sym, to: IOHIDCheckAccessFn.self)
        // kIOHIDRequestTypePostEvent = 1
        return fn(1)
    }

    /// Diagnostic: prints a comprehensive status report about keyboard
    /// simulation readiness.  Useful for troubleshooting "nothing happened"
    /// reports.
    func printDiagnostics() {
        let axTrusted = AXIsProcessTrusted()
        let ioHIDOk = Self.checkIOHIDPostEventAccess()
        let hasSrc = Self.sharedEventSource != nil
        let bundleId = Bundle.main.bundleIdentifier ?? "nil"
        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let macVer = ProcessInfo.processInfo.operatingSystemVersion

        print("""
        ┌──────────────────────────────────────────────────────┐
        │  MacKeyValue – Keyboard Simulation Diagnostics       │
        ├──────────────────────────────────────────────────────┤
        │ macOS version:       \(macVer.majorVersion).\(macVer.minorVersion).\(macVer.patchVersion)
        │ Bundle ID:           \(bundleId)
        │ Is .app bundle:      \(isAppBundle)
        ├──────────────────────────────────────────────────────┤
        │ AXIsProcessTrusted:  \(axTrusted ? "YES ✅" : "NO ❌")  ← Required for CGEvent.post()
        │ IOHIDCheckAccess:    \(ioHIDOk ? "YES" : "NO")      (NOT sufficient alone!)
        │ CGEventSource:       \(hasSrc ? "CREATED ✅" : "NIL ❌")
        ├──────────────────────────────────────────────────────┤
        │ Can simulate typing: \(axTrusted ? "YES ✅" : "NO ❌  ← Grant Accessibility permission!")
        └──────────────────────────────────────────────────────┘
        """)

        if !axTrusted {
            print("[Diagnostics] ⚠️  AXIsProcessTrusted = false")
            print("[Diagnostics]    CGEvent.post() will SILENTLY DROP all keystrokes!")
            if ioHIDOk {
                print("[Diagnostics]    IOHIDCheckAccess=true but AXIsProcessTrusted=false → STALE TCC ENTRY")
                print("[Diagnostics]    The Accessibility toggle shows ON in System Settings, but the code-signing")
                print("[Diagnostics]    hash (cdhash) no longer matches the current binary.")
                print("[Diagnostics]    This happens after every Xcode rebuild or build.sh recompilation.")
                print("[Diagnostics]    Will attempt automatic reset via tccutil…")
            } else {
                print("[Diagnostics]    IOHIDCheckAccess=false — no TCC entry exists at all.")
                print("[Diagnostics]    FIX: System Settings → Privacy & Security → Accessibility")
                print("[Diagnostics]         → Add and enable MacKeyValue")
            }
        } else if !hasSrc {
            print("[Diagnostics] ⚠️  CGEventSource is nil despite AXIsProcessTrusted=true.")
            print("[Diagnostics]    Attempting to reset and re-create…")
            Self.resetEventSource()
            if Self.sharedEventSource != nil {
                print("[Diagnostics] ✅ Successfully re-created CGEventSource!")
            } else {
                print("[Diagnostics] ❌ Still nil — try restarting the app.")
            }
        }
    }

    /// Detects whether the TCC Accessibility entry for this process is **stale**
    /// and attempts to reset it so a fresh grant can succeed.
    ///
    /// ### The "stale TCC" problem
    ///
    /// macOS TCC stores Accessibility permissions keyed by the executable's
    /// **code directory hash** (cdhash).  For ad-hoc signed builds (e.g. from
    /// Xcode or `build.sh`), every recompilation produces a new binary with a
    /// different cdhash.  The old TCC entry still appears enabled in System
    /// Settings (toggle ON), but the system no longer considers it a match for
    /// the current binary → `AXIsProcessTrusted()` returns `false` even though
    /// the user clearly granted permission.
    ///
    /// ### Detection heuristic
    ///
    /// `IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == true` while
    /// `AXIsProcessTrusted() == false` is a strong signal.  IOHIDCheckAccess
    /// can return true when the process has *any* matching TCC entry (even if
    /// the cdhash is stale for the higher-level AX trust check).  Alternatively,
    /// for `.app` bundles with a bundle ID, a stale entry simply means the
    /// bundle ID is in the list but the cdhash doesn't match.
    ///
    /// ### Recovery
    ///
    /// 1. Run `tccutil reset Accessibility [bundleId]` to remove the stale entry.
    /// 2. Call `AXIsProcessTrustedWithOptions(prompt: true)` to trigger a fresh
    ///    system dialog that adds the entry with the correct cdhash.
    ///
    /// - Returns: `true` if a stale entry was detected and reset was attempted.
    func detectAndResetStaleTCCEntry() -> Bool {
        let axTrusted = AXIsProcessTrusted()
        if axTrusted {
            // Already trusted — nothing stale.
            return false
        }

        let ioHIDOk = Self.checkIOHIDPostEventAccess()

        // Heuristic: IOHIDCheckAccess=true but AXIsProcessTrusted=false
        // strongly suggests a stale TCC entry (cdhash mismatch).
        let likelyStale = ioHIDOk

        if !likelyStale {
            print("[TCC] No stale TCC entry detected (IOHIDCheckAccess=false)")
            return false
        }

        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let bundleId = Bundle.main.bundleIdentifier

        print("[TCC] ⚠️  Detected likely STALE TCC entry:")
        print("[TCC]    IOHIDCheckAccess=true but AXIsProcessTrusted=false")
        print("[TCC]    The Accessibility toggle is ON in System Settings but the code-signing")
        print("[TCC]    hash (cdhash) no longer matches the current binary (rebuilt since last grant).")
        print("[TCC]    Resetting the stale entry so a fresh grant can succeed…")

        // Use tccutil to reset the stale entry.
        // For .app bundles with a bundle ID, target the reset precisely.
        // For bare executables, tccutil can only reset ALL entries for the
        // service — there is no path-based reset.  This is acceptable because:
        //   1. The user is a developer doing debug builds — they expect this.
        //   2. The alternative (manual remove + re-add each build) is far worse.
        //   3. Other apps just need to be re-granted once; the user already
        //      knows how to do that.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        if isAppBundle, let bid = bundleId {
            process.arguments = ["reset", "Accessibility", bid]
            print("[TCC] Running: tccutil reset Accessibility \(bid)")
        } else {
            process.arguments = ["reset", "Accessibility"]
            print("[TCC] Running: tccutil reset Accessibility  (all entries — bare executable has no bundle ID)")
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                print("[TCC] ✅ TCC reset successful\(output.isEmpty ? "" : ": \(output)")")
            } else {
                print("[TCC] ⚠️  tccutil exit code \(process.terminationStatus): \(output)")
            }
        } catch {
            print("[TCC] ❌ Failed to run tccutil: \(error.localizedDescription)")
            return false
        }

        // Give TCC database a moment to flush.
        Thread.sleep(forTimeInterval: 0.5)

        // Do NOT auto-trigger AXIsProcessTrustedWithOptions(prompt: true)
        // or open System Settings — let the user decide when to grant
        // via the in-app guide's "打开系统设置" button.

        // Check if the reset immediately resolved it.
        let nowTrusted = AXIsProcessTrusted()
        if nowTrusted {
            print("[TCC] ✅ AXIsProcessTrusted=true after reset — permission auto-granted!")
            DispatchQueue.main.async { [weak self] in
                self?.isAccessibilityGranted = true
                self?.accessibilityGranted.send()
            }
            Self.resetEventSource()
            return true
        }

        print("[TCC] AXIsProcessTrusted still false after reset — user needs to re-grant.")
        print("[TCC] The old stale toggle has been removed from System Settings.")
        print("[TCC] A fresh system prompt should now appear, or the user can add the app manually.")
        return true
    }

    /// Attempts to **automatically grant** Accessibility permission by writing
    /// directly to the TCC database with administrator privileges.
    ///
    /// This shows a **single macOS password dialog** ("MacKeyValue wants to
    /// make changes…").  If the user authenticates, the TCC entry is inserted
    /// and a restart makes it effective — no manual System Settings navigation
    /// is needed.
    ///
    /// ### How it works
    ///
    /// The system TCC database at `/Library/Application Support/com.apple.TCC/TCC.db`
    /// controls Accessibility permissions.  Writing to it requires root.
    /// We use `osascript … with administrator privileges` to execute a
    /// privileged `sqlite3` command that inserts or replaces the entry.
    ///
    /// - Parameter completion: Called on the main thread with `true` if the
    ///   grant succeeded, `false` otherwise.
    func autoGrantAccessibility(completion: @escaping (Bool) -> Void) {
        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let bundleId = Bundle.main.bundleIdentifier ?? ""

        print("[AutoGrant] Starting auto-grant flow (isApp=\(isAppBundle), bundleId=\(bundleId.isEmpty ? "nil" : bundleId))")

        // Trigger the system prompt (works for .app bundles).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(opts)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            Thread.sleep(forTimeInterval: 1.0)

            if AXIsProcessTrusted() {
                print("[AutoGrant] ✅ Permission granted via system dialog!")
                DispatchQueue.main.async { completion(true) }
                return
            }

            // Open Accessibility settings.
            self.openAccessibilitySystemSettings()
            print("[AutoGrant] Opened System Settings → Accessibility")

            // For bare executables, also reveal in Finder.
            if !isAppBundle {
                let execPath = Bundle.main.executablePath
                    ?? ProcessInfo.processInfo.arguments.first ?? ""
                if !execPath.isEmpty {
                    let fileURL = URL(fileURLWithPath: execPath)
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                }
            }

            DispatchQueue.main.async { completion(false) }
        }

        startAccessibilityPolling(timeoutSeconds: 300)
    }

    /// Re-reads the system accessibility trust status and updates the
    /// `@Published isAccessibilityGranted` property if it changed.
    ///
    /// The actual mutation is wrapped in `DispatchQueue.main.async` so it
    /// never fires synchronously inside a SwiftUI view-body evaluation.
    /// Call this from button actions, timer callbacks, etc. — **not** from
    /// within a SwiftUI `body` computation.
    func refreshAccessibilityStatus() {
        let trusted = checkAccessibilityPermission()
        guard trusted != isAccessibilityGranted else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isAccessibilityGranted = trusted
        }
    }

    /// Requests Accessibility permission from the user.
    ///
    /// **Strategy:**
    /// 1. If already granted → return immediately.
    /// 2. Call `AXIsProcessTrustedWithOptions(prompt: true)` — on macOS 26+
    ///    running as a signed `.app` bundle this triggers a **system-managed
    ///    dialog** whose "Open System Settings" button navigates directly to
    ///    the correct Accessibility sub-page.  This is the *only* reliable
    ///    navigation method on macOS 26 Tahoe.
    /// 3. As a fallback (for `swift run`, unsigned builds, or older macOS),
    ///    also open System Settings via URL scheme.
    /// 4. Start a background poll timer that checks `AXIsProcessTrusted()`
    ///    every second for up to 120 seconds.
    func requestAccessibilityPermission() {
        // Fast path: already authorized.
        if checkAccessibilityPermission() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.isAccessibilityGranted {
                    self.isAccessibilityGranted = true
                }
            }
            return
        }

        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let bundleId = Bundle.main.bundleIdentifier
        print("[ClipboardService] Requesting Accessibility permission (isApp=\(isAppBundle), bundleId=\(bundleId ?? "nil"))")

        // Primary method: system prompt dialog via AXIsProcessTrustedWithOptions.
        //
        // When running as a properly signed .app bundle with a valid bundle
        // identifier, this triggers a system dialog:
        //   "MacKeyValue wants to control this computer. Allow?"
        //   → [Deny] [Open System Settings]
        //
        // The "Open System Settings" button in the system dialog:
        //   1. Adds the app to the Accessibility list (with toggle OFF)
        //   2. Navigates directly to Privacy & Security → Accessibility
        //   3. The user just needs to flip the toggle ON
        //
        // When running as a bare executable (swift run), the system can't
        // identify the app so this call may silently do nothing.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(opts)

        // Give the system dialog a moment to appear. It may open System
        // Settings on its own.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            let settingsRunning = !NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .isEmpty

            if settingsRunning {
                print("[ClipboardService] System Settings already opened (likely by system prompt)")
                // The system prompt navigated correctly — just bring it to front.
                self.activateSystemSettings()
            } else {
                // System dialog didn't open System Settings.
                // This typically happens when:
                //   - Running as a bare executable (no bundle identifier)
                //   - The app is not properly signed
                //   - The system swallowed the dialog silently
                print("[ClipboardService] System prompt did not open System Settings, opening manually")
                self.openAccessibilitySystemSettings()
            }
        }

        startAccessibilityPolling()
    }

    /// Opens **System Settings → Privacy & Security → Accessibility**.
    ///
    /// ### macOS version-aware strategy
    ///
    /// - **macOS 13–15** (Ventura / Sonoma / Sequoia): URL scheme with
    ///   `?Privacy_Accessibility` anchor works reliably after a quit-then-
    ///   reopen cycle.
    ///
    /// - **macOS 26+** (Tahoe): The URL anchor parameter is **silently
    ///   ignored** by System Settings — it always lands on the Privacy &
    ///   Security category list.  AppleScript `reveal anchor` **hangs
    ///   indefinitely**.  Therefore on macOS 26+ we open the Privacy &
    ///   Security pane *without* an anchor and rely on the user clicking
    ///   "Accessibility" (guided by our alert text).
    ///
    /// A debounce guard prevents rapid repeated calls.
    func openAccessibilitySystemSettings() {
        // ── Debounce: ignore if already in-flight ────────────────────
        guard !isOpeningAccessibilitySettings else {
            print("[ClipboardService] openAccessibilitySystemSettings() already in-flight, skipping")
            return
        }
        isOpeningAccessibilitySettings = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async { self.isOpeningAccessibilitySettings = false }
            }

            let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

            // ── Phase 1: Force-quit System Settings if running ───────
            // System Settings ignores navigation requests if it's already open,
            // so we must quit it first for a reliable cold-start navigation.
            self.forceQuitSystemSettingsSync()

            if majorVersion >= 26 {
                // ── macOS 26+ Tahoe: URL anchors are silently ignored ──
                //
                // The ONLY reliable approach is AppleScript's `reveal anchor`
                // command using the scripting dictionary (`preferencepane.reveal`
                // access group). This does NOT require Accessibility permission.
                //
                // Two-step process:
                //   1. `reveal pane` → loads the Privacy & Security extension
                //   2. `reveal anchor "Privacy_Accessibility"` → navigates to
                //      the Accessibility sub-page within the pane
                //
                // A sufficient delay between steps is critical because the
                // extension is loaded out-of-process via XPC.
                print("[ClipboardService] macOS \(majorVersion) detected — using AppleScript reveal anchor")

                if self.revealAccessibilityAnchorViaAppleScript() {
                    print("[ClipboardService] AppleScript reveal anchor: navigated to Accessibility ✓")
                } else {
                    // Fallback: try the URL scheme (lands on Privacy & Security
                    // main page — user must click Accessibility manually).
                    print("[ClipboardService] AppleScript reveal failed — falling back to URL scheme")
                    self.openURLViaProcess("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
                    Thread.sleep(forTimeInterval: 2.0)
                }
            } else {
                // ── macOS 13–15: URL anchor parameter works ──────────
                print("[ClipboardService] macOS \(majorVersion) detected — opening with Privacy_Accessibility anchor")
                self.openAccessibilityURLViaProcess()

                Thread.sleep(forTimeInterval: 2.0)

                if !self.isSecurityPrivacyExtensionRunning() {
                    print("[ClipboardService] Extension not detected — retrying…")
                    self.forceQuitSystemSettingsSync()
                    self.openAccessibilityURLViaProcess()
                    Thread.sleep(forTimeInterval: 2.5)
                }

                if self.isSecurityPrivacyExtensionRunning() {
                    print("[ClipboardService] SecurityPrivacyExtension detected ✓")
                }
            }

            // Bring System Settings to front.
            Thread.sleep(forTimeInterval: 0.3)
            self.activateSystemSettings()
        }
    }

    /// Opens **System Settings → Privacy & Security → Input Monitoring**.
    ///
    /// Uses the same macOS-version-aware strategy as
    /// `openAccessibilitySystemSettings()`.
    func openInputMonitoringSystemSettings() {
        let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Force-quit first for reliable navigation.
            self.forceQuitSystemSettingsSync()

            if majorVersion >= 26 {
                // macOS 26+: AppleScript reveal anchor
                let scriptSource = """
                tell application "System Settings"
                    activate
                    delay 1
                    reveal pane id "com.apple.settings.PrivacySecurity.extension"
                    delay 3
                    reveal anchor "Privacy_ListenEvent" of pane id "com.apple.settings.PrivacySecurity.extension"
                    delay 0.5
                    return "OK"
                end tell
                """
                if let script = NSAppleScript(source: scriptSource) {
                    var errorDict: NSDictionary?
                    let result = script.executeAndReturnError(&errorDict)
                    if errorDict == nil, let str = result.stringValue, !str.isEmpty {
                        print("[ClipboardService] AppleScript: navigated to Input Monitoring ✓")
                    } else {
                        print("[ClipboardService] AppleScript Input Monitoring failed, fallback to URL")
                        self.openURLViaProcess("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
                    }
                }
            } else {
                // macOS 13–15: URL anchor works
                let urlCandidates = [
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                ]
                for url in urlCandidates {
                    if self.openURLViaProcess(url) { return }
                }
                self.openURLViaProcess("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
            }

            Thread.sleep(forTimeInterval: 0.3)
            self.activateSystemSettings()
        }
    }

    /// Opens **both** Accessibility and Input Monitoring settings pages
    /// sequentially — first Accessibility, then (after the user has time to
    /// toggle it) Input Monitoring — so the user can grant both permissions
    /// in a single flow.
    ///
    /// After both pages have been opened, the user is expected to enable the
    /// toggles for **MacKeyValue** in each, then restart the application.
    func openAllPermissionSettings() {
        guard !isOpeningAccessibilitySettings else {
            print("[ClipboardService] openAllPermissionSettings() already in-flight, skipping")
            return
        }
        isOpeningAccessibilitySettings = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async { self.isOpeningAccessibilitySettings = false }
            }

            let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

            // Phase 1: Force-quit System Settings for a clean navigation.
            self.forceQuitSystemSettingsSync()

            if majorVersion >= 26 {
                // ── macOS 26+: AppleScript two-anchor reveal ────────
                // Open System Settings once, navigate to Accessibility.
                let scriptSource = """
                tell application "System Settings"
                    activate
                    delay 1
                    reveal pane id "com.apple.settings.PrivacySecurity.extension"
                    delay 3
                    reveal anchor "Privacy_Accessibility" of pane id "com.apple.settings.PrivacySecurity.extension"
                    delay 0.5
                    return "OK"
                end tell
                """
                if let script = NSAppleScript(source: scriptSource) {
                    var errorDict: NSDictionary?
                    let result = script.executeAndReturnError(&errorDict)
                    if errorDict == nil, let str = result.stringValue, !str.isEmpty {
                        print("[ClipboardService] openAllPermissionSettings: navigated to Accessibility ✓")
                    } else {
                        print("[ClipboardService] Accessibility navigation failed, fallback to URL")
                        self.openURLViaProcess("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
                    }
                }
            } else {
                // ── macOS 13–15: URL anchor ─────────────────────────
                self.openAccessibilityURLViaProcess()
                Thread.sleep(forTimeInterval: 2.0)
            }

            // Bring System Settings to front.
            Thread.sleep(forTimeInterval: 0.3)
            self.activateSystemSettings()
        }
    }

    /// Whether an `openAccessibilitySystemSettings` call is currently executing.
    private var isOpeningAccessibilitySettings = false

    // MARK: - Private – System Settings Helpers

    /// Force-quits System Settings **synchronously** and blocks until the
    /// process has exited (or a 5-second timeout elapses).
    ///
    /// Uses `forceTerminate()` rather than `terminate()` because the latter
    /// can be blocked by unsaved-changes dialogs on some macOS versions.
    ///
    /// Must be called from a background queue.
    private func forceQuitSystemSettingsSync() {
        let bundleID = "com.apple.systempreferences"

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else {
            print("[ClipboardService] System Settings not running, opening directly")
            return
        }

        print("[ClipboardService] Force-quitting System Settings before navigation…")

        for app in running {
            app.forceTerminate()
        }

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let still = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if still.allSatisfy({ $0.isTerminated }) || still.isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Extra delay for WindowServer / launchd cleanup.
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Opens a single URL string using `/usr/bin/open`.
    /// Returns `true` if the `open` command exited with status 0.
    @discardableResult
    private func openURLViaProcess(_ urlString: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [urlString]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                print("[ClipboardService] Opened System Settings via: \(urlString)")
                return true
            } else {
                print("[ClipboardService] open exited with status \(process.terminationStatus) for: \(urlString)")
            }
        } catch {
            print("[ClipboardService] Failed to launch open for \(urlString): \(error.localizedDescription)")
        }
        return false
    }

    /// Opens the Accessibility deep-link URL using `/usr/bin/open`.
    ///
    /// Tries multiple URL formats with the `?Privacy_Accessibility` anchor.
    /// Used on macOS 13–15 where anchor navigation works reliably.
    private func openAccessibilityURLViaProcess() {
        let urlCandidates: [String] = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]

        for urlString in urlCandidates {
            if openURLViaProcess(urlString) { return }
        }

        // Last resort: top-level Privacy & Security pane (without anchor).
        print("[ClipboardService] All anchor URLs failed, opening top-level Privacy & Security")
        openURLViaProcess("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
    }

    /// Checks whether the `SecurityPrivacyExtension` XPC process is currently
    /// running.  Its presence is a reliable signal that System Settings has
    /// navigated into the Privacy & Security pane (the extension is only
    /// launched on demand when that pane is displayed).
    private func isSecurityPrivacyExtensionRunning() -> Bool {
        // Use /bin/ps to look for the process by name.  This avoids
        // importing private frameworks or using sysctl directly.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // Read pipe data BEFORE waitUntilExit to avoid deadlock when
            // the pipe buffer fills up (ps output can be large).
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("SecurityPrivacyExtension")
            }
        } catch {
            print("[ClipboardService] Failed to check for SecurityPrivacyExtension: \(error)")
        }
        return false
    }

    /// Brings System Settings to the foreground.
    private func activateSystemSettings() {
        let bundleID = "com.apple.systempreferences"
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        }
    }

    // MARK: - Private – macOS 26 AppleScript Navigation

    /// Uses System Settings' AppleScript scripting dictionary to navigate
    /// directly to **Privacy & Security → Accessibility**.
    ///
    /// This uses the `reveal pane` / `reveal anchor` commands from System
    /// Settings' sdef (`preferencepane.reveal` access group). Unlike GUI
    /// scripting via `System Events`, this approach does **not** require
    /// Accessibility permission — avoiding the chicken-and-egg problem.
    ///
    /// The two-step process is essential on macOS 26:
    ///   1. `reveal pane` loads the Privacy & Security extension (XPC).
    ///   2. After a delay for the extension to initialize, `reveal anchor`
    ///      navigates to the Accessibility sub-page.
    ///
    /// Must be called from a background queue (blocks for ~5–6 seconds).
    ///
    /// - Returns: `true` if the navigation succeeded.
    @discardableResult
    private func revealAccessibilityAnchorViaAppleScript() -> Bool {
        let scriptSource = """
        tell application "System Settings"
            activate
            delay 1
            -- Step 1: Load the Privacy & Security pane (XPC extension).
            reveal pane id "com.apple.settings.PrivacySecurity.extension"
            -- Step 2: Wait for the extension to fully initialize.
            delay 3
            -- Step 3: Navigate to the Accessibility sub-page via anchor.
            reveal anchor "Privacy_Accessibility" of pane id "com.apple.settings.PrivacySecurity.extension"
            delay 0.5
            return "OK"
        end tell
        """

        if let script = NSAppleScript(source: scriptSource) {
            var errorDict: NSDictionary?
            let result = script.executeAndReturnError(&errorDict)
            if errorDict == nil {
                let resultString = result.stringValue ?? ""
                if resultString == "OK" || !resultString.isEmpty {
                    print("[ClipboardService] AppleScript reveal anchor succeeded (result: \(resultString))")
                    return true
                }
            }
            if let error = errorDict {
                print("[ClipboardService] AppleScript reveal anchor error: \(error)")
            }
        }
        return false
    }

    /// Starts polling `AXIsProcessTrusted()` every second for up to 2 minutes.
    ///
    /// As soon as the permission is detected, `isAccessibilityGranted` is flipped
    /// to `true`, `accessibilityGranted` fires, and the timer is cancelled.
    func startAccessibilityPolling(timeoutSeconds: Int = 120) {
        // Cancel any existing poll timer.
        stopAccessibilityPolling()

        var elapsed = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            elapsed += 1

            if self.checkAccessibilityPermission() {
                // Permission was granted!
                //
                // Reset the CGEventSource cache so it gets re-created with
                // the new permission state.  If it was created (and cached
                // as nil) before the user granted permission, it would
                // remain nil forever.
                Self.resetEventSource()

                // Update the published property and fire the one-shot
                // subject.  Both mutations are deferred via async dispatch
                // so they never land inside a SwiftUI body.
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if !self.isAccessibilityGranted {
                        self.isAccessibilityGranted = true
                    }
                    self.accessibilityGranted.send()
                    print("[ClipboardService] Accessibility permission granted after ~\(elapsed)s ✅")
                    print("[ClipboardService] CGEvent keyboard simulation is now available")
                }
                self.stopAccessibilityPolling()
                return
            }

            if elapsed >= timeoutSeconds {
                print("[ClipboardService] Accessibility polling timed out after \(timeoutSeconds)s")
                self.stopAccessibilityPolling()
            }
        }
        timer.resume()
        accessibilityPollTimer = timer
    }

    /// Stops the accessibility permission polling timer.
    func stopAccessibilityPolling() {
        accessibilityPollTimer?.cancel()
        accessibilityPollTimer = nil
    }

    /// Presents a user-friendly alert explaining why Accessibility access is needed
    /// and offers a button to open System Settings directly.
    ///
    /// Call this from the main thread (e.g. from a ViewModel or View action).
    @MainActor
    func showAccessibilityPermissionAlert() {
        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let bundleId = Bundle.main.bundleIdentifier

        // Resolve the on-disk path of the running app or its .app bundle.
        let appPath: String = {
            if let bundlePath = Bundle.main.bundlePath as String?,
               bundlePath.hasSuffix(".app") {
                return bundlePath
            }
            return Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "MacKeyValue"
        }()

        print("[ClipboardService] showAccessibilityPermissionAlert — isApp=\(isAppBundle), bundleId=\(bundleId ?? "nil"), path=\(appPath)")

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Accessibility")

        if isAppBundle && bundleId != nil {
            // ── Running as a proper .app bundle ─────────────────────
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = """
            MacKeyValue 需要「辅助功能」权限才能模拟键盘输入密码。

            点击「请求授权」后：
            1. 系统会弹出授权对话框，点击「打开系统设置」
            2. 系统设置会自动打开「辅助功能」权限页面
            3. 找到「MacKeyValue」并打开开关

            应用标识: \(bundleId!)
            应用路径: \(appPath)

            授权后无需重启应用，权限会自动生效。
            """
            alert.addButton(withTitle: "请求授权")
            alert.addButton(withTitle: "手动打开系统设置")
            alert.addButton(withTitle: "稍后再说")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                requestAccessibilityPermission()
            case .alertSecondButtonReturn:
                openAccessibilitySystemSettings()
                startAccessibilityPolling()
            default:
                break
            }
        } else {
            // ── Running as a bare executable (Xcode SPM / swift run) ─
            //
            // The system's AXIsProcessTrustedWithOptions(prompt:true) may
            // not work because there's no bundle identifier.  We need to:
            //   1. Open System Settings → Accessibility
            //   2. Help the user find the executable to add via "+"
            alert.messageText = "需要辅助功能权限"
            alert.informativeText = """
            MacKeyValue 需要「辅助功能」权限才能模拟键盘输入密码。

            点击「打开设置并定位应用」后：
            1. 系统设置会打开「辅助功能」权限页面
            2. Finder 会定位到当前可执行文件
            3. 点击系统设置中的 "+" 按钮
            4. 将 Finder 中高亮的文件拖入，或直接选择

            可执行文件路径:
            \(appPath)

            💡 建议用 ./build.sh --run 构建 .app 后运行，
               系统可自动识别应用身份，授权更方便。

            授权后无需重启应用，权限会自动生效。
            """
            alert.addButton(withTitle: "打开设置并定位应用")
            alert.addButton(withTitle: "仅打开系统设置")
            alert.addButton(withTitle: "稍后再说")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // Open System Settings AND reveal executable in Finder
                openAccessibilitySystemSettings()
                startAccessibilityPolling()
                // Reveal the executable in Finder so the user can drag it
                // into the "+" dialog.
                let fileURL = URL(fileURLWithPath: appPath)
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            case .alertSecondButtonReturn:
                openAccessibilitySystemSettings()
                startAccessibilityPolling()
            default:
                break
            }
        }
    }

    // MARK: - Private – Polling

    private func pollPasteboard() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let content = pasteboard.string(forType: .string), !content.isEmpty else { return }

        let truncated: String
        if content.count > maxContentLength {
            truncated = String(content.prefix(maxContentLength))
        } else {
            truncated = content
        }

        let contentType = detectContentType(truncated)
        let sourceApp = DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }

        let info = ClipboardChangeInfo(
            content: truncated,
            contentType: contentType,
            sourceApplication: sourceApp,
            timestamp: Date()
        )

        // Publish the change
        DispatchQueue.main.async { [weak self] in
            self?.lastClipboardContent = truncated
            self?.clipboardChanged.send(info)
        }

        // Record to history unless privacy mode is active
        if !isPrivacyMode {
            let item = ClipboardHistoryItem(
                content: truncated,
                contentType: contentType,
                sourceApplication: sourceApp,
                isPrivate: false
            )
            storageService.addClipboardHistoryItem(item)
        }
    }

    // MARK: - Private – Content Type Detection

    private func detectContentType(_ content: String) -> ClipboardHistoryItem.ContentType {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // URL detection
        if let url = URL(string: trimmed),
           let scheme = url.scheme,
           ["http", "https", "ftp", "ssh"].contains(scheme.lowercased()) {
            return .url
        }

        // File path detection
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("file://") {
            let path = trimmed.replacingOccurrences(of: "file://", with: "")
            if FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath) {
                return .filePath
            }
        }

        // Rich text check (contains common HTML/RTF markers)
        if trimmed.hasPrefix("{\\rtf") || trimmed.contains("<html") || trimmed.contains("<div") {
            return .richText
        }

        return .plainText
    }

    // MARK: - Private – Keyboard Simulation Helpers

    /// Returns a CGEventSource for simulated keystrokes.
    ///
    /// Using `.combinedSessionState` means the events are tagged with the
    /// "combined" (hardware + software) session state, which makes the
    /// receiving application treat them the same as real keystrokes.
    ///
    /// **Important**: This is NOT a `static let` because `CGEventSource`
    /// creation can return `nil` when Accessibility permission hasn't been
    /// granted yet.  A `static let` would cache that `nil` forever.
    /// Instead, we cache the source once successfully created, and re-try
    /// creation on every call until it succeeds.
    private static var _cachedEventSource: CGEventSource?
    private static var _eventSourceInitialized = false

    private static var sharedEventSource: CGEventSource? {
        if _eventSourceInitialized {
            return _cachedEventSource
        }
        if let src = CGEventSource(stateID: .combinedSessionState) {
            _cachedEventSource = src
            _eventSourceInitialized = true
            print("[ClipboardService] CGEventSource created successfully ✅")
            return src
        }
        // Don't cache failure — will retry next time after permission is granted
        print("[ClipboardService] CGEventSource creation failed ❌ (Accessibility not yet granted?)")
        return nil
    }

    /// Resets the cached event source so it will be re-created on next use.
    /// Call this after the user grants Accessibility permission.
    static func resetEventSource() {
        _cachedEventSource = nil
        _eventSourceInitialized = false
        print("[ClipboardService] Event source cache reset — will re-create on next use")
    }

    /// Activates the frontmost application that is NOT this process.
    ///
    /// This is a utility method — it does NOT determine where typing goes.
    /// Typing always goes to whatever app has focus at the moment of
    /// `CGEvent.post()`.  Use this only when you explicitly need to bring
    /// a different app to front (e.g., before a countdown).
    @discardableResult
    func activatePreviousFrontmostApp() -> NSRunningApplication? {
        let myPID = ProcessInfo.processInfo.processIdentifier

        if let target = NSWorkspace.shared.runningApplications.first(where: {
            $0.isActive && $0.processIdentifier != myPID
        }) {
            target.activate()
            return target
        }
        // Fallback: iterate all regular apps and pick the first non-self one.
        let orderedApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != myPID }
        if let target = orderedApps.first {
            target.activate()
            return target
        }
        return nil
    }

    /// Types a single character using CGEvent.
    ///
    /// For ASCII characters that have a known macOS virtual key code, we set
    /// the correct `virtualKey` **and** the unicode string.  This is critical
    /// for browser-based applications like noVNC that translate the JS
    /// `event.code` / `event.keyCode` (derived from the HID virtual key
    /// code) into VNC keysyms.
    ///
    /// For characters that require Shift (e.g. uppercase letters, symbols
    /// like `!`, `@`, `#`), we send a full **four-event sequence**:
    ///
    ///   1. Shift keyDown  (flagsChanged event)
    ///   2. Character keyDown  (with `.maskShift` flag + unicode string)
    ///   3. Character keyUp    (with `.maskShift` flag + unicode string)
    ///   4. Shift keyUp    (flagsChanged event)
    ///
    /// This is necessary because web browsers (Chrome, Safari, Firefox)
    /// translate CGEvents into JS `KeyboardEvent` objects and expect to
    /// see explicit modifier key-down / key-up events — merely setting
    /// `.maskShift` in the flags of the character event is not sufficient
    /// for browsers to produce the correct shifted character.
    private func typeCharacter(_ character: Character) throws {
        let str = String(character)
        guard let utf16 = str.utf16.first else {
            throw ClipboardServiceError.typeSimulationFailed("Cannot convert character to UTF-16: \(character)")
        }

        var char = utf16

        let src = Self.sharedEventSource
        if src == nil {
            print("[ClipboardService] ⚠️  CGEventSource is nil — Accessibility permission may not be fully effective yet")
        }

        let (keyCode, needsShift) = Self.virtualKeyCode(for: character)

        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            let msg = "Failed to create CGEvent for '\(character)' (keyCode=\(keyCode)). "
                + "AXIsProcessTrusted()=\(AXIsProcessTrusted()), "
                + "eventSource=\(src == nil ? "nil" : "ok")"
            throw ClipboardServiceError.typeSimulationFailed(msg)
        }

        // Set the unicode string so native macOS apps receive the
        // intended character directly.
        keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
        keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)

        if needsShift {
            // ── Full Shift sequence for browser/web compatibility ──
            //
            // Step 1: Shift keyDown (flagsChanged)
            let shiftKeyCode: CGKeyCode = 56  // kVK_Shift
            if let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: shiftKeyCode, keyDown: true) {
                shiftDown.flags = CGEventFlags(rawValue: shiftDown.flags.rawValue | CGEventFlags.maskShift.rawValue)
                shiftDown.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.005)
            }

            // Step 2: Character keyDown (with Shift flag)
            keyDown.flags = CGEventFlags(rawValue: keyDown.flags.rawValue | CGEventFlags.maskShift.rawValue)
            keyDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)

            // Step 3: Character keyUp (with Shift flag)
            keyUp.flags = CGEventFlags(rawValue: keyUp.flags.rawValue | CGEventFlags.maskShift.rawValue)
            keyUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.005)

            // Step 4: Shift keyUp (flagsChanged)
            if let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: shiftKeyCode, keyDown: false) {
                shiftUp.flags = []  // No modifiers — Shift is released
                shiftUp.post(tap: .cghidEventTap)
            }
        } else {
            // ── Simple key press (no modifier) ──
            keyDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Input Source Management

    /// Returns the current input source as an opaque reference.
    private static func currentInputSource() -> TISInputSource? {
        return TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
    }

    /// Switches to an ASCII-capable input source (US, ABC, or similar).
    /// Returns `true` if a switch was performed.
    private static func switchToASCIIInputSource() -> Bool {
        // Check if the current input source is already ASCII-capable.
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            if let idRef = TISGetInputSourceProperty(current, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
                // Common ASCII input source IDs
                if id.contains("ABC") || id.contains("US") || id.contains("British")
                    || id.contains("Australian") || id.contains("Canadian")
                    || id == "com.apple.keylayout.USInternational-PC" {
                    return false  // Already ASCII — no switch needed.
                }
            }
        }

        // Find an ASCII-capable input source to switch to.
        let criteria: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsASCIICapable: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let sources = TISCreateInputSourceList(criteria as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              !sources.isEmpty else {
            print("[InputSource] No ASCII-capable input source found")
            return false
        }

        // Prefer "ABC" or "US" layout.
        let preferred = sources.first { source in
            guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            let id = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
            return id.contains("ABC") || id.contains("US")
        } ?? sources[0]

        let status = TISSelectInputSource(preferred)
        if status == noErr {
            if let idRef = TISGetInputSourceProperty(preferred, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
                print("[InputSource] Switched to ASCII input source: \(id)")
            }
            return true
        } else {
            print("[InputSource] ⚠️  Failed to switch input source (status=\(status))")
            return false
        }
    }

    /// Restores a previously saved input source.
    private static func restoreInputSource(_ source: TISInputSource) {
        let status = TISSelectInputSource(source)
        if status == noErr {
            if let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
                print("[InputSource] Restored input source: \(id)")
            }
        } else {
            print("[InputSource] ⚠️  Failed to restore input source (status=\(status))")
        }
    }

    // MARK: - Virtual Key Code Mapping (US ANSI Layout)

    /// Returns the macOS virtual key code for a given character, along with
    /// whether the Shift modifier is required.
    ///
    /// This mapping covers the US ANSI keyboard layout, which is also the
    /// layout used by VNC keysym translation in noVNC and most VNC clients.
    /// Characters not in the map get `keyCode = 0` as a fallback (the
    /// unicode string on the CGEvent will still deliver the correct character
    /// to native macOS apps).
    private static func virtualKeyCode(for character: Character) -> (CGKeyCode, Bool) {
        // US ANSI virtual key codes (from Events.h / Carbon HIToolbox)
        //
        // Map: character → (virtualKeyCode, needsShift)
        //
        // Lower-case letters
        switch character {
        case "a": return (0x00, false)
        case "s": return (0x01, false)
        case "d": return (0x02, false)
        case "f": return (0x03, false)
        case "h": return (0x04, false)
        case "g": return (0x05, false)
        case "z": return (0x06, false)
        case "x": return (0x07, false)
        case "c": return (0x08, false)
        case "v": return (0x09, false)
        case "b": return (0x0B, false)
        case "q": return (0x0C, false)
        case "w": return (0x0D, false)
        case "e": return (0x0E, false)
        case "r": return (0x0F, false)
        case "y": return (0x10, false)
        case "t": return (0x11, false)
        case "1": return (0x12, false)
        case "2": return (0x13, false)
        case "3": return (0x14, false)
        case "4": return (0x15, false)
        case "6": return (0x16, false)
        case "5": return (0x17, false)
        case "=": return (0x18, false)
        case "9": return (0x19, false)
        case "7": return (0x1A, false)
        case "-": return (0x1B, false)
        case "8": return (0x1C, false)
        case "0": return (0x1D, false)
        case "]": return (0x1E, false)
        case "o": return (0x1F, false)
        case "u": return (0x20, false)
        case "[": return (0x21, false)
        case "i": return (0x22, false)
        case "p": return (0x23, false)
        case "l": return (0x25, false)
        case "j": return (0x26, false)
        case "'": return (0x27, false)
        case "k": return (0x28, false)
        case ";": return (0x29, false)
        case "\\": return (0x2A, false)
        case ",": return (0x2B, false)
        case "/": return (0x2C, false)
        case "n": return (0x2D, false)
        case "m": return (0x2E, false)
        case ".": return (0x2F, false)
        case "`": return (0x32, false)
        case " ": return (0x31, false)
        // Return / Tab / Escape / Delete
        case "\n": return (0x24, false)
        case "\r": return (0x24, false)
        case "\t": return (0x30, false)

        // Upper-case letters (same key code, Shift required)
        case "A": return (0x00, true)
        case "S": return (0x01, true)
        case "D": return (0x02, true)
        case "F": return (0x03, true)
        case "H": return (0x04, true)
        case "G": return (0x05, true)
        case "Z": return (0x06, true)
        case "X": return (0x07, true)
        case "C": return (0x08, true)
        case "V": return (0x09, true)
        case "B": return (0x0B, true)
        case "Q": return (0x0C, true)
        case "W": return (0x0D, true)
        case "E": return (0x0E, true)
        case "R": return (0x0F, true)
        case "Y": return (0x10, true)
        case "T": return (0x11, true)
        case "O": return (0x1F, true)
        case "U": return (0x20, true)
        case "I": return (0x22, true)
        case "P": return (0x23, true)
        case "L": return (0x25, true)
        case "J": return (0x26, true)
        case "K": return (0x28, true)
        case "N": return (0x2D, true)
        case "M": return (0x2E, true)

        // Shifted number row symbols
        case "!": return (0x12, true)  // Shift+1
        case "@": return (0x13, true)  // Shift+2
        case "#": return (0x14, true)  // Shift+3
        case "$": return (0x15, true)  // Shift+4
        case "^": return (0x16, true)  // Shift+6
        case "%": return (0x17, true)  // Shift+5
        case "+": return (0x18, true)  // Shift+=
        case "(": return (0x19, true)  // Shift+9
        case "&": return (0x1A, true)  // Shift+7
        case "_": return (0x1B, true)  // Shift+-
        case "*": return (0x1C, true)  // Shift+8
        case ")": return (0x1D, true)  // Shift+0

        // Shifted punctuation
        case "}": return (0x1E, true)  // Shift+]
        case "{": return (0x21, true)  // Shift+[
        case "\"": return (0x27, true) // Shift+'
        case ":": return (0x29, true)  // Shift+;
        case "|": return (0x2A, true)  // Shift+\
        case "<": return (0x2B, true)  // Shift+,
        case "?": return (0x2C, true)  // Shift+/
        case ">": return (0x2F, true)  // Shift+.
        case "~": return (0x32, true)  // Shift+`

        default:
            // Unknown character — use keyCode 0 and rely on the unicode
            // string for native app delivery.  noVNC may not handle these
            // correctly, but most macOS apps will.
            return (0, false)
        }
    }
}
