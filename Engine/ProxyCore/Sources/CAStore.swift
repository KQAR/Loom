import Foundation
import Synchronization
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
    /// Where "the stored CA was unreadable, so a new one is coming" is reported. It
    /// is the most invisible failure in the whole engine: the *new* CA works
    /// perfectly, and every client that trusted the old one fails its handshake with
    /// nothing to point at.
    private let degradations: DegradationLog?

    init(fileURL: URL? = nil, degradations: DegradationLog? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        self.degradations = degradations
    }

    /// One wording for all four ways the file can be present and unusable — the
    /// operator's next step is the same in every one of them.
    private func reportRegeneration(_ because: String) {
        let reason = """
        The stored root CA could not be read (\(because)), so a new one was generated — every \
        client that trusted the old CA has to trust this one, and until then intercepted HTTPS \
        fails at the handshake.
        """
        Log.tls.error("CA store at \(self.fileURL.path, privacy: .public): \(reason, privacy: .public)")
        degradations?.record(.certificateAuthorityRegenerated, reason)
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
            reportRegeneration(error.localizedDescription)
            return nil
        }
        guard let blob = String(data: data, encoding: .utf8) else {
            reportRegeneration("it is not UTF-8")
            return nil
        }
        let parts = blob.components(separatedBy: Self.separator)
        guard parts.count == 2 else {
            reportRegeneration("it is malformed — \(parts.count) parts")
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
final class InMemoryCAStore: CAStore, Sendable {
    private let material: Mutex<CAMaterial?>

    init(seed: CAMaterial? = nil) { material = Mutex(seed) }

    func load() throws -> CAMaterial? {
        material.withLock { $0 }
    }

    func save(_ newValue: CAMaterial) throws {
        material.withLock { $0 = newValue }
    }
}

enum CAStoreError: Error {
    case keychain(OSStatus)
}

/// One-time move of a legacy Keychain-stored CA into the file store, so a user who
/// already trusted a Keychain CA keeps it after the switch to file storage.
///
/// Split out of `ProxyEngine` and parameterized on both stores so it is testable at
/// all: the engine's version reached the real Application Support path and the real
/// login Keychain, which no test can touch. Its promise — "an already-trusted CA
/// survives" — was the least-verified claim in the CA path.
enum CAStoreMigration {
    /// - Returns: `destination`, ready to use, whether or not anything was migrated.
    @discardableResult
    static func migrate(into destination: CAStore, from legacy: @autoclosure () -> CAStore) -> CAStore {
        // A CA already in the file store wins — nothing to do, and the Keychain is
        // not touched (a missing item returns errSecItemNotFound with no prompt,
        // but not reading at all is cheaper and quieter still).
        switch Result(catching: { try destination.load() }) {
        case .success(.some):
            return destination
        case let .failure(error):
            // Distinct from "empty": the destination exists but won't read. Migrating
            // over it would be right (a legacy CA is better than a regenerated one),
            // but the caller deserves to know the file is broken either way.
            Log.tls.error("CA store unreadable while checking for a legacy migration: \(String(describing: error))")
        case .success(.none):
            break
        }

        let legacyMaterial: CAMaterial?
        do {
            legacyMaterial = try legacy().load()
        } catch {
            Log.tls.error("""
            Legacy Keychain CA could not be read, so it cannot be migrated; a new root \
            CA will be generated and the previously trusted one will stop working: \
            \(String(describing: error))
            """)
            return destination
        }
        guard let legacyMaterial else { return destination }

        do {
            try destination.save(legacyMaterial)
            Log.tls.info("Migrated the legacy Keychain root CA into the file store; existing trust is preserved.")
        } catch {
            // The old code swallowed this. A failed write means the next launch finds
            // an empty file store and mints a *new* CA — the user's trusted CA stops
            // working, with nothing anywhere saying why.
            Log.tls.error("""
            Migrating the legacy Keychain root CA failed; a new root CA will be \
            generated and the previously trusted one will stop working: \
            \(String(describing: error))
            """)
        }
        return destination
    }
}
