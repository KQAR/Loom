import Foundation
import LoomSharedModels

/// Breakpoints: arm/disarm, list what is currently held, and resume (edit or
/// abort). A held exchange is parking a live client connection, so these are the
/// tools with the shortest fuse — `resume` is what lets the traffic go.
extension MCPToolExecutor {
    // MARK: Breakpoints

    func handleArmBreakpoint(_ arguments: MCPArguments) async throws -> String {
        guard let matchRaw = try arguments.object("match"),
              let match = try Self.ruleMatch(from: matchRaw) else {
            throw MCPError.invalidParams("`match` with `url_pattern` is required")
        }
        let breakpoint = Breakpoint(
            match: match,
            onRequest: try arguments.bool("on_request", or: true),
            onResponse: try arguments.bool("on_response", or: false),
            comment: try arguments.string("comment")
        )
        do {
            try await engine.armBreakpoint(breakpoint)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(Self.breakpoint(breakpoint))
    }

    func handleDisarmBreakpoint(_ arguments: MCPArguments) async throws -> String {
        let id = try arguments.requiredUUID("id", "a breakpoint UUID string")
        do {
            try await engine.disarmBreakpoint(id: id)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        return prettyJSON(["disarmed": id.uuidString])
    }

    func handleListPending(_ arguments: MCPArguments) async throws -> String {
        let armed = await engine.armedBreakpoints()
        let pending = await engine.pendingBreakpoints()
        return prettyJSON([
            "armed": armed.map(Self.breakpoint),
            "pending": pending.map(Self.pendingBreakpoint),
        ])
    }

    func handleResume(_ arguments: MCPArguments) async throws -> String {
        // One spelling. The `id` alias this used to read is gone rather than fixed:
        // list_pending renders an `id` on *both* an armed breakpoint and a held
        // exchange, so accepting `id` here takes either and answers "no such hold" for
        // the wrong one — indistinguishable from a hold that resolved on its own.
        // Refused at the choke point, the same slip comes back naming the key.
        guard let id = try arguments.uuid("pending_id") else {
            throw MCPError.invalidParams("`pending_id` must be a held-breakpoint UUID string")
        }
        let abort = try arguments.bool("abort", or: false)
        let edit = BreakpointEdit(
            method: try arguments.string("method"),
            url: try arguments.string("url"),
            statusCode: try arguments.int("status_code"),
            setHeaders: try Self.headerPairs(from: arguments),
            removeHeaders: try arguments.stringArray("remove_headers"),
            body: try Self.bodyOverride(from: arguments)
        )
        do {
            try await engine.resumeBreakpoint(pendingID: id, abort: abort, edit: edit)
        } catch let error as ProxyControlError {
            throw MCPToolFailure(error.message)
        }
        var payload: [String: Any] = ["resumed": id.uuidString, "aborted": abort]
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
