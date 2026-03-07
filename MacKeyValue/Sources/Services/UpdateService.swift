import AppKit
import Combine
import Foundation

// MARK: - GitHub API model

private struct GitHubRelease: Decodable {
    let tagName:     String
    let htmlURL:     String
    let name:        String
    let body:        String?
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName     = "tag_name"
        case htmlURL     = "html_url"
        case name, body
        case publishedAt = "published_at"
    }
}

// MARK: - UpdateService

/// Checks for app updates via GitHub Releases API and performs the update
/// using the method appropriate for the detected installation type:
///   • Homebrew cask  → `brew upgrade --cask keyvalue`  + auto-restart
///   • Git source     → `git pull`  (offers rebuild command)
///   • DMG / unknown  → opens GitHub Releases page in the browser
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
            case .homebrew:   return "Homebrew"
            case .sourceTree: return "源码构建"
            case .appBundle:  return "DMG 安装"
            case .unknown:    return "未知"
            }
        }
        var icon: String {
            switch self {
            case .homebrew:   return "shippingbox.fill"
            case .sourceTree: return "chevron.left.forwardslash.chevron.right"
            case .appBundle:  return "arrow.down.app.fill"
            case .unknown:    return "questionmark.app.fill"
            }
        }
        var canAutoUpdate: Bool {
            switch self {
            case .homebrew, .sourceTree: return true
            default: return false
            }
        }
    }

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: String)
        case updating
        case success(version: String)
        case failed(String)

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }
        var isChecking: Bool { self == .checking }
        var isUpdating: Bool { self == .updating }

        var availableVersion: String? {
            if case .available(let v, _) = self { return v }
            return nil
        }
        var releaseURL: String? {
            if case .available(_, let u) = self { return u }
            return nil
        }
    }

    // MARK: - Published State

    @Published var state:         UpdateState   = .idle
    @Published var installMethod: InstallMethod = .unknown
    @Published var lastChecked:   Date?

    // MARK: - Constants

    private let repoOwner = "aresnasa"
    private let repoName  = "mac-keyvalue"
    private let checkIntervalSeconds: TimeInterval = 86_400  // 24 h
    private let lastCheckedKey = "com.aresnasa.mackeyvalue.updateLastChecked"

    // MARK: - Init

    private init() {
        lastChecked   = UserDefaults.standard.object(forKey: lastCheckedKey) as? Date
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
            let latest  = release.tagName.trimmingCharacters(in: .init(charactersIn: "vV"))
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
        default:
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
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

    // MARK: - Homebrew Update

    @MainActor
    private func upgradeViaBrew(brewPath: String, expectedVersion: String) async {
        state = .updating
        guard let brew = resolvedBrewPath(hint: brewPath) else {
            state = .failed("未找到 brew。\n请手动运行：brew upgrade --cask keyvalue")
            return
        }
        do {
            let out = try await shell(brew, args: ["upgrade", "--cask", "keyvalue"])
            print("[UpdateService] brew:\n\(out)")
            state = .success(version: expectedVersion)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            relaunchApp()
        } catch {
            let msg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                      ?? error.localizedDescription
            state = .failed("brew upgrade 失败：\(msg)\n\n请手动运行：\nbrew upgrade --cask keyvalue")
        }
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
            let msg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
                      ?? error.localizedDescription
            state = .failed("git pull 失败：\(msg)\n\n请手动运行：\ncd \(repoPath) && git pull")
        }
    }

    @MainActor
    private func promptRebuild(repoPath: String) async {
        let alert = NSAlert()
        alert.messageText     = "代码已更新"
        alert.informativeText = "git pull 成功，请重新构建：\n\ncd \(repoPath)\n./MacKeyValue/build.sh --run"
        alert.alertStyle      = .informational
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
                let proc   = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                proc.executableURL    = URL(fileURLWithPath: exec)
                proc.arguments        = args
                proc.standardOutput   = stdout
                proc.standardError    = stderr
                // Pass through PATH so brew can find its dependencies
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                proc.environment = env

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: out + err)
                    } else {
                        cont.resume(throwing: NSError(
                            domain: "UpdateService",
                            code:   Int(proc.terminationStatus),
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

    private func relaunchApp() {
        let url  = Bundle.main.bundleURL
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments     = [url.path]
        try? proc.run()
        NSApplication.shared.terminate(nil)
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
        let len  = max(seg1.count, seg2.count)
        for i in 0..<len {
            let a = i < seg1.count ? seg1[i] : 0
            let b = i < seg2.count ? seg2[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - GitHub API

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
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
