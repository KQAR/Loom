import Foundation

// loom-mcp: a stdio <-> HTTP bridge. AI clients (Claude Desktop, Cursor) launch
// this binary and speak MCP JSON-RPC over stdio; it forwards each line to the
// Loom app's local HTTP MCP endpoint and streams the reply back. All logic and
// data live in the app — this process is intentionally tiny and stateless.
//
// One request at a time, on purpose: the read loop blocks on each reply, so a
// blocking tool (`wait_for_flow`) holds the bridge until it answers. That matches
// how a client drives it — one JSON-RPC call per turn — and keeps this process free
// of any state to reconcile. Clients that pipeline should use the HTTP endpoint
// directly (the app serves those concurrently).

let appSupportDirectoryName = "com.loom"

struct Handshake: Decodable {
    let token: String
    let port: Int
}

func readHandshake() -> Handshake? {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = base
        .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
        .appendingPathComponent("mcp-handshake.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Handshake.self, from: data)
}

/// Mirror the body fields that the Streamable HTTP transport carries in headers.
///
/// This is the one piece of protocol the bridge cannot avoid knowing. stdio has no
/// headers — a modern (`2026-07-28`) client puts the protocol version in `_meta` and
/// nothing else — but the HTTP endpoint on the other side **requires**
/// `MCP-Protocol-Version`, `Mcp-Method` and (for `tools/call`) `Mcp-Name` to be
/// present and to agree with the body, and answers `-32020 HeaderMismatch` when they
/// don't. Translating between the two bindings is exactly what a transport bridge is
/// for; without this, every modern request over stdio would be rejected.
///
/// A legacy request has no `_meta` protocol version, so nothing is mirrored and the
/// server serves it under legacy rules — the behaviour this bridge has always had.
func mirroredHeaders(for line: Data) -> [String: String] {
    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          let method = message["method"] as? String
    else { return [:] }
    let params = message["params"] as? [String: Any] ?? [:]
    let meta = params["_meta"] as? [String: Any] ?? [:]
    guard let version = meta["io.modelcontextprotocol/protocolVersion"] as? String else { return [:] }

    var headers = ["MCP-Protocol-Version": version, "Mcp-Method": method]
    // `Mcp-Name` mirrors `params.name` (tools/call, prompts/get) or `params.uri`
    // (resources/read); Loom only serves the first, but mirroring whichever is present
    // keeps the bridge correct if the server grows the others.
    if let name = (params["name"] as? String) ?? (params["uri"] as? String) {
        headers["Mcp-Name"] = headerSafe(name)
    }
    return headers
}

/// A header value must be visible ASCII. Anything else travels in the spec's Base64
/// sentinel, which the server decodes before comparing it to the body. A value that
/// merely *looks* like the sentinel is encoded too, so it can't be mistaken for one.
func headerSafe(_ value: String) -> String {
    let needsEncoding = value.unicodeScalars.contains { $0.value < 0x21 || $0.value > 0x7E }
        || value != value.trimmingCharacters(in: .whitespaces)
        || (value.hasPrefix("=?base64?") && value.hasSuffix("?="))
    guard needsEncoding else { return value }
    return "=?base64?\(Data(value.utf8).base64EncodedString())?="
}

func post(line: Data, handshake: Handshake) -> Data? {
    guard let url = URL(string: "http://127.0.0.1:\(handshake.port)/mcp") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(handshake.token)", forHTTPHeaderField: "Authorization")
    for (name, value) in mirroredHeaders(for: line) {
        request.setValue(value, forHTTPHeaderField: name)
    }
    request.httpBody = line
    // URLSession defaults to a 60 s request timeout, which the blocking tools
    // (`wait_for_flow`, `wait_for_pending`) can legitimately sit inside — a wait that
    // the app is still holding must not be torn down here as a transport failure. The
    // app caps its own waits well below this, so a request that actually reaches it
    // always answers first; this bound only exists so a wedged app can't hang the
    // bridge forever.
    request.timeoutInterval = 300

    let semaphore = DispatchSemaphore(value: 0)
    var result: Data?
    var status = 0
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        result = data
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    // 202 (notifications) has no body and expects no stdout line.
    return status == 202 ? nil : result
}

func writeStdout(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ message: String) {
    FileHandle.standardError.write(Data("loom-mcp: \(message)\n".utf8))
}

guard let handshake = readHandshake() else {
    fail("handshake not found — is the Loom app running with the MCP server enabled?")
    exit(1)
}

// Newline-delimited JSON-RPC over stdin.
var buffer = Data()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    buffer.append(chunk)

    while let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        let trimmed = lineData.trimmingTrailingWhitespace()
        guard !trimmed.isEmpty else { continue }
        if let response = post(line: trimmed, handshake: handshake) {
            writeStdout(response)
        }
    }
}

private extension Data {
    func trimmingTrailingWhitespace() -> Data {
        var end = endIndex
        while end > startIndex {
            let byte = self[index(before: end)]
            if byte == 0x20 || byte == 0x0D || byte == 0x0A || byte == 0x09 {
                end = index(before: end)
            } else {
                break
            }
        }
        return subdata(in: startIndex..<end)
    }
}
