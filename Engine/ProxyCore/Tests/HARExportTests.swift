import XCTest
import SharedModels

final class HARExportTests: XCTestCase {
    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_encode_producesValidHARStructure() throws {
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(
                method: "POST",
                url: "https://api.example.test/v1/home?x=1&y=2",
                headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                body: Data(#"{"a":1}"#.utf8)
            ),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HeaderPair(name: "Content-Type", value: "application/json")],
                body: Data(#"{"ok":true}"#.utf8)
            ),
            startedAt: Date(timeIntervalSince1970: 1_000),
            completedAt: Date(timeIntervalSince1970: 1_000.25),
            appliedRules: ["mock home"]
        )

        let json = try decode(HARExport.encode([flow], appVersion: "9.9"))
        let log = try XCTUnwrap(json["log"] as? [String: Any])
        XCTAssertEqual(log["version"] as? String, "1.2")
        XCTAssertEqual((log["creator"] as? [String: Any])?["name"] as? String, "Loom")

        let entries = try XCTUnwrap(log["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertEqual(entry["time"] as? Int, 250)
        XCTAssertEqual(entry["_appliedRules"] as? [String], ["mock home"])

        let request = try XCTUnwrap(entry["request"] as? [String: Any])
        XCTAssertEqual(request["method"] as? String, "POST")
        XCTAssertEqual(request["url"] as? String, "https://api.example.test/v1/home?x=1&y=2")
        XCTAssertEqual((request["queryString"] as? [[String: String]])?.count, 2)
        XCTAssertEqual((request["postData"] as? [String: Any])?["text"] as? String, #"{"a":1}"#)

        let response = try XCTUnwrap(entry["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 200)
        XCTAssertEqual((response["content"] as? [String: Any])?["text"] as? String, #"{"ok":true}"#)
    }

    func test_encode_binaryBody_isBase64NotDropped() throws {
        // Regression: a non-UTF-8 body used to vanish from the export entirely.
        let binary = Data([0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02]) // not valid UTF-8
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "http://x.test/img", headers: []),
            response: CapturedResponse(
                statusCode: 200,
                headers: [HeaderPair(name: "Content-Type", value: "image/jpeg")],
                body: binary
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 0)
        )
        let json = try decode(HARExport.encode([flow], appVersion: "1"))
        let entry = try XCTUnwrap((json["log"] as? [String: Any])?["entries"] as? [[String: Any]]).first
        let content = try XCTUnwrap((entry?["response"] as? [String: Any])?["content"] as? [String: Any])
        XCTAssertEqual(content["encoding"] as? String, "base64")
        XCTAssertEqual(content["text"] as? String, binary.base64EncodedString())
        XCTAssertEqual(content["size"] as? Int, binary.count)
    }

    func test_encode_inFlightFlow_hasEmptyResponse() throws {
        let flow = Flow(
            id: UUID(),
            request: CapturedRequest(method: "GET", url: "http://x.test/", headers: [], body: nil),
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let json = try decode(HARExport.encode([flow], appVersion: "1"))
        let entry = try XCTUnwrap((json["log"] as? [String: Any])?["entries"] as? [[String: Any]]).first
        XCTAssertEqual((entry?["response"] as? [String: Any])?["status"] as? Int, 0)
    }

    func test_encode_sortsByStartedAt() throws {
        let older = Flow(id: UUID(), request: CapturedRequest(method: "GET", url: "http://a/", headers: []), startedAt: Date(timeIntervalSince1970: 1))
        let newer = Flow(id: UUID(), request: CapturedRequest(method: "GET", url: "http://b/", headers: []), startedAt: Date(timeIntervalSince1970: 2))
        let json = try decode(HARExport.encode([newer, older], appVersion: "1"))
        let entries = try XCTUnwrap((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertEqual((entries.first?["request"] as? [String: Any])?["url"] as? String, "http://a/")
        XCTAssertEqual((entries.last?["request"] as? [String: Any])?["url"] as? String, "http://b/")
    }
}
