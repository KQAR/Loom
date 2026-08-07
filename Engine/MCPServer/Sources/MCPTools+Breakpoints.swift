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
        // `id` is accepted as well as `pending_id` because the held exchange renders
        // its own identifier as `id` (list_pending / wait_for_pending), so copying the
        // field straight across — the obvious thing to do — used to fail validation
        // and cost a round trip to discover.
        let rawID = (arguments["pending_id"] ?? arguments["id"]) as? String
        guard let idString = rawID, let id = UUID(uuidString: idString) else {
            throw MCPError.invalidParams("`pending_id` (or `id`) must be a held-breakpoint UUID string")
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
        var payload: [String: Any] = ["resumed": idString, "aborted": abort]
        // The edit already went to the client; the warning is how the operator learns
        // the JSON they meant to send wasn't JSON (`MCPBodyWarnings`).
        if !abort { Self.attach(warnings: Self.bodyWarnings(fromArguments: arguments), to: &payload) }
        return prettyJSON(payload)
    }

    static func breakpoint(_ bp: Breakpoint) -> [String: Any] {
        MCPRender.dict(BreakpointRender(
            id: bp.id.uuidString,
            match: RuleMatchRender(bp.match),
            onRequest: bp.onRequest,
            onResponse: bp.onResponse,
            createdAt: bp.createdAt,
            comment: bp.comment
        ))
    }

    static func pendingBreakpoint(_ pending: PendingBreakpoint) -> [String: Any] {
        MCPRender.dict(PendingBreakpointRender(
            id: pending.id.uuidString,
            breakpointId: pending.breakpointID.uuidString,
            phase: pending.phase.rawValue,
            heldAt: pending.heldAt,
            request: PendingRequestRender(
                method: pending.method,
                url: pending.url,
                headers: RenderedHeader.list(pending.requestHeaders),
                body: bodyField(pending.requestBody)
            ),
            // Only in the response phase: the client is waiting on bytes the origin
            // has already sent, and there is nothing to show before that.
            response: pending.phase == .response
                ? PendingResponseRender(
                    headers: RenderedHeader.list(pending.responseHeaders ?? []),
                    body: bodyField(pending.responseBody),
                    status: pending.statusCode
                )
                : nil
        ))
    }
}
