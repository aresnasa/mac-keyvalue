import Foundation
import Crypto
import Security

// MARK: - EncryptionError

enum EncryptionError: LocalizedError {
    case keyGenerationFailed
    case keychainSaveFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case invalidData(String)
    case masterKeyNotFound
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate encryption key"
        case .keychainSaveFailed(let status):
            return "Failed to save key to Keychain: \(status)"
        case .keychainReadFailed(let status):
            return "Failed to read key from Keychain: \(status)"
        case .keychainDeleteFailed(let status):
            return "Failed to delete key from Keychain: \(status)"
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .decryptionFailed(let reason):
            return "Decryption failed: \(reason)"
        case .invalidData(let reason):
            return "Invalid data: \(reason)"
        case .masterKeyNotFound:
            return "Master encryption key not found in Keychain"
        case .keyDerivationFailed:
            return "Key derivation from password failed"
        }
    }
}

// MARK: - EncryptionService

/// Provides AES-256-GCM encryption with a Keychain-backed master key.
///
/// The service stores a 256-bit symmetric key in the macOS Keychain and uses it
/// to encrypt / decrypt arbitrary `Data` payloads via AES-GCM (from Apple's
/// CryptoKit / swift-crypto).  It also supports deriving per-entry keys from a
/// user-supplied password using HKDF.
final class EncryptionService {

    // MARK: - Constants

    private enum Constants {
        static let keychainService = "com.mackeyvalue.encryption"
        static let masterKeyAccount = "master-key"
        static let keySizeBytes = 32 // 256 bits
        static let saltSize = 16
        static let hkdfInfo = "MacKeyValue-EntryKey".data(using: .utf8)!
    }

    // MARK: - Singleton

    static let shared = EncryptionService()

    // MARK: - Cached master key

    /// In-memory cache so we only hit the Keychain once per app launch.
    private var cachedMasterKey: SymmetricKey?

    private let queue = DispatchQueue(label: "com.mackeyvalue.encryption", attributes: .concurrent)

    // MARK: - Init

    private init() {}

    // MARK: - Public API – Encrypt / Decrypt

    /// Encrypts a plain-text `String` and returns a combined nonce+ciphertext+tag blob.
    func encrypt(_ plainText: String) throws -> Data {
        guard let data = plainText.data(using: .utf8) else {
            throw EncryptionError.invalidData("Unable to encode string to UTF-8")
        }
        return try encrypt(data)
    }

