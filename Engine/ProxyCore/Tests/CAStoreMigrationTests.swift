import Foundation
import Synchronization
import Testing
@testable import LoomProxyCore

/// The switch from a Keychain-stored root CA to a file-stored one promised that a
/// user who had already trusted the Keychain CA keeps it. That promise had no test:
/// the migration was private, reached the real Application Support path and the real
/// login Keychain, and swallowed every error with `try?` — so a failed write looked
/// exactly like a fresh install and silently invalidated the trusted CA.
///
/// These pin the behaviour against injected stores.
@Suite("CA store migration") struct CAStoreMigrationTests {
    private var legacyMaterial: CAMaterial {
        CAMaterial(certificatePEM: "LEGACY-CERT", privateKeyPEM: "LEGACY-KEY")
    }
    private var existingMaterial: CAMaterial {
        CAMaterial(certificatePEM: "EXISTING-CERT", privateKeyPEM: "EXISTING-KEY")
    }

    @Test func anEmptyDestinationTakesTheLegacyCA() throws {
        // The whole point: the already-trusted CA survives the storage change.
        let destination = InMemoryCAStore()
        CAStoreMigration.migrate(into: destination, from: InMemoryCAStore(seed: legacyMaterial))
        #expect(try destination.load() == legacyMaterial)
    }

    @Test func anExistingCAIsNeverOverwritten() throws {
        let destination = InMemoryCAStore(seed: existingMaterial)
        CAStoreMigration.migrate(into: destination, from: InMemoryCAStore(seed: legacyMaterial))
        #expect(try destination.load() == existingMaterial,
                "a CA already in the file store must win — migrating over it would invalidate current trust")
    }

    @Test func noLegacyCA_leavesTheDestinationEmptyForAFreshMint() throws {
        let destination = InMemoryCAStore()
        CAStoreMigration.migrate(into: destination, from: InMemoryCAStore())
        #expect(try destination.load() == nil)
    }

    @Test func theLegacyStoreIsNotReadWhenTheDestinationAlreadyHasACA() {
        // Reading the Keychain is the step that can prompt; skip it entirely when
        // there is nothing to migrate into.
        let legacy = CountingCAStore(seed: legacyMaterial)
        CAStoreMigration.migrate(into: InMemoryCAStore(seed: existingMaterial), from: legacy)
        #expect(legacy.loadCount == 0)
    }

    @Test func anUnreadableLegacyStoreIsSurvived() throws {
        // Fail open: no migration, but the engine still gets a usable store back and
        // mints a fresh CA rather than throwing out of `init`.
        let destination = InMemoryCAStore()
        let store = CAStoreMigration.migrate(into: destination, from: ThrowingCAStore(onLoad: true))
        #expect(try store.load() == nil)
    }

    @Test func aFailedWriteDoesNotPretendToHaveMigrated() throws {
        // The silent case this exists to catch: the write fails, so the next launch
        // finds an empty store and mints a new CA. The migration must not report
        // success by leaving the caller with something that looks migrated.
        let destination = ThrowingCAStore(onSave: true)
        let store = CAStoreMigration.migrate(into: destination, from: InMemoryCAStore(seed: legacyMaterial))
        #expect(try store.load() == nil)
        #expect(destination.saveAttempts == 1, "it must have tried, and the failure is logged, not swallowed")
    }

    @Test func anUnreadableDestinationStillTakesTheLegacyCA() throws {
        // A corrupt file store plus a legacy Keychain CA: recovering the trusted CA
        // beats regenerating, so the migration proceeds.
        let destination = ThrowingCAStore(onLoad: true, throwsOnceOnLoad: true)
        CAStoreMigration.migrate(into: destination, from: InMemoryCAStore(seed: legacyMaterial))
        #expect(try destination.load() == legacyMaterial)
    }
}

/// Counts `load()` calls so a test can prove the Keychain wasn't touched.
private final class CountingCAStore: CAStore, Sendable {
    private struct State {
        var material: CAMaterial?
        var loadCount = 0
    }

    private let state: Mutex<State>

    init(seed: CAMaterial? = nil) { state = Mutex(State(material: seed)) }

    var loadCount: Int { state.withLock { $0.loadCount } }

    func load() throws -> CAMaterial? {
        state.withLock { state in
            state.loadCount += 1
            return state.material
        }
    }

    func save(_ newValue: CAMaterial) throws {
        state.withLock { $0.material = newValue }
    }
}

/// Fails on demand. `throwsOnceOnLoad` models a store that is unreadable now but
/// readable after a successful write — i.e. a corrupt file that gets replaced.
private final class ThrowingCAStore: CAStore, Sendable {
    private struct State {
        var material: CAMaterial?
        var loadsThrown = 0
        var saveAttempts = 0
    }

    private let onLoad: Bool
    private let onSave: Bool
    private let throwsOnceOnLoad: Bool
    private let state = Mutex(State())

    init(onLoad: Bool = false, onSave: Bool = false, throwsOnceOnLoad: Bool = false) {
        self.onLoad = onLoad
        self.onSave = onSave
        self.throwsOnceOnLoad = throwsOnceOnLoad
    }

    var saveAttempts: Int { state.withLock { $0.saveAttempts } }

    func load() throws -> CAMaterial? {
        try state.withLock { state in
            if onLoad, !throwsOnceOnLoad || state.loadsThrown == 0 {
                state.loadsThrown += 1
                throw CAStoreError.keychain(-25300)
            }
            return state.material
        }
    }

    func save(_ newValue: CAMaterial) throws {
        try state.withLock { state in
            state.saveAttempts += 1
            if onSave { throw CAStoreError.keychain(-25299) }
            state.material = newValue
        }
    }
}
