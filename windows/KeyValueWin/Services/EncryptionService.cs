using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace KeyValueWin.Services;

/// <summary>
/// AES-256-GCM encryption – fully compatible with MacKeyValue's Swift EncryptionService.
/// <br/>
/// Wire formats:
/// <list type="bullet">
/// <item>Device-local:   nonce(12) || ciphertext || tag(16)</item>
/// <item>Password-based: salt(16)  || nonce(12)  || ciphertext || tag(16)</item>
/// </list>
/// </summary>
public sealed class EncryptionService
{
    // ── Singleton ────────────────────────────────────────────────────────────

    public static readonly EncryptionService Shared = new();
    private EncryptionService() { }

    // ── Constants ────────────────────────────────────────────────────────────

    private const int NonceSize = 12;
    private const int TagSize   = 16;
    private const int SaltSize  = 16;
    private const int KeySize   = 32;  // 256 bits

    // HKDF info bytes = UTF-8("MacKeyValue-EntryKey") – matches Swift constant
    private static readonly byte[] HkdfInfo = Encoding.UTF8.GetBytes("MacKeyValue-EntryKey");

    // DPAPI key file location
    private static readonly string KeyFilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MacKeyValue", "master.key");

    // ── In-memory key cache ───────────────────────────────────────────────────

    private byte[]? _cachedKey;
    private readonly object _lock = new();

    // ── Public API – device-local encrypt / decrypt ──────────────────────────

    public byte[] Encrypt(string plainText) =>
        Encrypt(Encoding.UTF8.GetBytes(plainText));

    public byte[] Encrypt(byte[] plainData)
    {
        var key = GetOrCreateMasterKey();
        return AesGcmEncrypt(plainData, key);
    }

    public string DecryptToString(byte[] combined) =>
        Encoding.UTF8.GetString(Decrypt(combined));

    public byte[] Decrypt(byte[] combined)
    {
        if (combined.Length < NonceSize + TagSize)
            throw new CryptographicException($"Data too short ({combined.Length} bytes)");
        var key = GetOrCreateMasterKey();
        return AesGcmDecrypt(combined, key);
    }

    // ── Public API – password-derived encrypt / decrypt ──────────────────────

    /// Encrypts using a password-derived key.
    /// Output: salt(16) || nonce(12) || ciphertext || tag(16)
    public byte[] Encrypt(byte[] plainData, string password)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltSize);
        var key  = DeriveKey(password, salt);
        var encrypted = AesGcmEncrypt(plainData, key);

        var result = new byte[SaltSize + encrypted.Length];
        Buffer.BlockCopy(salt, 0, result, 0, SaltSize);
        Buffer.BlockCopy(encrypted, 0, result, SaltSize, encrypted.Length);
        return result;
    }

    /// Decrypts data produced by Encrypt(byte[], string).
    public byte[] Decrypt(byte[] data, string password)
    {
        if (data.Length <= SaltSize)
            throw new CryptographicException("Data too short to contain salt");

        var salt     = data[..SaltSize];
        var combined = data[SaltSize..];
        var key      = DeriveKey(password, salt);
        try { return AesGcmDecrypt(combined, key); }
        catch { throw new CryptographicException("Wrong password or corrupted data"); }
    }

    // ── Key management ────────────────────────────────────────────────────────

    public bool HasMasterKey => File.Exists(KeyFilePath);

    public void DeleteMasterKey()
    {
        if (File.Exists(KeyFilePath)) File.Delete(KeyFilePath);
        lock (_lock) { _cachedKey = null; }
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    private byte[] GetOrCreateMasterKey()
    {
        lock (_lock)
        {
            if (_cachedKey is not null) return _cachedKey;

            if (File.Exists(KeyFilePath))
            {
                var protected_ = File.ReadAllBytes(KeyFilePath);
                _cachedKey = ProtectedData.Unprotect(
                    protected_, null, DataProtectionScope.CurrentUser);
            }
            else
            {
                _cachedKey = RandomNumberGenerator.GetBytes(KeySize);
                Directory.CreateDirectory(Path.GetDirectoryName(KeyFilePath)!);
                var protected_ = ProtectedData.Protect(
                    _cachedKey, null, DataProtectionScope.CurrentUser);
                File.WriteAllBytes(KeyFilePath, protected_);
            }
            return _cachedKey;
        }
    }

    private static byte[] AesGcmEncrypt(byte[] plainData, byte[] key)
    {
        var nonce  = RandomNumberGenerator.GetBytes(NonceSize);
        var cipher = new byte[plainData.Length];
        var tag    = new byte[TagSize];

        using var aes = new AesGcm(key, TagSize);
        aes.Encrypt(nonce, plainData, cipher, tag);

        // Format: nonce(12) || ciphertext || tag(16)
        var result = new byte[NonceSize + cipher.Length + TagSize];
        Buffer.BlockCopy(nonce,  0, result, 0,                            NonceSize);
        Buffer.BlockCopy(cipher, 0, result, NonceSize,                    cipher.Length);
        Buffer.BlockCopy(tag,    0, result, NonceSize + cipher.Length,    TagSize);
        return result;
    }

    private static byte[] AesGcmDecrypt(byte[] combined, byte[] key)
    {
        if (combined.Length < NonceSize + TagSize)
            throw new CryptographicException("Combined data too short");

        var nonce  = combined[..NonceSize];
        var tag    = combined[^TagSize..];
        var cipher = combined[NonceSize..^TagSize];
        var plain  = new byte[cipher.Length];

        using var aes = new AesGcm(key, TagSize);
        aes.Decrypt(nonce, cipher, tag, plain);
        return plain;
    }

    private static byte[] DeriveKey(string password, byte[] salt)
    {
        var passwordBytes = Encoding.UTF8.GetBytes(password);
        return HKDF.DeriveKey(HashAlgorithmName.SHA256,
            ikm:  passwordBytes,
            outputLength: KeySize,
            salt: salt,
            info: HkdfInfo);
    }
}
