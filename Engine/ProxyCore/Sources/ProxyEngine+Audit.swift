import Foundation
import LoomSharedModels

/// `AuditControlling`: the durable trail of MCP write actions. The MCP tool
/// choke point records here; the human's Audit panel and `get_audit_log` read it
/// back. Reads are never recorded — only writes touch real traffic.
extension ProxyEngine {
    public func recordAudit(_ entry: AuditEntry) async {
        await auditStore.record(entry)
    }

    public func recentAuditEntries(limit: Int) async -> [AuditEntry] {
        await auditStore.recent(limit: limit)
    }

    public func auditStream() async -> AsyncStream<AuditEntry> {
        await auditStore.stream()
    }

    public func clearAudit() async {
        await auditStore.clear()
    }
}
