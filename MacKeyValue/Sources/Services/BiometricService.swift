import Foundation
import LocalAuthentication

// MARK: - BiometricError

enum BiometricError: LocalizedError {
    case notAvailable(String)
    case authenticationFailed(String)
    case userCancelled
    case userFallback
    case systemCancel
    case passcodeNotSet
    case biometryNotEnrolled
    case biometryLockout
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable(let reason):
            return "生物识别不可用: \(reason)"
        case .authenticationFailed(let reason):
            return "认证失败: \(reason)"
        case .userCancelled:
            return "用户取消了认证"
        case .userFallback:
            return "用户选择了备用认证方式"
        case .systemCancel:
            return "系统取消了认证"
        case .passcodeNotSet:
            return "设备未设置密码"
        case .biometryNotEnrolled:
            return "未录入 Touch ID 指纹"
        case .biometryLockout:
            return "Touch ID 已锁定，请使用密码解锁"
        case .unknown(let error):
            return "认证错误: \(error.localizedDescription)"
        }
    }
}

// MARK: - BiometricType

enum BiometricType: Equatable {
    case none
    case touchID
    case opticID

    var displayName: String {
        switch self {
        case .none: return "无"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        }
    }

    var iconName: String {
        switch self {
        case .none: return "lock.fill"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        }
    }
}

// MARK: - BiometricService

