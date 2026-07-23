import Foundation
import SharedModels

/// Deterministic constructors for the domain fixtures the AppFeature tests share.
/// IDs and timestamps are pinned so `TestStore` state assertions stay exact.
enum Fixtures {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func flow(
        id: UUID = UUID(),
        method: String = "GET",
        url: String = "https://api.example.com/v1/home?x=1",
        requestHeaders: [HeaderPair] = [],
        requestBody: Data? = nil,
        status: Int? = 200,
        responseHeaders: [HeaderPair] = [HeaderPair(name: "Content-Type", value: "application/json")],
        responseBody: Data? = Data(#"{"ok":true}"#.utf8),
        error: String? = nil,
        replayedFrom: UUID? = nil,
        sourceApp: SourceApp? = nil
    ) -> Flow {
        let response = status.map { code in
            CapturedResponse(statusCode: code, headers: responseHeaders, body: responseBody)
        }
        let completedAt = epoch.addingTimeInterval(0.12)
        let outcome: FlowOutcome
        if let error {
            outcome = .failed(FlowError(error), at: completedAt, partialResponse: response)
        } else if let response {
            outcome = .completed(response, at: completedAt)
        } else {
            outcome = .pending
        }
        return Flow(
            id: id,
            request: CapturedRequest(method: method, url: url, headers: requestHeaders, body: requestBody),
            startedAt: epoch,
            outcome: outcome,
            replayedFrom: replayedFrom,
            sourceApp: sourceApp
        )
    }

    static func rule(
        id: UUID = UUID(),
        name: String = "Test Rule",
        group: String? = nil,
        isEnabled: Bool = true,
        urlPattern: String = "https://api.example.com/v1/home",
        methods: [String] = [],
        route: Route = .block
    ) -> TrafficRule {
        TrafficRule(
            id: id,
            name: name,
            group: group,
            isEnabled: isEnabled,
            match: RuleMatch(urlPattern: urlPattern, methods: methods),
            actions: RuleActions(route: route),
            createdAt: epoch
        )
    }
}
