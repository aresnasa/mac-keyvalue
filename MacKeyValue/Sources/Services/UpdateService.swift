import AppKit
import Combine
import Foundation

// MARK: - GitHub API Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let name: String
    let body: String?
    let publishedAt: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case name, body, assets
        case publishedAt = "published_at"
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let size: Int
    let contentType: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case contentType = "content_type"
    }
}

// MARK: - UpdateService

/// Checks for app updates via GitHub Releases API and performs the update
/// using the method appropriate for the detected installation type:
///   • Homebrew cask  → `brew upgrade --cask keyvalue`  + auto-restart
///   • Git source     → `git pull`  (offers rebuild command)
///   • DMG / .app     → **auto-download DMG → mount → replace .app → relaunch**
///   • Unknown        → opens GitHub Releases page in the browser
final class UpdateService: ObservableObject {

    static let shared = UpdateService()

    // MARK: - Nested Types

    enum InstallMethod: Equatable {
        case homebrew(brewPath: String)
        case sourceTree(repoPath: String)
        case appBundle
        case unknown

        var displayName: String {
            switch self {
            case .homebrew: return "Homebrew"
            case .sourceTree: return "源码构建"
            case .appBundle: return "DMG 安装"
            case .unknown: return "未知"
            }
        }
        var icon: String {
            switch self {
            case .homebrew: return "shippingbox.fill"
            case .sourceTree: return "chevron.left.forwardslash.chevron.right"
            case .appBundle: return "arrow.down.app.fill"
            case .unknown: return "questionmark.app.fill"
            }
        }
        var canAutoUpdate: Bool { true }
    }

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: String)
        case downloading(version: String, progress: Double)  // 0.0 … 1.0
        case installing(version: String)
        case updating  // brew / git
        case success(version: String)
        case failed(String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }
        var isChecking: Bool { self == .checking }
        var isUpdating: Bool {
            switch self {
            case .updating, .downloading, .installing: return true
            default: return false
            }
        }
        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        var availableVersion: String? {
            if case .available(let v, _) = self { return v }
            return nil
        }
        var releaseURL: String? {
            if case .available(_, let u) = self { return u }
            return nil
        }
        var downloadProgress: Double? {
            if case .downloading(_, let p) = self { return p }
            return nil
        }
    }

    // MARK: - Published State

    @Published var state: UpdateState = .idle
    @Published var installMethod: InstallMethod = .unknown
    @Published var lastChecked: Date?

    // MARK: - Constants

    private let repoOwner = "aresnasa"
    private let repoName = "mac-keyvalue"
    private let appName = "KeyValue"
    private let checkIntervalSeconds: TimeInterval = 86_400  // 24 h
    private let lastCheckedKey = "com.aresnasa.mackeyvalue.updateLastChecked"

    // MARK: - Private Properties

    /// Keeps a reference to the active download task so it can be cancelled.
    private var downloadTask: URLSessionDownloadTask?

    /// Delegate that forwards progress updates to the service.
    private var downloadDelegate: DownloadDelegate?

    /// The latest release info (kept around between check & perform).
    private var latestRelease: GitHubRelease?

    // MARK: - Init

    private init() {
        lastChecked = UserDefaults.standard.object(forKey: lastCheckedKey) as? Date
        installMethod = detectInstallMethod()
    }

    // MARK: - Public API

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var shouldCheckNow: Bool {
        guard let last = lastChecked else { return true }
        return Date().timeIntervalSince(last) >= checkIntervalSeconds
    }

    @MainActor
    func checkForUpdates(force: Bool = false) async {
        guard force || shouldCheckNow else { return }
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            latestRelease = release
            let latest = release.tagName.trimmingCharacters(in: .init(charactersIn: "vV"))
            saveLastChecked()
            if isNewer(latest, than: currentVersion) {
                state = .available(version: latest, url: release.htmlURL)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed("检查失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    func performUpdate() async {
        guard case .available(let version, let url) = state else { return }
        switch installMethod {
        case .homebrew(let brewPath):
            await upgradeViaBrew(brewPath: brewPath, expectedVersion: version)
        case .sourceTree(let repoPath):
            await pullViaGit(repoPath: repoPath)
        case .appBundle, .unknown:
            await downloadAndInstall(version: version, fallbackURL: url)
        }
    }

    /// Cancel an in-progress DMG download.
    @MainActor
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadDelegate = nil
        state = .idle
    }

    func refreshInstallMethod() {
        installMethod = detectInstallMethod()
    }

    // MARK: - Install-Method Detection

    private func detectInstallMethod() -> InstallMethod {
        // 1. Homebrew Caskroom
        let cellarRoots = ["/opt/homebrew", "/usr/local", "/home/linuxbrew/.linuxbrew"]
        for root in cellarRoots {
            if FileManager.default.fileExists(atPath: "\(root)/Caskroom/keyvalue") {
                return .homebrew(brewPath: "\(root)/bin/brew")
            }
        }
        // 2. Source tree: walk up looking for .git
        if let execPath = Bundle.main.executablePath {
            var dir = URL(fileURLWithPath: execPath)
            for _ in 0..<8 {
                dir = dir.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                    return .sourceTree(repoPath: dir.path)
                }
            }
        }
        // 3. App bundle
        if Bundle.main.bundlePath.hasSuffix(".app") {
            return .appBundle
        }
        return .unknown
    }

    // MARK: - DMG Auto-Download & Install

    /// Full auto-update flow for `.appBundle` installs:
    ///   1. Find a DMG asset matching the current architecture.
    ///   2. Download it with real-time progress reporting.
    ///   3. Mount the DMG.
    ///   4. Locate the .app inside.
    ///   5. Replace the running .app (quarantine-stripped).
    ///   6. Unmount the DMG + cleanup.
    ///   7. Relaunch.
    @MainActor
    private func downloadAndInstall(version: String, fallbackURL: String) async {
        // ── 1. Resolve DMG download URL ──────────────────────────────────
        guard let dmgURL = resolveDMGAssetURL() else {
            state = .failed("该版本未找到适用于当前架构的 DMG 安装包，请前往 GitHub Releases 手动下载：\n\(fallbackURL)")
            return
        }

        // ── 2. Download ─────────────────────────────────────────────────
        state = .downloading(version: version, progress: 0)

        let tmpDMGURL: URL
        do {
            tmpDMGURL = try await downloadDMG(from: dmgURL, version: version)
        } catch {
            if (error as NSError).code == NSURLErrorCancelled { return }
            state = .failed("下载失败：\(error.localizedDescription)")
            return
        }

        defer { try? FileManager.default.removeItem(at: tmpDMGURL) }

        // ── 3-6. Mount → replace → unmount ──────────────────────────────
        state = .installing(version: version)

        do {
            let mountPoint = try await mountDMG(at: tmpDMGURL)
            defer { unmountDMG(mountPoint: mountPoint) }

            guard let appInDMG = findAppBundle(in: mountPoint) else {
                state = .failed("在 DMG 中未找到 \(appName).app")
                return
            }

            try replaceCurrentApp(with: appInDMG)
        } catch {
            state = .failed("安装失败：\(error.localizedDescription)")
            return
        }

        // ── 7. Relaunch ─────────────────────────────────────────────────
        state = .success(version: version)
        // Brief pause so the user can see the success message.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        relaunchApp()
    }

    /// Picks the DMG asset whose filename matches the current CPU architecture.
    /// The release script produces names like `KeyValue-1.2.0-apple-silicon.dmg`
    /// and `KeyValue-1.2.0-intel.dmg`.
    private func resolveDMGAssetURL() -> URL? {
        guard let release = latestRelease else { return nil }
        let arch: String = {
            #if arch(arm64)
                return "apple-silicon"
            #else
                return "intel"
            #endif
        }()

        // Prefer the arch-specific DMG; fall back to any .dmg in the release.
        let dmgAssets = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let best =
            dmgAssets.first(where: { $0.name.contains(arch) })
            ?? dmgAssets.first
        guard let asset = best else { return nil }
        return URL(string: asset.browserDownloadURL)
    }

    // MARK: - Download with Progress

    /// Downloads the DMG to a temporary file, reporting progress through
    /// `state = .downloading(…)`.
    private func downloadDMG(from url: URL, version: String) async throws -> URL {
        return try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else {
                cont.resume(throwing: URLError(.cancelled))
                return
            }

            let delegate = DownloadDelegate(
                onProgress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.state = .downloading(version: version, progress: fraction)
                    }
                },
                onComplete: { localURL, response, error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    guard let localURL else {
                        cont.resume(throwing: URLError(.cannotCreateFile))
                        return
                    }
                    // Move from the temporary download location to a stable temp file
                    // because URLSession deletes the file after the delegate returns.
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("KeyValue-update-\(UUID().uuidString).dmg")
                    do {
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.moveItem(at: localURL, to: dest)
                        cont.resume(returning: dest)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            )
            self.downloadDelegate = delegate

            let session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
            var request = URLRequest(url: url)
            request.setValue("KeyValue/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            self.downloadTask = task
            task.resume()
        }
    }

    // MARK: - Mount / Unmount DMG

    /// Mounts a DMG and returns the mount-point path (e.g. `/Volumes/KeyValue`).
    ///
    /// Before mounting we strip quarantine from the DMG file itself so that
    /// the mounted volume and its contents don't inherit the attribute.
    private func mountDMG(at dmgURL: URL) async throws -> String {
        // Strip quarantine from the DMG before mounting so contents are clean.
        stripAllQuarantine(at: dmgURL)

        // `hdiutil attach -nobrowse -noverify -noautoopen -plist <path>`
        // returns a plist with mount info.
        let out = try await shell(
            "/usr/bin/hdiutil",
            args: [
                "attach", dmgURL.path,
                "-nobrowse", "-noverify", "-noautoopen", "-plist",
            ]
        )
        // Parse plist to extract mount point
        guard let data = out.data(using: .utf8),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw NSError(
                domain: "UpdateService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法解析 hdiutil 输出"])
        }
        // Find the entity with a mount-point key.
        for entity in entities {
            if let mp = entity["mount-point"] as? String {
                return mp
            }
        }
        throw NSError(
            domain: "UpdateService", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "DMG 挂载成功但未找到挂载点"])
    }

    private func unmountDMG(mountPoint: String) {
        // Best-effort; ignore errors.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mountPoint, "-quiet", "-force"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Locate .app in DMG

    /// Finds the first `.app` bundle at the top level of the mount point.
    private func findAppBundle(in mountPoint: String) -> URL? {
        let url = URL(fileURLWithPath: mountPoint)
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            )
        else { return nil }
        return items.first { $0.pathExtension == "app" }
    }

    // MARK: - Replace Running App

    /// Replaces the currently running `.app` bundle with the new one.
    ///
    /// Strategy:
    ///   1. Determine the path of the running .app
    ///   2. Move the old .app to a temporary backup
    ///   3. Copy the new .app to the original location
    ///   4. Strip ALL quarantine / security xattrs so Gatekeeper won't block it
    ///   5. Re-apply ad-hoc code signature (matches build.sh behaviour)
    ///   6. Remove the backup
    ///
    /// If the copy fails, we attempt to restore from the backup.
    private func replaceCurrentApp(with newAppURL: URL) throws {
        let currentAppURL = Bundle.main.bundleURL  // e.g. /Applications/KeyValue.app
        let fm = FileManager.default

        // The running app might not end with .app when built via `swift run`.
        // In that case there's nothing to replace.
        guard currentAppURL.pathExtension == "app" else {
            throw NSError(
                domain: "UpdateService", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "当前进程不是 .app 包，无法自动替换"])
        }

        // ── 0. Pre-strip quarantine from the DMG source BEFORE copying ──
        // The mounted DMG inherits quarantine from the downloaded file.
        // Stripping it here prevents the attribute from propagating into
        // the final installation directory.
        stripAllQuarantine(at: newAppURL)

        let parentDir = currentAppURL.deletingLastPathComponent()
        let backupURL = parentDir.appendingPathComponent(
            ".KeyValue-backup-\(UUID().uuidString).app")

        // 1. Backup current
        try fm.moveItem(at: currentAppURL, to: backupURL)

        do {
            // 2. Copy new
            try fm.copyItem(at: newAppURL, to: currentAppURL)
        } catch {
            // Rollback: restore from backup
            try? fm.moveItem(at: backupURL, to: currentAppURL)
            throw error
        }

        // 3. Strip ALL quarantine & security xattrs from the installed copy
        stripAllQuarantine(at: currentAppURL)

        // 4. Re-sign ad-hoc — matches what build.sh does for open-source
        //    distribution.  Without this macOS Gatekeeper / AMFI will reject
        //    the binary because the original ad-hoc signature was tied to
        //    the build machine.
        resignAdHoc(at: currentAppURL)

        // 5. Touch the bundle so Launch Services notices the change
        try? fm.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: currentAppURL.path
        )

        // 6. Remove backup
        try? fm.removeItem(at: backupURL)
    }

    // MARK: - Quarantine & Signing Helpers

    /// Recursively clears **all** extended attributes (`xattr -cr`) from the
    /// app bundle.  This removes `com.apple.quarantine` as well as any other
    /// security-related xattrs that macOS attaches to downloaded files.
    /// Using `-c` (clear all) is more thorough than `-d` (delete one).
    private func stripAllQuarantine(at appURL: URL) {
        runProcess("/usr/bin/xattr", args: ["-cr", appURL.path])
    }

    /// Re-applies an ad-hoc code signature to the .app bundle, replicating
    /// the same flags that `build.sh` uses for open-source distribution:
    ///
    ///   codesign --force --sign - --timestamp=none \
    ///            --entitlements MacKeyValue-adhoc.entitlements <app>
    ///
    /// This is necessary because:
    ///   1. The original ad-hoc signature is bound to the build machine's
    ///      code-directory hash; copying to a different location invalidates it.
    ///   2. macOS 14+ / 26 AMFI rejects ad-hoc binaries with restricted
    ///      entitlements or mismatched signatures.
    ///   3. A fresh ad-hoc signature makes the binary trusted by the kernel
    ///      without needing an Apple Developer ID.
    private func resignAdHoc(at appURL: URL) {
        // ── Sign nested frameworks / dylibs first ────────────────────────
        let fm = FileManager.default
        if let enumerator = fm.enumerator(atPath: appURL.path) {
            while let relativePath = enumerator.nextObject() as? String {
                let ext = (relativePath as NSString).pathExtension
                if ext == "framework" || ext == "dylib" {
                    let fullPath = appURL.appendingPathComponent(relativePath).path
                    runProcess(
                        "/usr/bin/codesign",
                        args: [
                            "--force", "--sign", "-",
                            "--timestamp=none",
                            fullPath,
                        ])
                } else if ext == "bundle" {
                    // Only sign .bundle directories that are real signable
                    // macOS bundles (contain Info.plist or a Mach-O binary).
                    // SPM resource bundles like swift-crypto_Crypto.bundle
                    // only contain PrivacyInfo.xcprivacy and codesign rejects
                    // them with "bundle format unrecognized, invalid, or
                    // unsuitable".
                    let bundleURL = appURL.appendingPathComponent(relativePath)
                    let hasInfoPlist = fm.fileExists(
                        atPath: bundleURL.appendingPathComponent("Info.plist").path)
                    let hasCodeSignature = fm.fileExists(
                        atPath: bundleURL.appendingPathComponent("_CodeSignature").path)
                    if hasInfoPlist || hasCodeSignature {
                        runProcess(
                            "/usr/bin/codesign",
                            args: [
                                "--force", "--sign", "-",
                                "--timestamp=none",
                                bundleURL.path,
                            ])
                    }
                }
            }
        }

        // ── Sign the main app bundle ─────────────────────────────────────
        // Try to locate the ad-hoc entitlements inside the new bundle first
        // (build.sh copies Resources/ into the bundle).  If not found, sign
        // without entitlements — still much better than a broken signature.
        let entitlementsCandidates = [
            appURL.appendingPathComponent("Contents/Resources/MacKeyValue-adhoc.entitlements"),
            appURL.appendingPathComponent("Contents/Resources/MacKeyValue.entitlements"),
        ]
        let entitlementsPath = entitlementsCandidates.first { fm.fileExists(atPath: $0.path) }

        var args = ["--force", "--sign", "-", "--timestamp=none"]
        if let ent = entitlementsPath {
            args.insert(contentsOf: ["--entitlements", ent.path], at: args.count - 1)
        }
        args.append(appURL.path)
        runProcess("/usr/bin/codesign", args: args)
    }

    /// Runs a process synchronously, discarding output.  Best-effort; ignores errors.
    @discardableResult
    private func runProcess(_ executablePath: String, args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            print("[UpdateService] Failed to run \(executablePath): \(error)")
            return -1
        }
    }

    // MARK: - Homebrew Update

    /// Full Homebrew upgrade flow:
    ///   1. `brew update` — refresh all taps (including aresnasa/tap) so
    ///      Homebrew sees the latest Cask version.
    ///   2. `brew upgrade --cask keyvalue` — download & install the new DMG.
    ///   3. Strip quarantine + re-sign ad-hoc — same post-install hardening
    ///      that the DMG auto-update path uses, because the Cask `postflight`
    ///      only does `xattr -cr` which is not always sufficient on macOS 14+.
    ///   4. Relaunch via direct binary execution (bypasses Gatekeeper).
    @MainActor
    private func upgradeViaBrew(brewPath: String, expectedVersion: String) async {
        state = .updating
        guard let brew = resolvedBrewPath(hint: brewPath) else {
            state = .failed("未找到 brew。\n请手动运行：\nbrew update && brew upgrade --cask keyvalue")
            return
        }

        // ── 1. Refresh taps so Homebrew knows about the new version ──────
        do {
            let tapOut = try await shell(brew, args: ["update"])
            print("[UpdateService] brew update:\n\(tapOut)")
        } catch {
            // Non-fatal: `brew update` can fail if network is flaky but the
            // tap might already be up-to-date locally.
            print("[UpdateService] brew update warning (continuing): \(error.localizedDescription)")
        }

        // ── 2. Upgrade the cask ──────────────────────────────────────────
        // `brew upgrade --cask` can fail with "already an App at …" when
        // /Applications/KeyValue.app exists but wasn't installed by Homebrew
        // (e.g. manual DMG install, or app self-update replaced the bundle).
        // In that case we fall back to `brew install --cask --force` which
        // forcefully overwrites the existing .app.
        var upgraded = false
        do {
            let upgradeOut = try await shell(brew, args: ["upgrade", "--cask", "keyvalue"])
            print("[UpdateService] brew upgrade:\n\(upgradeOut)")
            upgraded = true
        } catch {
            let msg =
                (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                ?? error.localizedDescription

            // Already up-to-date — not an error.
            if msg.contains("already installed") || msg.contains("up-to-date") {
                state = .upToDate
                return
            }

            // "It seems there is already an App at '/Applications/KeyValue.app'"
            // → force reinstall to overwrite it.
            if msg.contains("already an App") || msg.contains("already a App")
                || msg.contains("already exists")
            {
                print("[UpdateService] Existing app detected, retrying with --force reinstall…")
                do {
                    let reinstallOut = try await shell(
                        brew,
                        args: ["install", "--cask", "keyvalue", "--force"]
                    )
                    print("[UpdateService] brew install --force:\n\(reinstallOut)")
                    upgraded = true
                } catch {
                    let retryMsg =
                        (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                        ?? error.localizedDescription
                    state = .failed(
                        "brew 强制安装失败：\(retryMsg)\n\n请手动运行：\nbrew install --cask keyvalue --force"
                    )
                    return
                }
            }

            if !upgraded {
                state = .failed(
                    "brew upgrade 失败：\(msg)\n\n请手动运行：\nbrew update && brew upgrade --cask keyvalue"
                )
                return
            }
        }

        // ── 3. Post-install hardening ────────────────────────────────────
        // Homebrew installs the .app into /Applications (or ~/Applications).
        // The Cask postflight does `xattr -cr` but does NOT re-sign, which
        // can still trigger Gatekeeper on macOS 14+ / 26.
        let installedAppCandidates = [
            "/Applications/\(appName).app",
            NSHomeDirectory() + "/Applications/\(appName).app",
        ]
        if let installedPath = installedAppCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) {
            let appURL = URL(fileURLWithPath: installedPath)
            stripAllQuarantine(at: appURL)
            resignAdHoc(at: appURL)
            // Touch so Launch Services notices the update
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: installedPath
            )
            print("[UpdateService] Post-install hardening complete: \(installedPath)")
        }

        // ── 4. Success + relaunch ────────────────────────────────────────
        state = .success(version: expectedVersion)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        relaunchApp()
    }

    // MARK: - Git Pull

    @MainActor
    private func pullViaGit(repoPath: String) async {
        state = .updating
        guard let git = resolvedGitPath() else {
            state = .failed("未找到 git。\n请手动运行：\ncd \(repoPath)\ngit pull")
            return
        }
        do {
            let out = try await shell(git, args: ["-C", repoPath, "pull", "--ff-only"])
            print("[UpdateService] git pull:\n\(out)")
            if out.contains("Already up to date") || out.contains("already up-to-date") {
                state = .upToDate
            } else {
                state = .success(version: "latest")
                await promptRebuild(repoPath: repoPath)
            }
        } catch {
            let msg =
                (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                ?? error.localizedDescription
            state = .failed("git pull 失败：\(msg)\n\n请手动运行：\ncd \(repoPath) && git pull")
        }
    }

    @MainActor
    private func promptRebuild(repoPath: String) async {
        let alert = NSAlert()
        alert.messageText = "代码已更新"
        alert.informativeText = "git pull 成功，请重新构建：\n\ncd \(repoPath)\n./MacKeyValue/build.sh --run"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "复制命令")
        alert.addButton(withTitle: "关闭")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            let cmd = "cd \(repoPath) && ./MacKeyValue/build.sh --run"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }

    // MARK: - Shell Helpers

    private func resolvedBrewPath(hint: String) -> String? {
        let candidates = [hint, "/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func resolvedGitPath() -> String? {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func shell(_ exec: String, args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                proc.executableURL = URL(fileURLWithPath: exec)
                proc.arguments = args
                proc.standardOutput = stdout
                proc.standardError = stderr
                // Pass through PATH so brew can find its dependencies
                var env = ProcessInfo.processInfo.environment
                env["PATH"] =
                    "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                proc.environment = env

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let out =
                        String(
                            data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                        ) ?? ""
                    let err =
                        String(
                            data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                        ) ?? ""
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: out + err)
                    } else {
                        cont.resume(
                            throwing: NSError(
                                domain: "UpdateService",
                                code: Int(proc.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? out : err]
                            ))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Relaunch

    /// Relaunches the app after an update.
    ///
    /// **Why not `open KeyValue.app`?**
    /// `open` goes through Launch Services which enforces Gatekeeper.  For
    /// ad-hoc signed (open-source) apps this triggers the "Apple cannot
    /// verify" dialog — or worse, on macOS 14+/26, outright refusal.
    ///
    /// Instead we:
    ///   1. Spawn a tiny shell watcher that waits for our PID to exit.
    ///   2. The watcher then directly executes the **binary** inside the
    ///      .app bundle (`Contents/MacOS/MacKeyValue`), which completely
    ///      bypasses Launch Services / Gatekeeper.
    ///   3. Terminate ourselves so the watcher can proceed.
    private func relaunchApp() {
        let appURL = Bundle.main.bundleURL
        let binPath =
            appURL
            .appendingPathComponent("Contents/MacOS/MacKeyValue")
            .path

        let pid = ProcessInfo.processInfo.processIdentifier

        // The script:
        //   • Waits for the current process to exit (polling kill -0).
        //   • Strips quarantine one more time (belt & suspenders).
        //   • Launches the binary directly — no Launch Services / Gatekeeper.
        //   • Uses `disown` so the shell doesn't wait for the child.
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done
            /usr/bin/xattr -cr "\(appURL.path)" 2>/dev/null
            "\(binPath)" &
            disown
            """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()

        // Terminate ourselves so the watcher script can relaunch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Persistence

    private func saveLastChecked() {
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: lastCheckedKey)
    }

    // MARK: - Version Comparison

    /// Returns true when v1 is strictly greater than v2 (numeric segment compare).
    private func isNewer(_ v1: String, than v2: String) -> Bool {
        let seg1 = v1.split(separator: ".").compactMap { Int($0) }
        let seg2 = v2.split(separator: ".").compactMap { Int($0) }
        let len = max(seg1.count, seg2.count)
        for i in 0..<len {
            let a = i < seg1.count ? seg1[i] : 0
            let b = i < seg2.count ? seg2[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - GitHub API

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(
            string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        req.setValue("KeyValue/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

// MARK: - Download Delegate

/// `URLSessionDownloadDelegate` that bridges progress & completion back to
/// the `UpdateService` via closures.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {

    let onProgress: (Double) -> Void
    let onComplete: (URL?, URLResponse?, Error?) -> Void

    init(
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (URL?, URLResponse?, Error?) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        onComplete(location, downloadTask.response, nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(fraction, 1.0))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onComplete(nil, task.response, error)
        }
    }
}
