import Foundation

private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

private func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message) }
}

private final class CatalogFixture: URLProtocol {
    static var respond: (URLRequest) throws -> (Int, Data) = { _ in throw Failure("Unexpected request") }
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        do {
            let (status, data) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
private struct VerifyCatalog {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let key = "test-fixture-catalog-credential"
        for (provider, endpoint) in [(AIProvider.openAI, "https://api.openai.com/v1/models"),
                                     (.anthropic, "https://api.anthropic.com/v1/models"),
                                     (.deepSeek, "https://api.deepseek.com/models")] {
            CatalogFixture.requests = []
            CatalogFixture.respond = { request in
                try expect(request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil,
                           "Discovery sent a request body")
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key, "Missing account key")
                if provider == .anthropic {
                    try expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21", "Missing version")
                }
                if request.url?.query != nil {
                    try expect(provider == .anthropic && request.url?.absoluteString == endpoint + "?after_id=model-b",
                               "Unexpected pagination target")
                    return (200, Data(#"{"has_more":false,"data":[{"id":"model-a"}]}"#.utf8))
                }
                try expect(request.url?.absoluteString == endpoint, "Wrong initial catalog endpoint")
                return (200, Data(#"{"has_more":true,"last_id":"model-b","data":[{"id":"model-b"},{"id":"model-b"},{"id":" "},{"id":"embedding-only","output_modalities":["vector"]}]}"#.utf8))
            }
            let models = try await AIClient.listModels(provider: provider, key: key, session: session)
            try expect(models == (provider == .anthropic ? ["model-a", "model-b"] : ["model-b"]), "Incorrect model choices")
            try expect(CatalogFixture.requests.count == (provider == .anthropic ? 2 : 1), "Wrong page count")
        }

        for (status, data) in [(401, Data(key.utf8)), (200, Data("unparseable".utf8)),
                               (200, Data(#"{"data":[],"has_more":true,"last_id":"same"}"#.utf8))] {
            CatalogFixture.respond = { _ in (status, data) }
            var failed = false
            do { _ = try await AIClient.listModels(provider: .anthropic, key: key, session: session) }
            catch {
                try expect(!error.localizedDescription.contains(key), "Provider error revealed credential")
                failed = true
            }
            try expect(failed, "Malformed or failed catalog accepted")
        }

        CatalogFixture.requests = []
        do {
            _ = try await AIClient.listModels(provider: .deepSeek, key: "", session: session)
            throw Failure("Empty key accepted")
        } catch let error as Failure { throw error }
        catch { try expect(CatalogFixture.requests.isEmpty, "Empty key reached network transport") }

        CatalogFixture.respond = { request in
            try expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/tags", "Local catalog contacted cloud")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "Local catalog received cloud credentials")
            return (200, Data(#"{"models":[]}"#.utf8))
        }
        let models = try await AIClient.listModels(provider: .ollama, key: key, session: session)
        try expect(models.isEmpty && CatalogFixture.requests.count == 1, "Local model list was not empty")
        print("Verified fixed cloud model endpoints, credential isolation, pagination, response validation and loopback discovery.")
    }
}
