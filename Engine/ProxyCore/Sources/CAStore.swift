import Foundation
import Security
import LoomSharedModels

/// The persisted root-CA material: certificate + private key, both PEM-encoded.
struct CAMaterial: Sendable, Equatable {
    var certificatePEM: String
    var privateKeyPEM: String
}

/// Where the root CA is sealed between launches. The live store uses the
/// Keychain; tests use an in-memory store so no global state leaks.
protocol CAStore: Sendable {
    func load() throws -> CAMaterial?
    func save(_ material: CAMaterial) throws
}

/// Keychain-backed store. The CA lives as a single generic-password item whose
/// payload is `certPEM` + a separator + `keyPEM`; the private key never touches
/// disk in plaintext.
final class KeychainCAStore: CAStore {
    private let service: String
    private let account: String
    private static let separator = "\n--LOOM-CA-SPLIT--\n"

    init(service: String = "com.loom.ca", account: String = "root") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> CAMaterial? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let blob = String(data: data, encoding: .utf8)
        else {
            throw CAStoreError.keychain(status)
        }
        let parts = blob.components(separatedBy: Self.separator)
        guard parts.count == 2 else { return nil }
        return CAMaterial(certificatePEM: parts[0], privateKeyPEM: parts[1])
    }

    func save(_ material: CAMaterial) throws {
        let blob = material.certificatePEM + Self.separator + material.privateKeyPEM
        let data = Data(blob.utf8)

        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw CAStoreError.keychain(status) }
    }
}

/// File-backed store (the default). The CA blob lives in a single 0600 file under
/// Application Support — the same approach Charles / mitmproxy / Proxyman use for
/// their root CA. Reading a file triggers no Keychain ACL check, so a rebuilt
/// (ad-hoc re-signed) app never re-prompts for the login password the way a
/// Keychain item does. The private key is protected by file permissions.
final class FileCAStore: CAStore {
    private static let separator = "\n--LOOM-CA-SPLIT--\n"
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
    }

    private static var defaultURL: URL {
        LoomPaths.appSupportFile("ca-store.pem")
    }

    func load() throws -> CAMaterial? {
        // Absent is normal (first run). Present-but-unreadable is not: returning nil
        // makes the caller mint a *new* root CA, which silently invalidates the one
        // the user already trusted — every HTTPS interception then fails until they
        // trust the new CA. That must not be a silent event.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Log.tls.error("""
            CA store unreadable at \(self.fileURL.path, privacy: .public); \
            a new root CA will be generated and the previously trusted one will stop \
            working: \(String(describing: error))
            """)
            return nil
        }
        guard let blob = String(data: data, encoding: .utf8) else {
            Log.tls.error("CA store at \(self.fileURL.path, privacy: .public) is not UTF-8; regenerating (previously trusted CA will stop working).")
            return nil
        }
        let parts = blob.components(separatedBy: Self.separator)
        guard parts.count == 2 else {
            Log.tls.error("CA store at \(self.fileURL.path, privacy: .public) is malformed (\(parts.count) parts); regenerating (previously trusted CA will stop working).")
            return nil
        }
        return CAMaterial(certificatePEM: parts[0], privateKeyPEM: parts[1])
    }

    func save(_ material: CAMaterial) throws {
        let blob = material.certificatePEM + Self.separator + material.privateKeyPEM
        try LoomPaths.createSecureDirectory(at: fileURL.deletingLastPathComponent())
        try Data(blob.utf8).write(to: fileURL, options: .atomic)
        LoomPaths.restrictToOwner(fileURL)
    }
}

/// In-memory store for tests. Thread-safe so it can be shared across the actor
/// and NIO handlers without ceremony.
final class InMemoryCAStore: CAStore, @unchecked Sendable {
    private let lock = NSLock()
    private var material: CAMaterial?

    init(seed: CAMaterial? = nil) { material = seed }

    func load() throws -> CAMaterial? {
        lock.lock(); defer { lock.unlock() }
        return material
    }

    func save(_ newValue: CAMaterial) throws {
        lock.lock(); defer { lock.unlock() }
        material = newValue
    }
}

enum CAStoreError: Error {
    case keychain(OSStatus)
}
