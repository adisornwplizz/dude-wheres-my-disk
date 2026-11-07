import Foundation

private struct CatalogPage: Decodable {
    struct Model: Decodable {
        let id: String
        let lifecycle: String?
        let input_modalities: [String]?
        let output_modalities: [String]?
    }

    let data: [Model]
    let has_more: Bool?
    let last_id: String?
}

extension AIClient {
    static func listModels(provider: AIProvider, key: String) async throws -> [String] {
        let session: URLSession
        if provider == .ollama {
            session = OllamaLocal.makeSession()
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 40
            session = URLSession(configuration: config, delegate: FixedEndpoint(), delegateQueue: nil)
        }
        defer { session.invalidateAndCancel() }
        return try await listModels(provider: provider, key: key, session: session)
    }

    static func listModels(provider: AIProvider, key: String, session: URLSession) async throws -> [String] {
        try Task.checkCancellation()
        let endpoint: URL
        switch provider {
        case .ollama: return try await OllamaLocal.models(session: session)
        case .openAI: endpoint = URL(string: "https://api.openai.com/v1/models")!
        case .anthropic: endpoint = URL(string: "https://api.anthropic.com/v1/models")!
        case .deepSeek: endpoint = URL(string: "https://api.deepseek.com/models")!
        }
        guard !key.isEmpty, key.utf8.count <= 4096, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw AIRequestError("Save a valid API key for this provider before connecting.")
        }

        var ids: Set<String> = []
        var cursors: Set<String> = []
        var url = endpoint
        for _ in 0..<20 {
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            if provider == .anthropic { request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version") }
            let page = try await catalogPage(request, session: session)
            for model in page.data {
                let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, id.utf8.count <= 200, !id.contains(key),
                      id.utf8.allSatisfy({ (33...126).contains($0) }),
                      model.lifecycle != "retired", model.input_modalities?.contains("text") != false,
                      model.output_modalities?.contains("text") != false else { continue }
                ids.insert(id)
            }
            guard provider == .anthropic && page.has_more == true else { return ids.sorted() }
            guard let next = page.last_id, !next.isEmpty, next.utf8.count <= 200,
                  cursors.insert(next).inserted else { throw AIRequestError("The provider returned an invalid page cursor.") }
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "after_id", value: next)]
            url = components.url!
        }
        throw AIRequestError("The provider’s model catalog exceeds the page limit.")
    }

    private static func catalogPage(_ request: URLRequest, session: URLSession) async throws -> CatalogPage {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw AIRequestError("Unexpected model catalog destination.")
            }
            guard (200..<300).contains(http.statusCode) else { throw AIRequestError(status: http.statusCode) }
            let limit = 1024 * 1024
            guard http.expectedContentLength <= limit else { throw AIRequestError("Model catalog exceeds the size limit.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw AIRequestError("Model catalog exceeds the size limit.") }
                data.append(byte)
            }
            return try JSONDecoder().decode(CatalogPage.self, from: data)
        } catch let error as AIRequestError {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw AIRequestError("Could not load the provider’s model catalog. Check the connection and try again.")
        }
    }
}
