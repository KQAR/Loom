import Foundation
import Testing
@testable import LoomSharedModels

/// The three capacity numbers, and the relationship between them.
///
/// These exist as one type because each of them used to be a literal in several
/// places, and raising one raised fewer of its copies than it had. What a test can
/// still add on top of that is the *ordering*: the numbers are independent values, so
/// nothing but this stops a future adjustment from making the window larger than the
/// store or the ring larger than the window — both of which fail silently, as a row
/// that draws and cannot be opened, or flows held in memory the table refuses to show.
@Suite struct FlowLimitsTests {
    @Test func theCapsAreOrdered() {
        #expect(FlowLimits.isOrdered, """
        memoryRing=\(FlowLimits.memoryRing) windowRows=\(FlowLimits.windowRows) \
        persistedRows=\(FlowLimits.persistedRows) — expected memoryRing ≤ windowRows ≤ persistedRows
        """)
    }

    /// A zero ring is a supported configuration (an embedder that retains nothing),
    /// but a negative or zero *store* would mean every read resolves to nothing while
    /// the surfaces still claim to search it.
    @Test func theCapsArePositive() {
        #expect(FlowLimits.memoryRing > 0)
        #expect(FlowLimits.windowRows > 0)
        #expect(FlowLimits.persistedRows > 0)
    }
}
