import Foundation
import LoomSharedModels

/// `RulesControlling`. Validation lives on `TrafficRule`, persistence and the
/// live snapshot in `RulesConfig` — the same `RulesConfig` instance the
/// `RuleApplyingForwarder` reads, which is why a rule written here takes effect
/// on the next request without any further plumbing.
extension ProxyEngine {
    public func rulesState() async -> RulesState {
        // The per-rule drop counts live on the store (that is where the drops happen)
        // and are folded in here rather than kept in `RulesConfig`, which is persisted
        // — a session count written to the rules file would come back on the next
        // launch attached to traffic that never arrived.
        var state = rulesConfig.snapshot()
        state.droppedCounts = await store.droppedCountsByRule
        return state
    }

    public func setRulesEnabled(_ enabled: Bool) async {
        rulesConfig.setEnabled(enabled)
    }

    public func addRule(_ rule: TrafficRule) async throws {
        if let reason = rule.validationError() {
            throw ProxyControlError.invalidRule(reason)
        }
        rulesConfig.add(rule)
    }

    public func updateRule(_ rule: TrafficRule) async throws {
        if let reason = rule.validationError() {
            throw ProxyControlError.invalidRule(reason)
        }
        guard rulesConfig.update(rule) else {
            throw ProxyControlError.ruleNotFound(rule.id)
        }
    }

    public func deleteRule(id: UUID) async throws {
        guard rulesConfig.delete(id: id) else {
            throw ProxyControlError.ruleNotFound(id)
        }
    }

    @discardableResult
    public func setRules(_ rules: [TrafficRule]) async -> SetRulesReport {
        // Degrade gracefully: apply every rule that validates and drop the rest,
        // so a single malformed rule can't reject the whole synced set. The
        // caller gets a per-rule report of what was left out and why.
        var applied: [TrafficRule] = []
        var rejected: [SetRulesReport.Rejection] = []
        for rule in rules {
            if let reason = rule.validationError() {
                rejected.append(.init(id: rule.id, name: rule.name, reason: reason))
            } else {
                applied.append(rule)
            }
        }
        rulesConfig.replaceAll(applied)
        return SetRulesReport(applied: applied, rejected: rejected)
    }

    public func setGroupEnabled(group: String?, enabled: Bool) async {
        rulesConfig.setGroupEnabled(group: group, enabled: enabled)
    }
}
