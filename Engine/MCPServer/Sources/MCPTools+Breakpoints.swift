import Foundation
import LoomSharedModels

/// Breakpoints: arm/disarm, list what is currently held, and resume (edit or
/// abort). A held exchange is parking a live client connection, so these are the
/// tools with the shortest fuse — `resume` is what lets the traffic go.
extension MCPToolExecutor {
    // MARK: Breakpoints

    func handleArmBreakpoint(_ arguments: [String: Any]) async throws -> String {
        guard let matchRaw = arguments["match"] as? [String: Any],
              let match = Self.ruleMatch(from: matchRaw) else {
            throw MCPError.invalidParams("`match` with `url_pattern` is required")
        }
        let breakpoint = Breakpoint(
            match: match,
            onRequest: (arguments["on_request"] as? Bool) ?? true,
            onResponse: (arguments["on_response"] as? Bool) ?? false,
            comment: arguments["comment"] as? String
        )
        do {
            try await engine.armBreakpoint(breakpoint)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(Self.breakpoint(breakpoint))
    }

    func handleDisarmBreakpoint(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`id` must be a breakpoint UUID string")
        }
        do {
            try await engine.disarmBreakpoint(id: id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["disarmed": idString])
    }

    func handleListPending(_ arguments: [String: Any]) async throws -> String {
        let armed = await engine.armedBreakpoints()
        let pending = await engine.pendingBreakpoints()
        return prettyJSON([
            "armed": armed.map(Self.breakpoint),
            "pending": pending.map(Self.pendingBreakpoint),
        ])
    }

    func handleResume(_ arguments: [String: Any]) async throws -> String {
        guard let idString = arguments["pending_id"] as? String, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`pending_id` must be a held-breakpoint UUID string")
        }
        let abort = (arguments["abort"] as? Bool) ?? false
        var setHeaders: [HeaderPair]?
        if let raw = arguments["set_headers"] as? [String: Any] {
            setHeaders = raw.map { HeaderPair(name: $0.key, value: String(describing: $0.value)) }
        }
        let body: BodyOverride
        if let bodyString = arguments["body"] as? String {
            body = .replace(Data(bodyString.utf8))
        } else if (arguments["clear_body"] as? Bool) == true {
            body = .clear
        } else {
            body = .keep
        }
        let edit = BreakpointEdit(
            method: arguments["method"] as? String,
            url: arguments["url"] as? String,
            statusCode: arguments["status_code"] as? Int,
            setHeaders: setHeaders,
            removeHeaders: arguments["remove_headers"] as? [String],
            body: body
        )
        do {
            try await engine.resumeBreakpoint(pendingID: id, abort: abort, edit: edit)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["resumed": idString, "aborted": abort])
    }

    static func breakpoint(_ bp: Breakpoint) -> [String: Any] {
        var out: [String: Any] = [
            "id": bp.id.uuidString,
            "match": matchDict(bp.match),
            "onRequest": bp.onRequest,
            "onResponse": bp.onResponse,
            "createdAt": iso8601.string(from: bp.createdAt),
        ]
        if let comment = bp.comment { out["comment"] = comment }
        return out
    }

    static func pendingBreakpoint(_ pending: PendingBreakpoint) -> [String: Any] {
        var out: [String: Any] = [
            "id": pending.id.uuidString,
            "breakpointId": pending.breakpointID.uuidString,
            "phase": pending.phase.rawValue,
            "heldAt": iso8601.string(from: pending.heldAt),
            "request": [
                "method": pending.method,
                "url": pending.url,
                "headers": pending.requestHeaders.map { ["name": $0.name, "value": $0.value] },
                "body": bodyField(pending.requestBody),
            ],
        ]
        if pending.phase == .response {
            var response: [String: Any] = [
                "headers": (pending.responseHeaders ?? []).map { ["name": $0.name, "value": $0.value] },
                "body": bodyField(pending.responseBody),
            ]
            if let statusCode = pending.statusCode { response["status"] = statusCode }
            out["response"] = response
        }
        return out
    }
}