    /// Encrypts raw `Data` and returns a combined nonce+ciphertext+tag blob.
    func encrypt(_ data: Data) throws -> Data {
        let key = try getMasterKey()
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw EncryptionError.encryptionFailed("Failed to produce combined sealed box")
            }
            return combined
        } catch let error as EncryptionError {
            throw error
        } catch {
            throw EncryptionError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypts a combined blob back into a plain-text `String`.
    func decryptToString(_ data: Data) throws -> String {
        let decrypted = try decrypt(data)
        guard let string = String(data: decrypted, encoding: .utf8) else {
            throw EncryptionError.invalidData("Decrypted data is not valid UTF-8")
        }
        return string
    }

    /// Decrypts a combined blob back into raw `Data`.
    ///
    /// The combined blob must contain at least a 12-byte nonce + 16-byte GCM
    /// tag (28 bytes minimum). Passing empty or too-short data is treated as
    /// "no encrypted value" rather than a crypto error.
    func decrypt(_ combined: Data) throws -> Data {
        // AES-GCM combined = nonce(12) + ciphertext(>=0) + tag(16) => min 28 bytes
        guard combined.count >= 28 else {
            throw EncryptionError.invalidData(
                combined.isEmpty
                    ? "该条目没有加密值（可能来自 Gist 同步或导入）"
                    : "加密数据长度不足（\(combined.count) 字节），可能已损坏"
            )
        }
        let key = try getMasterKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch let error as EncryptionError {
            throw error
        } catch {
            throw EncryptionError.decryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Public API – Password-derived key operations

    /// Encrypts data with a key derived from `password` + random salt.
    /// Returns `salt + nonce + ciphertext + tag`.
    func encrypt(_ data: Data, withPassword password: String) throws -> Data {
        let salt = generateRandomBytes(count: Constants.saltSize)
        let key = try deriveKey(from: password, salt: salt)
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else {
                throw EncryptionError.encryptionFailed("Failed to produce combined sealed box")
            }
            var result = Data()
            result.append(salt)
            result.append(combined)
            return result
        } catch let error as EncryptionError {
            throw error
        } catch {
            throw EncryptionError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypts data that was encrypted with `encrypt(_:withPassword:)`.
    func decrypt(_ data: Data, withPassword password: String) throws -> Data {
        guard data.count > Constants.saltSize else {
            throw EncryptionError.invalidData("Data too short to contain salt")
        }
        let salt = data.prefix(Constants.saltSize)
        let combined = data.dropFirst(Constants.saltSize)
        let key = try deriveKey(from: password, salt: Data(salt))
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key)
        } catch let error as EncryptionError {
            throw error
        } catch {
            throw EncryptionError.decryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Public API – Key Management

    /// Ensures a master key exists in the Keychain; generates one if absent.
    @discardableResult
    func ensureMasterKeyExists() throws -> Bool {
        if (try? getMasterKey()) != nil {
            return false // key already existed
        }
        let key = SymmetricKey(size: .bits256)
        try saveMasterKeyToKeychain(key)
        queue.sync(flags: .barrier) {
            cachedMasterKey = key
        }
        return true // new key was created
    }

    /// Re-encrypts all provided entries' values from an old master key to a new one.
    /// Useful when the user wants to rotate the master key.
    func rotateMasterKey(entries: [(Data)], oldKey: SymmetricKey? = nil) throws -> (newKey: SymmetricKey, reEncrypted: [Data]) {
        let currentKey = try oldKey ?? getMasterKey()
        let newKey = SymmetricKey(size: .bits256)

        var reEncrypted: [Data] = []
        for combined in entries {
            // Decrypt with old key
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plainData = try AES.GCM.open(sealedBox, using: currentKey)
            // Re-encrypt with new key
            let newSealedBox = try AES.GCM.seal(plainData, using: newKey)
            guard let newCombined = newSealedBox.combined else {
                throw EncryptionError.encryptionFailed("Failed to produce combined sealed box during rotation")
            }
            reEncrypted.append(newCombined)
        }

        // Persist the new master key
        try deleteMasterKeyFromKeychain()
        try saveMasterKeyToKeychain(newKey)
        queue.sync(flags: .barrier) {
            cachedMasterKey = newKey
        }

        return (newKey, reEncrypted)
    }

    /// Deletes the master key from the Keychain (destructive!).
    func deleteMasterKey() throws {
        try deleteMasterKeyFromKeychain()
        queue.sync(flags: .barrier) {
            cachedMasterKey = nil
        }
    }

    /// Returns `true` if a master key is present in the Keychain.
    var hasMasterKey: Bool {
        return (try? getMasterKey()) != nil
    }

    // MARK: - Internal Helpers

    /// Retrieves (or creates and caches) the master `SymmetricKey`.
    private func getMasterKey() throws -> SymmetricKey {
        // Fast path – check cache
        if let cached = queue.sync(execute: { cachedMasterKey }) {
            return cached
        }

        // Slow path – read from Keychain
        let keyData = try readMasterKeyFromKeychain()
        let key = SymmetricKey(data: keyData)
        queue.sync(flags: .barrier) {
            cachedMasterKey = key
        }
        return key
    }

    // MARK: - Keychain Operations

    private func saveMasterKeyToKeychain(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: Constants.masterKeyAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Key already exists – update it
            let searchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Constants.keychainService,
                kSecAttrAccount as String: Constants.masterKeyAccount,
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: keyData,
            ]
            let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw EncryptionError.keychainSaveFailed(updateStatus)
            }
        } else if status != errSecSuccess {
            throw EncryptionError.keychainSaveFailed(status)
        }
    }

    private func readMasterKeyFromKeychain() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: Constants.masterKeyAccount,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw EncryptionError.masterKeyNotFound
            }
            throw EncryptionError.keychainReadFailed(status)
        }
        return data
    }

    private func deleteMasterKeyFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.keychainService,
            kSecAttrAccount as String: Constants.masterKeyAccount,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EncryptionError.keychainDeleteFailed(status)
        }
    }

    // MARK: - Key Derivation

    /// Derives a 256-bit key from a password and salt using HKDF-SHA256.
    private func deriveKey(from password: String, salt: Data) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw EncryptionError.keyDerivationFailed
        }
        let inputKey = SymmetricKey(data: passwordData)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Constants.hkdfInfo,
            outputByteCount: Constants.keySizeBytes
        )
        return derivedKey
    }

    // MARK: - Random Bytes

    private func generateRandomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

// MARK: - Convenience Extensions

extension EncryptionService {

    /// Encrypts a `Codable` value by JSON-encoding it first.
    func encrypt<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(value)
        return try encrypt(jsonData)
    }

    /// Decrypts a combined blob and JSON-decodes it into the requested type.
    func decrypt<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decryptedData = try decrypt(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: decryptedData)
    }
}
