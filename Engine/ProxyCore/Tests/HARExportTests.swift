import Testing
import Foundation
import LoomSharedModels

@Suite struct HARExportTests {
    private func decode(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func encode_producesValidHARStructure() throws {
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "POST",
                url: "https://api.example.test/v1/home?x=1&y=2",
                headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                body: Data(#"{"a":1}"#.utf8)
            ),
            startedAt: Date(timeIntervalSince1970: 1_000),
            outcome: .completed(
                CapturedResponse(
                    statusCode: 200,
                    headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                    body: Data(#"{"ok":true}"#.utf8)
                ),
                at: Date(timeIntervalSince1970: 1_000.25)
            ),
            appliedRules: [AppliedRule(id: UUID(), name: "mock home")]
        )

        let json = try decode(HARExport.encode([flow], appVersion: "9.9"))
        let log = try #require(json["log"] as? [String: Any])
        #expect(log["version"] as? String == "1.2")
        #expect((log["creator"] as? [String: Any])?["name"] as? String == "Loom")

        let entries = try #require(log["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry["time"] as? Int == 250)
        #expect(entry["_appliedRules"] as? [String] == ["mock home"])

        let request = try #require(entry["request"] as? [String: Any])
        #expect(request["method"] as? String == "POST")
        #expect(request["url"] as? String == "https://api.example.test/v1/home?x=1&y=2")
        #expect((request["queryString"] as? [[String: String]])?.count == 2)
        #expect((request["postData"] as? [String: Any])?["text"] as? String == #"{"a":1}"#)

        let response = try #require(entry["response"] as? [String: Any])
        #expect(response["status"] as? Int == 200)
        #expect((response["content"] as? [String: Any])?["text"] as? String == #"{"ok":true}"#)
    }

    @Test func encode_binaryBody_isBase64NotDropped() throws {
        // Regression: a non-UTF-8 body used to vanish from the export entirely.
        let binary = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02]) // not valid UTF-8
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "http://x.test/img", headers: []),
            startedAt: Date(timeIntervalSince1970: 0),
            outcome: .completed(
                CapturedResponse(
                    statusCode: 200,
                    headers: [HeaderPair(name: "Content-Type", value: "image/jpeg")],
                    body: binary
                ),
                at: Date(timeIntervalSince1970: 0)
            )
        )
        let json = try decode(HARExport.encode([flow], appVersion: "1"))
        let entry = try #require((json["log"] as? [String: Any])?["entries"] as? [[String: Any]]).first
        let content = try #require((entry?["response"] as? [String: Any])?["content"] as? [String: Any])
        #expect(content["encoding"] as? String == "base64")
        #expect(content["text"] as? String == binary.base64EncodedString())
        #expect(content["size"] as? Int == binary.count)
    }

    @Test func encode_inFlightFlow_hasEmptyResponse() throws {
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "http://x.test/", headers: [], body: nil),
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let json = try decode(HARExport.encode([flow], appVersion: "1"))
        let entry = try #require((json["log"] as? [String: Any])?["entries"] as? [[String: Any]]).first
        #expect((entry?["response"] as? [String: Any])?["status"] as? Int == 0)
    }

    @Test func encode_sortsByStartedAt() throws {
        let older = Flow(id: UUID(), request: CapturedRequest(method: "GET", url: "http://a/", headers: []), startedAt: Date(timeIntervalSince1970: 1))
        let newer = Flow(id: UUID(), request: CapturedRequest(method: "GET", url: "http://b/", headers: []), startedAt: Date(timeIntervalSince1970: 2))
        let json = try decode(HARExport.encode([newer, older], appVersion: "1"))
        let entries = try #require((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        #expect((entries.first?["request"] as? [String: Any])?["url"] as? String == "http://a/")
        #expect((entries.last?["request"] as? [String: Any])?["url"] as? String == "http://b/")
    }
}
