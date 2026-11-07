import Foundation

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private final class FixtureProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let responder = Self.respond, let url = request.url else { throw Failure("Missing fixture") }
            let (status, data) = try responder(request)
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            FileHandle.standardError.write(Data(("Fixture transport failed: " + error.localizedDescription + "\n").utf8))
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@main
private struct VerifyProvider {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let key = "dummy-fixture-credential"
        let evidence = "{\"decision\":\"keep\",\"active\":true}"
        let answer = "เก็บ worktree นี้ไว้เพราะยังมีโปรเซสใช้งาน"
        for provider in AIProvider.allCases where provider.requiresKey {
            FixtureProtocol.respond = { request in
                func expect(_ condition: Bool, _ text: String) throws { if !condition { throw Failure(text) } }
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key, "Missing provider authorization")
                try expect(request.httpMethod == "POST" && request.url?.scheme == "https", "Unexpected transport")
                let requestData: Data?
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var bytes = Data()
                    var chunk = [UInt8](repeating: 0, count: 1024)
                    while true {
                        let count = stream.read(&chunk, maxLength: chunk.count)
                        if count < 0 { throw Failure("Unreadable fixture request") }
                        if count == 0 { break }
                        bytes.append(contentsOf: chunk.prefix(count))
                    }
                    requestData = bytes
                } else {
                    requestData = request.httpBody
                }
                guard let data = requestData,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      body["model"] as? String == provider.defaultModel, body["tools"] == nil else { throw Failure("Bad request body") }
                let output: [String: Any]
                switch provider {
                case .ollama: throw Failure("Unexpected Ollama request from cloud test")
                case .openAI:
                    try expect(request.url?.absoluteString == "https://api.openai.com/v1/responses", "Wrong OpenAI endpoint")
                    try expect(body["store"] as? Bool == false && (body["input"] as? [[String: String]])?.last?["content"] == evidence, "Incorrect Responses input")
                    output = ["status": "completed", "output": [["type": "reasoning"],
                              ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": answer]]]]]
                case .anthropic:
                    try expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Wrong Claude endpoint")
                    try expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21", "Missing API version")
                    try expect((body["messages"] as? [[String: String]])?.first?["content"] == evidence && body["system"] is String, "Incorrect Messages input")
                    output = ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": "internal"],
                              ["type": "text", "text": answer]]]
                case .deepSeek:
                    try expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions", "Wrong DeepSeek endpoint")
                    let messages = body["messages"] as? [[String: String]]
                    try expect(messages?.first?["role"] == "system" && messages?.last?["content"] == evidence, "Incorrect Chat Completions input")
                    output = ["choices": [["finish_reason": "stop", "message": ["reasoning_content": "internal", "content": answer]]]]
                }
                return (200, try JSONSerialization.data(withJSONObject: output))
            }
            let result = try await AIClient.analyze(provider: provider, model: provider.defaultModel, key: key,
                                                    evidence: evidence, session: session)
            if result != answer { throw Failure("Wrong explanation") }
        }
        try await verifyLocal(session: session, evidence: evidence, answer: answer)
        for (status, data) in [
            (401, Data(key.utf8)),
            (429, Data(key.utf8)),
            (200, Data("broken".utf8)),
            (200, Data(#"{"status":"incomplete","output":[]}"#.utf8)),
            (200, Data(repeating: 65, count: 135_000)),
        ] {
            FixtureProtocol.respond = { _ in (status, data) }
            var errorMessage: String?
            do {
                _ = try await AIClient.analyze(provider: .openAI, model: AIProvider.openAI.defaultModel, key: key,
                                               evidence: evidence, session: session)
            } catch {
                errorMessage = error.localizedDescription
            }
            guard let errorMessage, !errorMessage.contains(key) else { throw Failure("Missing or unsanitized provider error") }
        }
        print("Verified local-only Ollama, three HTTPS API adapters, evidence-only request bodies, text extraction and bounded error handling with intercepted requests.")
    }
    static func verifyLocal(session: URLSession, evidence: String, answer: String) async throws {
        let uploaded = Data(evidence.utf8)
        let good = "fixture:q4"
        let local: [String: Any] = ["name": good, "details": ["format": "gguf"], "capabilities": ["completion"]]
        var remote = local
        remote["name"] = "friendly-alias"
        remote["remote_host"] = "https://invalid.example"
        var embedding = local
        embedding["name"] = "vectors"
        embedding["capabilities"] = ["embedding"]
        var cloud = local
        cloud["name"] = "fixture:cloud"
        let records = [cloud, remote, embedding, local]
        var chatCalls = 0
        var remoteAtShow = false
        FixtureProtocol.respond = { request in
            guard request.url?.host == "127.0.0.1", request.url?.port == 11434,
                  request.value(forHTTPHeaderField: "Authorization") == nil,
                  request.value(forHTTPHeaderField: "x-api-key") == nil else { throw Failure("Local request leaked credentials or used a non-loopback endpoint") }
            let output: [String: Any]
            switch request.url?.path {
            case "/api/tags":
                guard request.httpMethod == "GET" else { throw Failure("Expected local model list") }
                output = ["models": records]
            case "/api/show", "/api/chat":
                let data: Data
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count >= 0 else { throw Failure("Invalid request stream") }
                    data = Data(bytes.prefix(count))
                } else { data = request.httpBody ?? Data() }
                guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      body["model"] as? String == good + ":local" else { throw Failure("Missing explicit local-only source") }
                if request.url?.path == "/api/show" {
                    guard body.count == 1, data.range(of: uploaded) == nil else { throw Failure("Evidence included in metadata request") }
                    output = remoteAtShow ? remote : local
                } else {
                    chatCalls += 1
                    guard body["stream"] as? Bool == false,
                          (body["messages"] as? [[String: String]])?.last?["content"] == evidence else { throw Failure("Bad local chat request") }
                    output = ["done": true, "done_reason": "stop", "message": ["role": "assistant", "content": answer]]
                }
            default: throw Failure("Unexpected Ollama API call")
            }
            return (200, try JSONSerialization.data(withJSONObject: output))
        }
        guard AIProvider.allCases.first == .ollama, !AIProvider.ollama.requiresKey,
              try await OllamaLocal.models(session: session) == [good] else { throw Failure("Unsafe or missing local choices") }
        let response = try await AIClient.analyze(provider: .ollama, model: good, key: "", evidence: evidence, session: session)
        guard response == answer, chatCalls == 1 else { throw Failure("Local explanation missing") }
        remoteAtShow = true
        do {
            _ = try await AIClient.analyze(provider: .ollama, model: good, key: "", evidence: evidence, session: session)
            throw Failure("Accepted remote alias")
        } catch let unexpected as Failure { throw unexpected }
        catch { guard chatCalls == 1 else { throw Failure("Sent evidence for remote model") } }
        do {
            _ = try await AIClient.analyze(provider: .ollama, model: "missing", key: "", evidence: evidence, session: session)
            throw Failure("Accepted a model absent from tags")
        } catch let unexpected as Failure { throw unexpected }
        catch { guard chatCalls == 1 else { throw Failure("Sent evidence for model absent from tags") } }
    }

}
