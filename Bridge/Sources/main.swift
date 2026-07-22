import Foundation

// loom-mcp: a stdio <-> HTTP bridge. AI clients (Claude Desktop, Cursor) launch
// this binary and speak MCP JSON-RPC over stdio; it forwards each line to the
// Loom app's local HTTP MCP endpoint and streams the reply back. All logic and
// data live in the app — this process is intentionally tiny and stateless.

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

func post(line: Data, handshake: Handshake) -> Data? {
    guard let url = URL(string: "http://127.0.0.1:\(handshake.port)/mcp") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(handshake.token)", forHTTPHeaderField: "Authorization")
    request.httpBody = line

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
