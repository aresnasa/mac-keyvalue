import AppKit
import Foundation

// MARK: - Build Identity

/// A stable identity for an app build. This is deliberately kept outside of
/// Keychain because it contains no credentials; it only records migration state.
struct AppBuildIdentity: Equatable, CustomStringConvertible {
    let version: String
    let build: String

    init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    init(bundle: Bundle) {
        version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    var description: String { "\(version) (\(build))" }

    /// Returns true when the persisted launch marker belongs to a different
    /// release build. A missing marker is treated as a migration so installs
    /// from versions that predate this logic are handled once.
    static func requiresMigration(from persistedMarker: String?, to current: AppBuildIdentity)
        -> Bool
    {
        persistedMarker != current.description
    }

    /// Numeric comparison handles version components such as `0.1.10`.
    func isOlder(than other: AppBuildIdentity) -> Bool {
        if version.compare(other.version, options: .numeric) == .orderedAscending {
            return true
        }
        if version.compare(other.version, options: .numeric) == .orderedSame {
            return build.compare(other.build, options: .numeric) == .orderedAscending
        }
        return false
    }
}

// MARK: - Upgrade Authorization

/// Coordinates the non-sensitive parts of a version upgrade at launch.
///
/// A signed macOS build can lose its Accessibility authorization after an
/// update. The actual authorization remains managed by TCC; this service only
/// remembers which build has completed the preparation step, gracefully asks
/// older duplicate processes to quit, and resets this app's stale TCC record
/// when a newer build still lacks authorization.
enum AppUpgradeAuthorizationService {
    private static let lastPreparedBuildKey = "com.aresnasa.mackeyvalue.authorizationPreparedBuild"

    @discardableResult
    static func prepareForLaunch(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        runningApplications: [NSRunningApplication]? = nil
    ) -> Bool {
        // `swift run` has no stable .app identity to migrate or to target with
        // tccutil, so retain the existing bare-executable behavior.
        guard bundle.bundlePath.hasSuffix(".app"), let bundleIdentifier = bundle.bundleIdentifier
        else {
            return false
        }

        let currentBuild = AppBuildIdentity(bundle: bundle)
        let previousMarker = defaults.string(forKey: lastPreparedBuildKey)
        guard AppBuildIdentity.requiresMigration(from: previousMarker, to: currentBuild) else {
            return false
        }

        let applications =
            runningApplications
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        terminateOlderInstances(
            applications,
            currentBuild: currentBuild,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )

        // Do not disturb a current, valid grant. If the newly launched build
        // lacks access, reset only this bundle's stale Accessibility record so
        // the normal in-app authorization guide can request a fresh grant.
        if !AXIsProcessTrusted(),
            !ClipboardService.shared.resetAccessibilityAuthorizationForAppUpgrade()
        {
            print(
                "[UpgradeAuthorization] Accessibility authorization reset failed; will retry on next launch"
            )
            return false
        }

        defaults.set(currentBuild.description, forKey: lastPreparedBuildKey)
        print("[UpgradeAuthorization] Prepared authorization migration for \(currentBuild)")
        return true
    }

    static func terminateOlderInstances(
        _ applications: [NSRunningApplication],
        currentBuild: AppBuildIdentity,
        currentProcessIdentifier: pid_t
    ) {
        for application in applications
        where application.processIdentifier != currentProcessIdentifier {
            guard
                let appURL = application.bundleURL,
                let candidateBundle = Bundle(url: appURL)
            else {
                continue
            }

            let candidateBuild = AppBuildIdentity(bundle: candidateBundle)
            guard candidateBuild.isOlder(than: currentBuild) else { continue }

            if application.terminate() {
                print(
                    "[UpgradeAuthorization] Asked older app instance to quit: \(appURL.path) (\(candidateBuild))"
                )
            } else {
                print(
                    "[UpgradeAuthorization] Could not quit older app instance: \(appURL.path) (\(candidateBuild))"
                )
            }
        }
    }
}