/// Provides Touch ID / biometric and device-password authentication using the
/// `LocalAuthentication` framework.
///
/// ### Usage
///
///     let service = BiometricService.shared
///
///     // Quick check
///     if service.isBiometricAvailable {
///         let ok = await service.authenticate(reason: "解锁密码库")
///         if ok { /* proceed */ }
///     }
///
///     // With detailed error handling
///     do {
///         try await service.authenticateOrThrow(reason: "查看敏感信息")
///         // Success
///     } catch {
///         print(error.localizedDescription)
///     }
///
/// ### Thread Safety
///
/// All public methods are safe to call from any thread.  The underlying
/// `LAContext` evaluation is asynchronous and does not block the main thread.
/// Published property mutations are always dispatched to the main actor.
///
final class BiometricService: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = BiometricService()

    // MARK: - Session Configuration

    /// Duration (in seconds) for which a successful biometric/password
    /// authentication remains valid.  During this window, subsequent
    /// authentication requests are satisfied immediately by the cached
    /// `LAContext`, avoiding repeated Touch ID / password prompts.
    ///
    /// Set to 0 to disable session caching (every call prompts).
    /// The maximum value supported by the system is 300 (5 minutes).
    var sessionDuration: TimeInterval = 120

    // MARK: - Session State

    /// A cached `LAContext` that has been successfully authenticated.
    /// Reused within `sessionDuration` to avoid repeated prompts.
    private var cachedContext: LAContext?

    /// Timestamp of the last successful authentication.
    private var lastAuthTime: Date?

    /// Serialises access to the cached session state.
    private let sessionLock = NSLock()

    // MARK: - Properties

    /// The type of biometric hardware available on this Mac.
    var availableBiometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .touchID:
            return .touchID
        case .opticID:
            return .opticID
        default:
            return .none
        }
    }

    /// Returns `true` if Touch ID (or another biometric) is enrolled and available.
    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Returns `true` if device passcode / password is available as a fallback.
    var isDevicePasswordAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    // MARK: - Init

    private init() {}

    // MARK: - Authentication (async/await)

    /// Authenticates the user via Touch ID, falling back to device password.
    ///
    /// - Parameter reason: A human-readable string displayed in the Touch ID
    ///   prompt explaining why authentication is needed.
    /// - Returns: `true` if the user authenticated successfully, `false` if
    ///   they cancelled or authentication is not available.
    func authenticate(reason: String) async -> Bool {
        do {
            try await authenticateOrThrow(reason: reason)
            return true
        } catch BiometricError.userCancelled {
            return false
        } catch {
            print("[BiometricService] Authentication failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Authenticates the user via Touch ID, falling back to device password.
    ///
    /// Uses `deviceOwnerAuthentication` policy which allows both biometric and
    /// password fallback — the system handles the UI automatically.
    ///
    /// If a previous authentication is still valid (within `sessionDuration`),
    /// this method returns immediately without prompting the user again.
    /// This prevents the annoying "multiple password prompts" issue.
    ///
    /// - Parameter reason: Displayed in the system authentication dialog.
    /// - Throws: `BiometricError` on failure.
    func authenticateOrThrow(reason: String) async throws {
        // ── Fast path: check if we have a valid cached session ───────
        if checkCachedSession() {
            return
        }

        // ── Slow path: create a new context and authenticate ─────────
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        context.localizedFallbackTitle = "使用密码"
        // Allow Touch ID result to be reused for the session duration,
        // so the system itself can skip re-prompting for back-to-back calls.
        let duration = sessionDuration
        if duration > 0 {
            context.touchIDAuthenticationAllowableReuseDuration = min(duration, 300)
        }

        // Use deviceOwnerAuthentication: tries biometric first, then falls
        // back to the device (macOS login) password automatically.
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw mapLAError(error)
        }

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            // Success — cache the authenticated context for session reuse.
            cacheAuthenticatedContext(context)
            print("[BiometricService] Authentication succeeded (\(availableBiometricType.displayName)), session cached for \(Int(duration))s")
        } catch let laError as LAError {
            throw mapLAErrorCode(laError)
        } catch {
            throw BiometricError.unknown(error)
        }
    }

    /// Checks if a valid cached session exists (synchronous, lock-safe).
    /// Returns `true` if the session is still valid.
    private func checkCachedSession() -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let cachedCtx = cachedContext,
              let authTime = lastAuthTime,
              sessionDuration > 0,
              Date().timeIntervalSince(authTime) < sessionDuration else {
            return false
        }
        // Verify the cached context is still usable
        var checkError: NSError?
        if cachedCtx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &checkError) {
            print("[BiometricService] Using cached session (age: \(String(format: "%.0f", Date().timeIntervalSince(authTime)))s)")
            return true
        }
        // Cached context expired or invalidated — clear it.
        cachedContext = nil
        lastAuthTime = nil
        return false
    }

    /// Caches a successfully authenticated context (synchronous, lock-safe).
    private func cacheAuthenticatedContext(_ context: LAContext) {
        sessionLock.lock()
        cachedContext = context
        lastAuthTime = Date()
        sessionLock.unlock()
    }

    /// Authenticates using **only** biometrics (no password fallback).
    ///
    /// - Parameter reason: Displayed in the Touch ID prompt.
    /// - Throws: `BiometricError` on failure.
    func authenticateBiometricOnly(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        // Setting fallbackTitle to empty string hides the "Use Password" button.
        context.localizedFallbackTitle = ""

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw mapLAError(error)
        }

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            print("[BiometricService] Biometric-only authentication succeeded")
        } catch let laError as LAError {
            throw mapLAErrorCode(laError)
        } catch {
            throw BiometricError.unknown(error)
        }
    }

    // MARK: - Session Management

    /// Returns `true` if a valid authentication session exists and the user
    /// would not be prompted on the next `authenticate` / `authenticateOrThrow`
    /// call.
    var hasValidSession: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard let authTime = lastAuthTime, sessionDuration > 0 else { return false }
        return Date().timeIntervalSince(authTime) < sessionDuration
    }

    /// Immediately invalidates the cached authentication session, causing the
    /// next authentication request to prompt the user again.
    func invalidateSession() {
        sessionLock.lock()
        cachedContext = nil
        lastAuthTime = nil
        sessionLock.unlock()
        print("[BiometricService] Session invalidated")
    }

    // MARK: - Convenience – Authenticate Then Execute

    /// Authenticates and then executes the given closure on success.
    ///
    /// This is a convenience wrapper for the common pattern:
    /// ```
    /// if await biometric.authenticate(reason: "...") {
    ///     doSomething()
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - reason: Displayed in the authentication dialog.
    ///   - action: The closure to run if authentication succeeds.
    /// - Returns: `true` if authentication succeeded and the action ran.
    @discardableResult
    func authenticateAndPerform(
        reason: String,
        action: @escaping () async throws -> Void
    ) async -> Bool {
        let ok = await authenticate(reason: reason)
        guard ok else { return false }
        do {
            try await action()
            return true
        } catch {
            print("[BiometricService] Action after authentication failed: \(error)")
            return false
        }
    }

    // MARK: - Private – Error Mapping

    private func mapLAError(_ error: NSError?) -> BiometricError {
        guard let error = error else {
            return .notAvailable("未知原因")
        }
        if let laError = error as? LAError {
            return mapLAErrorCode(laError)
        }
        return .notAvailable(error.localizedDescription)
    }

    private func mapLAErrorCode(_ error: LAError) -> BiometricError {
        switch error.code {
        case .userCancel:
            return .userCancelled
        case .userFallback:
            return .userFallback
        case .systemCancel:
            return .systemCancel
        case .passcodeNotSet:
            return .passcodeNotSet
        case .biometryNotEnrolled, .touchIDNotEnrolled:
            return .biometryNotEnrolled
        case .biometryNotAvailable, .touchIDNotAvailable:
            return .notAvailable("此设备不支持 Touch ID")
        case .biometryLockout, .touchIDLockout:
            return .biometryLockout
        case .authenticationFailed:
            return .authenticationFailed("指纹或密码不匹配")
        case .appCancel:
            return .systemCancel
        case .invalidContext:
            return .authenticationFailed("认证上下文已失效")
        case .notInteractive:
            return .authenticationFailed("无法显示认证对话框")
        case .watchNotAvailable:
            return .notAvailable("Apple Watch 不可用")
        case .biometryNotPaired:
            return .notAvailable("生物识别设备未配对")
        case .biometryDisconnected:
            return .notAvailable("生物识别设备已断开")
        case .invalidDimensions:
            return .authenticationFailed("无效的认证维度")
        @unknown default:
            return .unknown(error)
        }
    }
}
