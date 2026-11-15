import Foundation

enum ReaderAIClient {
    private static let apiSession = session(forMedia: false)
    private static let mediaSession = session(forMedia: true)
    private static let textLimit = 8 * 1024 * 1024
    private static let imageLimit = 32 * 1024 * 1024
    private static let imageResponseLimit = 48 * 1024 * 1024

    static func models(provider: ReaderAIProvider) async throws -> [String] {
        let request = try request(
            address: provider.address, route: "models", key: provider.key, headers: provider.headers, timeout: 30
        )
        let payload = try await read(request, limit: textLimit)
        guard let models = object(payload)?["data"] as? [[String: Any]] else {
            throw ReaderAIError.emptyResponse
        }
        var seen = Set<String>()
        return models.compactMap { ($0["id"] as? String)?.aiTrimmed }.filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    static func chat(
        messages: [ReaderAIChatMessage], using choice: ReaderAIModelChoice,
        onDelta: @MainActor (String) -> Void = { _ in }
    ) async throws -> String {
        guard !choice.model.isEmpty else { throw ReaderAIError.missingSettings }
        let provider = choice.provider
        let fields = messages.filter { !$0.content.aiTrimmed.isEmpty }.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        let inputKey = provider.apiMode == .responses ? "input" : "messages"
        var body: [String: Any] = ["model": choice.model, "stream": true, inputKey: fields]
        if provider.promptCache {
            body["prompt_cache_key"] = String("legado-reader-\(choice.id)".prefix(64))
        }
        let request = try request(
            address: provider.address, route: provider.apiMode.route, key: provider.key, headers: provider.headers,
            timeout: 300, body: body, accept: "text/event-stream, application/json"
        )
        let (bytes, response) = try await open(request)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= textLimit else { throw ReaderAIError.oversizedResponse }
        if response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true {
            return try await readStream(bytes, request: request, onDelta: onDelta)
        }

        let payload = try await readBytes(bytes, limit: textLimit)
        var result = ChatStream()
        if let object = object(payload) {
            if let delta = try result.consume(object, redacting: request) { await onDelta(delta) }
        } else if let content = String(data: payload, encoding: .utf8) {
            // Some compatible gateways respond with an event stream labelled as JSON or text.
            for line in content.components(separatedBy: "\n") {
                if let delta = try result.line(line, redacting: request) { await onDelta(delta) }
            }
            if let delta = try result.line("", redacting: request) { await onDelta(delta) }
        }
        return try result.answer()
    }

    static func generateImage(prompt: String, provider: ReaderAIImageProvider) async throws -> Data {
        let params = try provider.parameters()
        let usesResponses = provider.usesResponses(parameters: params)
        let model = provider.resolvedModel(parameters: params)
        let effectivePrompt = [provider.stylePrompt.aiTrimmed, prompt.aiTrimmed].filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !effectivePrompt.isEmpty else { throw ReaderAIError.emptyResponse }

        let route: String
        let body: [String: Any]
        if usesResponses {
            route = "responses"
            var tool: [String: Any] = ["type": "image_generation"]
            tool.merge(params["tool"] as? [String: Any] ?? [:]) { _, new in new }
            let reserved: Set<String> = ["endpoint", "model", "input", "tools", "stream", "response", "tool", "type"]
            tool.merge(params.filter { !reserved.contains($0.key) }) { _, new in new }
            tool["type"] = "image_generation"
            var payload: [String: Any] = ["model": model, "input": effectivePrompt, "tools": [tool]]
            let extra = params["response"] as? [String: Any] ?? [:]
            payload.merge(extra.filter { !["model", "input", "tools", "stream"].contains($0.key) }) { _, new in new }
            body = payload
        } else {
            route = "images/generations"
            var payload: [String: Any] = [
                "model": model, "prompt": effectivePrompt, "n": 1, "size": "1024x1024"
            ]
            payload.merge(params.filter { !["endpoint", "model", "prompt"].contains($0.key) }) { _, new in new }
            body = payload
        }

        let timeout = TimeInterval(max(60_000, min(600_000, provider.timeoutMilliseconds))) / 1_000
        let request = try request(
            address: provider.address, route: route, key: provider.key, headers: provider.headers,
            timeout: timeout, body: body
        )
        let payload = try await read(request, limit: imageResponseLimit)
        if let result = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) {
            if let error = serviceError(in: result as? [String: Any] ?? [:], request: request) {
                throw ReaderAIError.provider(error)
            }
            if let source = imageSource(in: result) {
                switch source {
                case .data(let image): return image
                case .url(let url):
                    var download = URLRequest(url: url, timeoutInterval: timeout)
                    download.setValue("image/*", forHTTPHeaderField: "Accept")
                    let image = try await read(download, limit: imageLimit, forMedia: true)
                    guard isImage(image) else { throw ReaderAIError.emptyResponse }
                    return image
                }
            }
        }
        if payload.count <= imageLimit, isImage(payload) { return payload }
        throw ReaderAIError.emptyResponse
    }

