import Foundation

struct ReaderAITavilyConfig: Codable, Equatable, Sendable {
    static let defaultAddress = "https://api.tavily.com/search"
    static let topics = ["general", "news", "finance"]
    static let depths = ["basic", "advanced", "ultra-fast"]
    static let resultRange = 1...10

    var enabled = false
    var key = ""
    var address = Self.defaultAddress
    var topic = "general"
    var depth = "basic"
    var maxResults = 5

    func validatedEndpoint() throws -> URL {
        let configured = address.aiTrimmed.isEmpty ? Self.defaultAddress : address.aiTrimmed
        guard var parts = URLComponents(string: configured), parts.scheme?.lowercased() == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil, parts.fragment == nil else {
            throw ReaderAITavilyError.invalidAddress
        }
        var path = parts.percentEncodedPath
        while path.last == "/" { path.removeLast() }
        parts.percentEncodedPath = path.hasSuffix("/search") ? path : path + "/search"
        guard let endpoint = parts.url else { throw ReaderAITavilyError.invalidAddress }
        return endpoint
    }

    func validateKey() throws {
        guard key.aiTrimmed.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw ReaderAITavilyError.invalidKey
        }
    }
}

enum ReaderAITavily {
    static let name = "search_web_tavily"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration, delegate: TavilyRedirectPolicy(), delegateQueue: nil)
    }()

    static func tool(for config: ReaderAITavilyConfig) -> ReaderAITool? {
        let key = config.key.aiTrimmed
        guard config.enabled, !key.isEmpty,
              (try? config.validateKey()) != nil, let url = try? config.validatedEndpoint() else { return nil }
        return ReaderAITool(
            name: name,
            description: "使用 Tavily 搜索公开网页，返回答案摘要、来源链接和内容片段。",
            parameters: [
                "type": "object", "required": ["query"], "additionalProperties": false,
                "properties": [
                    "query": ["type": "string", "description": "要搜索的问题或关键词。"],
                    "topic": ["type": "string", "enum": ReaderAITavilyConfig.topics],
                    "searchDepth": ["type": "string", "enum": ReaderAITavilyConfig.depths],
                    "maxResults": ["type": "integer", "minimum": 1, "maximum": 10],
                    "includeDomains": ["type": "array", "items": ["type": "string"]],
                    "excludeDomains": ["type": "array", "items": ["type": "string"]],
                    "includeAnswer": ["type": "boolean"]
                ]
            ],
            invoke: { arguments in try await search(arguments, config: config, url: url, key: key) }
        )
    }

    private static func search(_ arguments: String, config: ReaderAITavilyConfig, url: URL, key: String) async throws -> String {
        guard arguments.utf8.count <= 64 * 1024, let arguments = object(Data(arguments.utf8)),
              let query = (arguments["query"] as? String)?.aiTrimmed, (1...1024).contains(query.count) else {
            throw ReaderAITavilyError.invalidQuery
        }
        let topics = ReaderAITavilyConfig.topics
        let depths = ReaderAITavilyConfig.depths
        let topic = [arguments["topic"] as? String, config.topic].compactMap { $0 }
            .first(where: topics.contains) ?? "general"
        let depth = [arguments["searchDepth"] as? String, config.depth].compactMap { $0 }
            .first(where: depths.contains) ?? "basic"
        let range = ReaderAITavilyConfig.resultRange
        let count = min(range.upperBound, max(range.lowerBound, arguments["maxResults"] as? Int ?? config.maxResults))
        var body: [String: Any] = [
            "query": query, "topic": topic, "search_depth": depth, "max_results": count,
            "include_answer": arguments["includeAnswer"] as? Bool ?? true, "include_raw_content": false
        ]
        for (field, parameter) in [("includeDomains", "include_domains"), ("excludeDomains", "exclude_domains")] {
            let list = (arguments[field] as? [String] ?? []).map(\.aiTrimmed)
                .filter { !$0.isEmpty && $0.count <= 253 }.prefix(30)
            if !list.isEmpty { body[parameter] = Array(list) }
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let querySecrets: [String] = queryItems.compactMap { item in
            let name = item.name.lowercased()
            let sensitive = ["token", "key", "secret", "auth"].contains { name.contains($0) }
            return sensitive ? item.value : nil
        }
        let knownSecrets = ([url.absoluteString, config.address.aiTrimmed, key] + querySecrets).filter { !$0.isEmpty }
        func sanitized(_ text: String, limit: Int) -> String {
            let cleaned = knownSecrets.reduce(text) { value, secret in value.replacingOccurrences(of: secret, with: "••••") }
            return String(cleaned.prefix(limit))
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw ReaderAITavilyError.invalidResponse }
            let succeeded = (200..<300).contains(http.statusCode)
            let limit = succeeded ? 1024 * 1024 : 16 * 1024
            if succeeded, response.expectedContentLength > limit { throw ReaderAITavilyError.oversizedResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else {
                    if succeeded { throw ReaderAITavilyError.oversizedResponse }
                    break
                }
                data.append(byte)
            }
            try Task.checkCancellation()
            let payload = object(data)
            guard succeeded else {
                let detail = errorMessage(in: payload).map { sanitized($0, limit: 240) }
                throw ReaderAITavilyError.http(http.statusCode, detail)
            }
            guard let payload, let results = payload["results"] as? [[String: Any]] else {
                throw ReaderAITavilyError.invalidResponse
            }
            let hits: [[String: Any]] = results.prefix(count).compactMap { result in
                guard let raw = result["url"] as? String, let source = URL(string: raw),
                      let scheme = source.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      source.host?.isEmpty == false, source.user == nil, source.password == nil else { return nil }
                var item: [String: Any] = [
                    "url": sanitized(raw, limit: 2048),
                    "title": sanitized(result["title"] as? String ?? "", limit: 360),
                    "content": sanitized(result["content"] as? String ?? "", limit: 1800)
                ]
                if let score = result["score"] as? Double { item["score"] = score }
                if let date = result["published_date"] as? String { item["publishedDate"] = sanitized(date, limit: 128) }
                return item
            }
            var result: [String: Any] = ["ok": true, "query": sanitized(query, limit: 1024), "results": hits]
            if let answer = payload["answer"] as? String { result["answer"] = sanitized(answer, limit: 2500) }
            if let time = payload["response_time"] as? Double {
                result["responseTime"] = time
            } else if let raw = payload["response_time"] as? String, let time = Double(raw), time.isFinite {
                result["responseTime"] = time
            }
            return try ReaderAITool.json(result)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw ReaderAITavilyError.connection(error.code.rawValue)
        }
    }

    private static func errorMessage(in payload: [String: Any]?) -> String? {
        let detail = payload?["detail"]
        return (detail as? [String: Any])?["error"] as? String
            ?? (payload?["error"] as? [String: Any])?["message"] as? String
            ?? detail as? String
            ?? payload?["message"] as? String
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private final class TavilyRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let from = task.originalRequest?.url, let to = request.url,
              to.scheme?.lowercased() == "https", to.user == nil, to.password == nil,
              ReaderAIEndpoint.sameOrigin(from, to), request.httpMethod == "POST" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private enum ReaderAITavilyError: LocalizedError {
    case invalidAddress, invalidKey, invalidQuery, invalidResponse, oversizedResponse
    case http(Int, String?), connection(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请填写有效的 Tavily HTTPS 接口地址。"
        case .invalidKey: "Tavily API Key 不能包含空格或换行。"
        case .invalidQuery: "Tavily 搜索需要 1 到 1024 字的关键词。"
        case .invalidResponse: "Tavily 未返回有效的搜索结果。"
        case .oversizedResponse: "Tavily 返回的数据超过 1 MB。"
        case .http(401, _), .http(403, _): "Tavily 拒绝了授权，请核对 API Key 和权限。"
        case .http(429, _): "Tavily 请求过于频繁，请稍后再试。"
        case .http(let code, let detail): ["Tavily HTTP \(code)", detail].compactMap { $0 }.joined(separator: " · ")
        case .connection(let code): "无法连接 Tavily（\(code)）。"
        }
    }
}
