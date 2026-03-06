import SwiftUI

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by AppDelegate when it detects that Accessibility permission
    /// is needed and the in-app animated guide should be displayed.
    static let showAccessibilityGuide = Notification.Name("com.mackeyvalue.showAccessibilityGuide")
}

// MARK: - App Entry Point

@main
struct MacKeyValueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        // Main Window
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .task {
                    await viewModel.bootstrap()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(
            width: viewModel.uiMode == .compact ? 420 : 1000,
            height: viewModel.uiMode == .compact ? 520 : 650
        )
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("新建条目") {
                    viewModel.prepareNewEntry()
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("导入...") {
                    importEntries()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("导出...") {
                    exportEntries()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            // Edit menu additions
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("剪贴板历史") {
                    viewModel.activeSheet = .clipboardHistory
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Button("清除剪贴板") {
                    viewModel.clearClipboard()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            // View menu additions
            CommandGroup(after: .sidebar) {
                Divider()

                Button("快速搜索") {
                    viewModel.activeSheet = .quickSearch
                }
                .keyboardShortcut(" ", modifiers: [.command, .option])

                Divider()

                Button {
                    viewModel.toggleUIMode()
                } label: {
                    Text(viewModel.uiMode == .compact ? "切换到管理模式" : "切换到精简模式")
                }
                .keyboardShortcut("1", modifiers: [.command])

                Divider()

                Menu("排序方式") {
                    ForEach(EntrySortOrder.allCases) { order in
                        Button {
                            viewModel.filterState.sortOrder = order
                        } label: {
                            HStack {
                                Text(order.displayName)
                                if viewModel.filterState.sortOrder == order {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Menu("筛选分类") {
                    Button("全部") {
                        viewModel.filterState.selectedCategory = nil
                    }
                    Divider()
                    ForEach(KeyValueEntry.Category.allCases) { category in
                        Button(category.displayName) {
                            viewModel.filterState.selectedCategory = category
                        }
                    }
                }

                Toggle("仅显示收藏", isOn: $viewModel.filterState.showFavoritesOnly)
                Toggle("仅显示私密", isOn: $viewModel.filterState.showPrivateOnly)
            }

            // Custom "Security" menu
            CommandMenu("安全") {
                Toggle("隐私模式", isOn: $viewModel.isPrivacyMode)
                    .keyboardShortcut("p", modifiers: [.command, .shift, .option])

                Divider()

                Button("同步到 Gist") {
                    Task { await viewModel.performGistSync() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(viewModel.isSyncing)

                Button("Gist 同步设置...") {
                    viewModel.activeSheet = .gistSync
                }

                Divider()

                Button("快捷键设置...") {
                    viewModel.activeSheet = .hotkeySettings
                }
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Button("关于 MacKeyValue") {
                    viewModel.activeSheet = .about
                }
            }

            // Settings command (⌘,)
            CommandGroup(replacing: .appSettings) {
                Button("设置...") {
                    viewModel.activeSheet = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        // Menu Bar Extra (status bar icon)
        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
        } label: {
            Image(systemName: "key.viewfinder")
        }
        .menuBarExtraStyle(.menu)
    }

    // MARK: - Import / Export Helpers

    private func importEntries() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要导入的 JSON 文件"
        panel.prompt = "导入"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.importEntries(from: url, overwriteExisting: false)
        }
    }

    private func exportEntries() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "mackeyvalue_export.json"
        panel.message = "选择导出位置"
        panel.prompt = "导出"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.exportEntries(to: url, includePrivate: false)
        }
    }
}

// MARK: - MenuBarView

struct MenuBarView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        // Quick access to favorite entries
        if !viewModel.favoriteEntries.isEmpty {
            Section("收藏") {
                ForEach(viewModel.favoriteEntries.prefix(10)) { entry in
                    Button {
                        viewModel.copyEntryValue(id: entry.id)
                    } label: {
                        HStack {
                            Image(systemName: entry.category.iconName)
                            Text(entry.title)
                            Spacer()
                            Text("复制")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()
        }

        // Privacy mode toggle
        Button {
            viewModel.isPrivacyMode.toggle()
        } label: {
            HStack {
                Image(systemName: viewModel.isPrivacyMode ? "eye.slash.fill" : "eye")
                Text(viewModel.isPrivacyMode ? "关闭隐私模式" : "开启隐私模式")
            }
        }

        // Clear clipboard
        Button {
            viewModel.clearClipboard()
        } label: {
            HStack {
                Image(systemName: "xmark.circle")
                Text("清除剪贴板")
            }
        }

        Divider()

        // Sync
        Button {
            Task { await viewModel.performGistSync() }
        } label: {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("同步 Gist")
            }
        }
        .disabled(viewModel.isSyncing || !viewModel.gistSyncService.hasToken)

        Divider()

        // Show main window
        Button {
            viewModel.activateApp()
        } label: {
            HStack {
                Image(systemName: "macwindow")
                Text("打开主窗口")
            }
        }

        // Mode toggle
        Button {
            viewModel.toggleUIMode()
            viewModel.activateApp()
        } label: {
            HStack {
                Image(systemName: viewModel.uiMode == .compact
                      ? "rectangle.expand.vertical"
                      : "rectangle.compress.vertical")
                Text(viewModel.uiMode == .compact ? "管理模式" : "精简模式")
            }
        }

        // Settings
        Button {
            viewModel.activateApp()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                viewModel.activeSheet = .settings
            }
        } label: {
            HStack {
                Image(systemName: "gear")
                Text("设置")
            }
        }

        Divider()

        // Status info
        Section {
            Text("共 \(viewModel.totalEntryCount) 条记录")
                .font(.caption)
            if viewModel.isPrivacyMode {
                Label("隐私模式已开启", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        Divider()

        // About / Donate
        Button {
            viewModel.activateApp()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                viewModel.activeSheet = .about
            }
        } label: {
            HStack {
                Image(systemName: "info.circle")
                Text("关于 / ☕ 请喝咖啡")
            }
        }

        // Quit
        Button("退出 KeyValue") {
            viewModel.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the activation policy to regular (shows in Dock)
        NSApplication.shared.setActivationPolicy(.regular)

        // Set the app icon at runtime so it displays correctly even when
        // running as a bare executable (swift run / Xcode SPM).  The .app
        // bundle normally picks it up from Info.plist → CFBundleIconFile,
        // but bare executables have no bundle resources.
        setApplicationIcon()

        // ── Accessibility Permission – Proactive Check & Request ──
        //
        // CGEvent.post(tap: .cghidEventTap) REQUIRES the app to be in the
        // system's Accessibility allow-list (TCC kTCCServiceAccessibility).
        // Without this permission, posted CGEvents are silently dropped by
        // the system — no error is returned, the events simply vanish.
        //
        // For ad-hoc signed builds, macOS stores the TCC permission keyed
        // by (bundleId, codeSignHash).  Every rebuild changes the code
        // signature → the old TCC entry is invalidated.  We proactively
        // detect this and guide the user through re-granting.
        let clipboardService = ClipboardService.shared

        // Print full diagnostics on startup for troubleshooting.
        clipboardService.printDiagnostics()

        // ── Stale TCC detection & auto-reset ──
        //
        // When running ad-hoc signed builds (Xcode, build.sh), every rebuild
        // produces a new code-signing hash.  The old Accessibility TCC entry
        // becomes stale: the toggle appears ON in System Settings, but
        // AXIsProcessTrusted() returns false.  Detect this and auto-reset
        // so the user gets a clean prompt instead of a confusing mismatch.
        let didResetStale = clipboardService.detectAndResetStaleTCCEntry()
        if didResetStale {
            print("[AppDelegate] Stale TCC entry was reset — re-checking accessibility…")
        }

        let granted = clipboardService.checkAccessibilityPermission()
        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let bundleId = Bundle.main.bundleIdentifier

        if !granted {
            print("[AppDelegate] ⚠️  Accessibility not granted")

            // Start polling so we detect when the user grants permission.
            clipboardService.startAccessibilityPolling(timeoutSeconds: 300)

            if !isAppBundle || bundleId == nil {
                let execPath = Bundle.main.executablePath
                    ?? ProcessInfo.processInfo.arguments.first ?? "MacKeyValue"
                print("[AppDelegate] Running as bare executable: \(execPath)")
                print("[AppDelegate] 💡 Tip: use ./build.sh --run  for .app bundle")
            }

            // Show the auto-grant overlay after a brief delay so the main
            // window has time to appear.  The overlay's primary action is
            // "一键授权" which writes to TCC.db via admin password dialog,
            // then auto-restarts.  No manual System Settings needed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !clipboardService.checkAccessibilityPermission() {
                    NotificationCenter.default.post(
                        name: .showAccessibilityGuide,
                        object: nil
                    )
                }
            }
        } else {
            print("[AppDelegate] ✅ Accessibility permission granted — keyboard simulation is available")
        }

        print("[AppDelegate] MacKeyValue launched successfully")
    }

    /// Sets the application icon for the Dock, window title bar, etc.
    ///
    /// When running as a .app bundle, macOS reads `CFBundleIconFile` from
    /// Info.plist and sets the icon automatically — we only need to handle
    /// the case where we're running as a bare executable (swift run / Xcode SPM).
    ///
    /// Search order:
    /// 1. `CFBundleIconFile` already loaded by the system (.app bundle) — skip
    /// 2. Bundle resources via `image(forResource:)` or direct `.icns` in bundle
    /// 3. `.icns` / `.png` in the source tree (relative to executable or CWD)
    /// 4. Programmatic fallback with "MK" text
    private func setApplicationIcon() {
        // ── 1. Check if the system already loaded the icon from the bundle ──
        // In a properly signed .app, the system reads CFBundleIconFile from
        // Info.plist and sets the Dock icon before applicationDidFinishLaunching
        // is called.  Detect this by checking if the bundle has the .icns file.
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            // We're in a .app bundle. Try to load the icon explicitly to set it
            // on NSApplication (needed for the window title bar and other places).
            let icnsInBundle = (bundlePath as NSString)
                .appendingPathComponent("Contents/Resources/AppIcon.icns")
            if FileManager.default.fileExists(atPath: icnsInBundle),
               let image = NSImage(contentsOfFile: icnsInBundle) {
                NSApplication.shared.applicationIconImage = image
                print("[AppDelegate] Icon loaded from .app bundle: \(icnsInBundle)")
                return
            }
            // Also try via Bundle API (works with asset catalogs)
            if let bundleIcon = Bundle.main.image(forResource: "AppIcon") {
                NSApplication.shared.applicationIconImage = bundleIcon
                print("[AppDelegate] Icon loaded from bundle resources (asset catalog)")
                return
            }
        }

        // ── 2. Bare executable — search for icon files in the source tree ──
        let execPath = Bundle.main.executablePath
            ?? ProcessInfo.processInfo.arguments.first ?? ""
        let execDir = URL(fileURLWithPath: execPath).deletingLastPathComponent()

        let candidatePaths: [String] = [
            // .build/debug/ or .build/release/ → ../../Resources/
            execDir.appendingPathComponent("../../Resources/AppIcon.icns").path,
            execDir.appendingPathComponent("../../../Resources/AppIcon.icns").path,
            execDir.appendingPathComponent("../../MacKeyValue/Resources/AppIcon.icns").path,
            // Relative to CWD
            "MacKeyValue/Resources/AppIcon.icns",
            "Resources/AppIcon.icns",
            // PNG fallback
            execDir.appendingPathComponent("../../Resources/AppIcon.appiconset/icon_512x512@2x.png").path,
            "MacKeyValue/Resources/AppIcon.appiconset/icon_512x512@2x.png",
            "Resources/AppIcon.appiconset/icon_512x512@2x.png",
        ]

        for path in candidatePaths {
            let resolved = (path as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved),
               let image = NSImage(contentsOfFile: resolved) {
                NSApplication.shared.applicationIconImage = image
                print("[AppDelegate] Icon loaded from source tree: \(resolved)")
                return
            }
        }

        // ── 3. Fallback: generate a programmatic icon ──
        //
        // Theme: Key-Value + Encryption — a key icon with curly braces
        // representing the JSON/dict nature of key-value pairs, and a
        // lock overlay symbolising encryption.
        print("[AppDelegate] No icon file found — generating fallback icon")
        let size: CGFloat = 512
        let icon = NSImage(size: NSSize(width: size, height: size))
        icon.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            // ── White rounded-rect background ──
            let inset: CGFloat = 4
            let cornerRadius = size * 0.22
            let rect = CGRect(x: inset, y: inset,
                              width: size - inset * 2, height: size - inset * 2)
            let bgPath = CGPath(roundedRect: rect,
                                cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                                transform: nil)

            // White gradient background
            let bgColors = [
                CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
                CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1.0),
            ]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: bgColors as CFArray,
                locations: [0, 1]
            )!
            ctx.saveGState()
            ctx.addPath(bgPath)
            ctx.clip()
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: size / 2, y: size),
                                   end: CGPoint(x: size / 2, y: 0),
                                   options: [])
            ctx.restoreGState()

            // ── Subtle border ──
            ctx.saveGState()
            ctx.addPath(bgPath)
            ctx.setStrokeColor(CGColor(red: 0.75, green: 0.76, blue: 0.80, alpha: 0.40))
            ctx.setLineWidth(2)
            ctx.strokePath()
            ctx.restoreGState()

            // ── "K" letter (left) ──
            let letterColor = NSColor(red: 0.20, green: 0.24, blue: 0.35, alpha: 1.0)
            let kAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Georgia-Bold", size: size * 0.32) ?? NSFont.systemFont(ofSize: size * 0.32, weight: .bold),
                .foregroundColor: letterColor,
            ]
            let kText = "K" as NSString
            let kSize = kText.size(withAttributes: kAttrs)
            kText.draw(at: CGPoint(
                x: size * 0.12,
                y: (size - kSize.height) / 2
            ), withAttributes: kAttrs)

            // ── Lock icon (centre) ──
            let lockAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.22, weight: .regular),
                .foregroundColor: NSColor(red: 0.22, green: 0.27, blue: 0.38, alpha: 1.0),
            ]
            let lockText = "🔒" as NSString
            let lockSize = lockText.size(withAttributes: lockAttrs)
            lockText.draw(at: CGPoint(
                x: (size - lockSize.width) / 2,
                y: (size - lockSize.height) / 2
            ), withAttributes: lockAttrs)

            // ── "V" letter (right) ──
            let vAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Georgia-Bold", size: size * 0.32) ?? NSFont.systemFont(ofSize: size * 0.32, weight: .bold),
                .foregroundColor: letterColor,
            ]
            let vText = "V" as NSString
            let vSize = vText.size(withAttributes: vAttrs)
            vText.draw(at: CGPoint(
                x: size * 0.88 - vSize.width,
                y: (size - vSize.height) / 2
            ), withAttributes: vAttrs)

            // ── "KeyValue" label below ──
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.065, weight: .light),
                .foregroundColor: NSColor(red: 0.35, green: 0.38, blue: 0.48, alpha: 0.75),
                .kern: size * 0.012,
            ]
            let nameText = "KeyValue" as NSString
            let nameSize = nameText.size(withAttributes: nameAttrs)
            nameText.draw(at: CGPoint(
                x: (size - nameSize.width) / 2,
                y: size * 0.16
            ), withAttributes: nameAttrs)
        }
        icon.unlockFocus()
        NSApplication.shared.applicationIconImage = icon
        print("[AppDelegate] Fallback icon generated (K🔒V symmetric white theme)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the accessibility polling timer to avoid dangling references.
        ClipboardService.shared.stopAccessibilityPolling()

        // Ensure all data is saved and services are torn down cleanly.
        StorageService.shared.teardown()
        HotkeyService.shared.stop()
        ClipboardService.shared.stopMonitoring()
        GistSyncService.shared.stopAutoSync()

        print("[AppDelegate] MacKeyValue terminated")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar even when all windows are closed
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-show the main window when the user clicks the dock icon
        if !flag {
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(self)
                    break
                }
            }
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