    private static func request(
        address: String, route: String, key: String, headers: String, timeout: TimeInterval,
        body: [String: Any]? = nil, accept: String = "application/json"
    ) throws -> URLRequest {
        let url = try ReaderAIEndpoint.make(address, route: route)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let key = key.aiTrimmed
        if !key.isEmpty {
            guard !key.contains(where: { $0.isNewline }), !key.utf8.contains(0) else {
                throw ReaderAIError.invalidHeaders
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let transportHeaders: Set<String> = ["host", "content-length", "transfer-encoding", "connection"]
        for (name, value) in try ReaderAIHeaders.parse(headers) where !transportHeaders.contains(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static func open(
        _ request: URLRequest, forMedia: Bool = false
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await (forMedia ? mediaSession : apiSession).bytes(for: request)
        } catch let failure as URLError {
            if failure.code == .cancelled { throw CancellationError() }
            throw ReaderAIError.connection(
                host: request.url?.host ?? "AI 服务", code: failure.code.rawValue, detail: failure.localizedDescription
            )
        }
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ReaderAIError.emptyResponse
        }
        if !(200..<300).contains(response.statusCode) {
            defer { bytes.task.cancel() }
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count >= 16_384 { break }
            }
            let detail = object(errorBody).flatMap { serviceError(in: $0, request: request, allowTopLevelMessage: true) }
            throw ReaderAIError.http(response.statusCode, detail)
        }
        return (bytes, response)
    }

    private static func read(_ request: URLRequest, limit: Int, forMedia: Bool = false) async throws -> Data {
        let (bytes, response) = try await open(request, forMedia: forMedia)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= limit else { throw ReaderAIError.oversizedResponse }
        return try await readBytes(bytes, limit: limit)
    }

    private static func readBytes(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ReaderAIError.oversizedResponse }
            data.append(byte)
        }
        return data
    }

    private static func readStream(
        _ bytes: URLSession.AsyncBytes, request: URLRequest, onDelta: @MainActor (String) -> Void
    ) async throws -> String {
        var stream = ChatStream()
        var line = [UInt8]()
        var count = 0
        for try await byte in bytes {
            count += 1
            guard count <= textLimit else { throw ReaderAIError.oversizedResponse }
            if byte == 10 {
                if let delta = try stream.line(String(decoding: line, as: UTF8.self), redacting: request) {
                    await onDelta(delta)
                }
                if stream.finished { return try stream.answer() }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if let delta = try stream.line(String(decoding: line, as: UTF8.self), redacting: request) { await onDelta(delta) }
        if let delta = try stream.line("", redacting: request) { await onDelta(delta) }
        return try stream.answer()
    }

    private struct ChatStream {
        private var text = ""
        private var pending = ""
        private(set) var finished = false

        mutating func line(_ raw: String, redacting request: URLRequest) throws -> String? {
            let line = raw.aiTrimmed
            if line.isEmpty {
                guard !pending.isEmpty else { return nil }
                let event = object(Data(pending.utf8))
                pending.removeAll(keepingCapacity: true)
                return try event.flatMap { try consume($0, redacting: request) }
            }
            let payload: String
            if line.hasPrefix("data:") {
                payload = String(line.dropFirst(5)).aiTrimmed
            } else if line.hasPrefix("{") {
                payload = line
            } else {
                return nil
            }
            if payload == "[DONE]" {
                finished = true
                return nil
            }
            if pending.isEmpty, let event = object(Data(payload.utf8)) {
                return try consume(event, redacting: request)
            }
            if !pending.isEmpty { pending.append("\n") }
            pending.append(payload)
            if let event = object(Data(pending.utf8)) {
                pending.removeAll(keepingCapacity: true)
                return try consume(event, redacting: request)
            }
            return nil
        }

        mutating func consume(_ event: [String: Any], redacting request: URLRequest) throws -> String? {
            if finished { return nil }
            if let problem = serviceError(in: event, request: request) {
                throw ReaderAIError.provider(problem)
            }
            if let errorObject = event["response"] as? [String: Any],
               let problem = serviceError(in: errorObject, request: request) {
                throw ReaderAIError.provider(problem)
            }

            let fragment: String?
            switch event["type"] as? String {
            case "response.output_text.delta":
                fragment = event["delta"] as? String
            case "response.completed", "response.incomplete":
                finished = true
                let result = event["response"] as? [String: Any] ?? event
                fragment = suffix(of: responseText(result))
            case "response.failed", "error":
                let message = serviceError(in: event, request: request, allowTopLevelMessage: true)
                throw message.map(ReaderAIError.provider) ?? ReaderAIError.emptyResponse
            default:
                let choice = (event["choices"] as? [[String: Any]])?.first
                let delta = (choice?["delta"] as? [String: Any])?["content"]
                let message = (choice?["message"] as? [String: Any])?["content"]
                fragment = contentText(delta) ?? suffix(of: contentText(message)) ?? suffix(of: responseText(event))
            }
            guard let fragment, !fragment.isEmpty else { return nil }
            text.append(fragment)
            return fragment
        }

        private func suffix(of response: String?) -> String? {
            guard let response else { return nil }
            if text.isEmpty { return response }
            guard response.hasPrefix(text) else { return nil }
            return String(response.dropFirst(text.count))
        }

        func answer() throws -> String {
            let answer = text.aiTrimmed
            guard !answer.isEmpty else { throw ReaderAIError.emptyResponse }
            return answer
        }
    }

    private static func responseText(_ object: [String: Any]) -> String? {
        if let text = object["output_text"] as? String { return text }
        let output = object["output"] as? [[String: Any]] ?? []
        let messages = output.compactMap { item -> String? in
            guard item["type"] as? String == "message" else { return nil }
            return contentText(item["content"])
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private static func contentText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let fragments = blocks.compactMap { block -> String? in
            if let text = block["text"] as? String { return text }
            return (block["text"] as? [String: Any])?["value"] as? String
        }
        return fragments.isEmpty ? nil : fragments.joined()
    }

    private enum ImageSource {
        case data(Data)
        case url(URL)
    }

    private static func imageSource(in value: Any, depth: Int = 0) -> ImageSource? {
        guard depth < 12 else { return nil }
        if let object = value as? [String: Any] {
            let names = [
                "b64_json", "base64", "b64", "url", "image_url", "imageUrl", "image", "result", "src",
                "output", "data", "images", "artifacts", "content"
            ]
            for name in names {
                if let child = object[name], let source = imageSource(in: child, depth: depth + 1) { return source }
            }
        } else if let items = value as? [Any] {
            for item in items {
                if let source = imageSource(in: item, depth: depth + 1) { return source }
            }
        } else if let text = value as? String {
            let value = text.aiTrimmed
            if let url = URL(string: value), ReaderAIEndpoint.isAllowed(url) { return .url(url) }
            if value.hasPrefix("data:image/"), let separator = value.firstIndex(of: ","),
               value[..<separator].lowercased().hasSuffix(";base64") {
                return decodeImage(String(value[value.index(after: separator)...]))
            }
            if value.hasPrefix("{") || value.hasPrefix("["),
               let nested = try? JSONSerialization.jsonObject(with: Data(value.utf8)) {
                return imageSource(in: nested, depth: depth + 1)
            }
            return decodeImage(value)
        }
        return nil
    }

    private static func decodeImage(_ value: String) -> ImageSource? {
        guard value.utf8.count <= imageResponseLimit else { return nil }
        var encoded = value.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - encoded.utf8.count % 4) % 4
        if padding > 0 { encoded += String(repeating: "=", count: padding) }
        guard let data = Data(base64Encoded: encoded), data.count <= imageLimit, isImage(data) else { return nil }
        return .data(data)
    }

    private static func isImage(_ data: Data) -> Bool {
        let header = Array(data.prefix(12))
        guard header.count >= 8 else { return false }
        return header.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
            || header.starts(with: [255, 216, 255])
            || header.starts(with: [71, 73, 70, 56])
            || (header.starts(with: [82, 73, 70, 70]) && header.dropFirst(8).elementsEqual([87, 69, 66, 80]))
            || header.dropFirst(4).prefix(4).elementsEqual([102, 116, 121, 112])
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func serviceError(
        in body: [String: Any], request: URLRequest, allowTopLevelMessage: Bool = false
    ) -> String? {
        let error = body["error"]
        let nestedMessage = (error as? [String: Any])?["message"] as? String
        guard var message = nestedMessage ?? error as? String ?? (allowTopLevelMessage ? body["message"] as? String : nil) else {
            return nil
        }
        let visibleHeaders: Set<String> = ["accept", "content-type"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where !visibleHeaders.contains(name.lowercased()) {
            if !value.isEmpty { message = message.replacingOccurrences(of: value, with: "••••") }
            if value.lowercased().hasPrefix("bearer ") {
                let token = String(value.dropFirst(7))
                if !token.isEmpty { message = message.replacingOccurrences(of: token, with: "••••") }
            }
        }
        message = String(message.aiTrimmed.prefix(480))
        return message.isEmpty ? nil : message
    }

    private static func session(forMedia: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 660
        return URLSession(configuration: configuration, delegate: RedirectPolicy(forMedia: forMedia), delegateQueue: nil)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        private let forMedia: Bool

        init(forMedia: Bool) { self.forMedia = forMedia }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let from = task.originalRequest?.url, let to = request.url, ReaderAIEndpoint.isAllowed(to) else {
                completionHandler(nil)
                return
            }
            let sameOrigin = ReaderAIEndpoint.sameOrigin(from, to)
            let safeMediaRedirect = forMedia && to.scheme?.lowercased() == "https"
            let sameMethod = task.originalRequest?.httpMethod == request.httpMethod
            completionHandler((sameOrigin || safeMediaRedirect) && sameMethod ? request : nil)
        }
    }
}
