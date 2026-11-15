import Foundation

struct ReaderAIMCPServer: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = ""
    var address = ""
    var key = ""
    var enabled = true

    func validatedEndpoint() throws -> URL {
        guard !name.aiTrimmed.isEmpty else { throw ReaderAIMCPError.missingName }
        guard let parts = URLComponents(string: address.aiTrimmed), parts.fragment == nil,
              let url = parts.url, ReaderAIEndpoint.isAllowed(url) else {
            throw ReaderAIMCPError.invalidEndpoint
        }
        guard key.aiTrimmed.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw ReaderAIMCPError.invalidKey
        }
        return url
    }
}

enum ReaderAIMCP {
    static func test(_ server: ReaderAIMCPServer) async throws -> Int {
        try await MCPConnection.connect(to: server).listTools().count
    }

    static func tools(for servers: [ReaderAIMCPServer]) async throws -> [ReaderAITool] {
        var tools: [ReaderAITool] = []
        var serverIDs = Set<String>()
        var aliases = Set<String>()
        for server in servers where server.enabled && serverIDs.insert(server.id).inserted {
            try Task.checkCancellation()
            let connection = try await MCPConnection.connect(to: server)
            let descriptors = try await connection.listTools()
            for descriptor in descriptors {
                let base = "mcp_\(slug(server.name, fallback: "server", limit: 16))_\(slug(descriptor.name, fallback: "tool", limit: 32))"
                var alias = base
                var suffix = 2
                while !aliases.insert(alias).inserted {
                    alias = "\(base)_\(suffix)"
                    suffix += 1
                }
                let title = descriptor.title.isEmpty ? descriptor.name : descriptor.title
                let detail = ["MCP \(server.name) · \(title)", descriptor.description]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                tools.append(ReaderAITool(
                    name: alias,
                    description: String(connection.redact(detail).prefix(1024)),
                    parameters: descriptor.schema,
                    invoke: { arguments in try await connection.call(descriptor.name, arguments: arguments) }
                ))
            }
        }
        return tools
    }

    private static func slug(_ value: String, fallback: String, limit: Int) -> String {
        let ascii = value.lowercased().utf8.map { byte in
            (97...122).contains(byte) || (48...57).contains(byte) ? byte : UInt8(95)
        }
        let parts = String(decoding: ascii, as: UTF8.self).split(separator: "_")
        return parts.isEmpty ? fallback : String(parts.joined(separator: "_").prefix(limit))
    }
}

private struct MCPConnection: Sendable {
    private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private static let payloadLimit = 1024 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 100
        return URLSession(configuration: configuration, delegate: MCPRedirectPolicy(), delegateQueue: nil)
    }()

    let endpoint: URL
    let key: String
    let protocolVersion: String?
    let sessionID: String?
    let secrets: [String]

    static func connect(to server: ReaderAIMCPServer) async throws -> Self {
        let endpoint = try server.validatedEndpoint()
        let key = server.key.aiTrimmed
        let queryItems = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let querySecrets: [String] = queryItems.compactMap { item in
            let name = item.name.lowercased()
            let sensitive = ["key", "token", "secret", "auth", "credential"].contains { name.contains($0) }
            return sensitive ? item.value : nil
        }
        let configuredSecrets = Set([server.address.aiTrimmed, endpoint.absoluteString, key] + querySecrets)
        let secrets = configuredSecrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let initial = Self(endpoint: endpoint, key: key, protocolVersion: nil, sessionID: nil, secrets: secrets)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let initialization = try await initial.request("initialize", parameters: [
            "protocolVersion": versions[0], "capabilities": [String: Any](),
            "clientInfo": ["name": "LegadoPad", "version": version]
        ], timeout: 20)
        guard let negotiated = initialization.body["protocolVersion"] as? String else {
            throw ReaderAIMCPError.invalidResponse
        }
        guard versions.contains(negotiated) else {
            throw ReaderAIMCPError.unsupportedProtocol(initial.redact(negotiated))
        }
        let sessionID = initialization.sessionID
        if let sessionID, sessionID.isEmpty || !sessionID.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) {
            throw ReaderAIMCPError.invalidResponse
        }
        let sessionSecrets = sessionID.map { (secrets + [$0]).sorted { $0.count > $1.count } } ?? secrets
        let connection = Self(
            endpoint: endpoint, key: key, protocolVersion: negotiated, sessionID: sessionID,
            secrets: sessionSecrets
        )
        try await connection.notify("notifications/initialized")
        return connection
    }

    struct Tool {
        let name: String
        let title: String
        let description: String
        let schema: [String: Any]
    }

    func listTools() async throws -> [Tool] {
        var tools: [Tool] = []
        var names = Set<String>()
        var cursors = Set<String>()
        var parameters: [String: Any] = [:]
        for _ in 0..<20 {
            try Task.checkCancellation()
            let reply = try await request("tools/list", parameters: parameters, timeout: 20)
            guard let page = reply.body["tools"] as? [[String: Any]] else {
                throw ReaderAIMCPError.invalidResponse
            }
            for item in page {
                guard let name = item["name"] as? String, !name.aiTrimmed.isEmpty,
                      names.insert(name).inserted else { continue }
                var schema = item["inputSchema"] as? [String: Any] ?? [:]
                if schema["type"] == nil { schema["type"] = "object" }
                if schema["properties"] == nil { schema["properties"] = [String: Any]() }
                tools.append(Tool(
                    name: name,
                    title: item["title"] as? String ?? "",
                    description: item["description"] as? String ?? "",
                    schema: scrub(schema) as? [String: Any] ?? schema
                ))
                guard tools.count <= 128 else { throw ReaderAIMCPError.tooManyTools }
            }
            guard let cursor = reply.body["nextCursor"] as? String, !cursor.isEmpty else { return tools }
            guard cursors.insert(cursor).inserted else { throw ReaderAIMCPError.repeatedCursor }
            parameters = ["cursor": cursor]
        }
        throw ReaderAIMCPError.tooManyPages
    }

    func call(_ name: String, arguments: String) async throws -> String {
        let clean = arguments.aiTrimmed
        let values: [String: Any]
        if clean.isEmpty {
            values = [:]
        } else {
            guard clean.utf8.count <= Self.payloadLimit,
                  let object = Self.object(Data(clean.utf8)) else { throw ReaderAIMCPError.invalidArguments }
            values = object
        }
        let reply = try await request("tools/call", parameters: ["name": name, "arguments": values], timeout: 80)
        let result = try JSONSerialization.data(withJSONObject: scrub(reply.body), options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: result, as: UTF8.self)
    }

    private struct Reply {
        let body: [String: Any]
        let sessionID: String?
    }

    private func request(_ method: String, parameters: [String: Any], timeout: TimeInterval) async throws -> Reply {
        let id = UUID().uuidString
        do {
            return try await exchange(
                ["jsonrpc": "2.0", "method": method, "id": id, "params": parameters],
                matching: id, timeout: timeout
            )
        } catch {
            let transportError = error as? URLError
            if method != "initialize" && (Task.isCancelled || transportError?.code == .timedOut) {
                Task.detached(priority: .utility) {
                    try? await notify("notifications/cancelled", parameters: ["requestId": id])
                }
            }
            if Task.isCancelled || transportError?.code == .cancelled { throw CancellationError() }
            if let transportError { throw ReaderAIMCPError.connection(transportError.code.rawValue) }
            throw error
        }
    }

    private func notify(_ method: String, parameters: [String: Any]? = nil) async throws {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        body["params"] = parameters
        do {
            _ = try await exchange(body, matching: nil, timeout: 8)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw ReaderAIMCPError.connection(error.code.rawValue)
        }
    }

    private func exchange(_ body: [String: Any], matching id: String?, timeout: TimeInterval) async throws -> Reply {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await Self.session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw ReaderAIMCPError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 404, sessionID != nil { throw ReaderAIMCPError.expiredSession }
            throw ReaderAIMCPError.http(response.statusCode)
        }
        let newSessionID = response.value(forHTTPHeaderField: "Mcp-Session-Id")
        guard let id else { return Reply(body: [:], sessionID: newSessionID) }
        guard response.expectedContentLength <= Self.payloadLimit else { throw ReaderAIMCPError.oversizedResponse }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let message: [String: Any]?
        if contentType.contains("text/event-stream") {
            message = try await Self.sseMessage(bytes, matching: id)
        } else {
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.payloadLimit else { throw ReaderAIMCPError.oversizedResponse }
                data.append(byte)
            }
            message = Self.object(data)
        }
        try Task.checkCancellation()
        guard let message, message["id"] as? String == id, message["jsonrpc"] as? String == "2.0" else {
            throw ReaderAIMCPError.invalidResponse
        }
        if let error = message["error"] as? [String: Any] {
            let detail = error["message"] as? String ?? ""
            throw ReaderAIMCPError.rpc(error["code"] as? Int, String(redact(detail).prefix(240)))
        }
        guard let result = message["result"] as? [String: Any] else { throw ReaderAIMCPError.invalidResponse }
        return Reply(body: result, sessionID: newSessionID)
    }

    private static func sseMessage(_ bytes: URLSession.AsyncBytes, matching id: String) async throws -> [String: Any]? {
        var line = [UInt8]()
        var event = Data()
        var count = 0
        var followsCR = false
        for try await byte in bytes {
            count += 1
            guard count <= payloadLimit else { throw ReaderAIMCPError.oversizedResponse }
            if byte == 10 && followsCR {
                followsCR = false
                continue
            }
            followsCR = byte == 13
            if byte == 10 || byte == 13 {
                if let message = consume(line, event: &event, matching: id) { return message }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty { _ = consume(line, event: &event, matching: id) }
        return consume([], event: &event, matching: id)
    }

    private static func consume(_ line: [UInt8], event: inout Data, matching id: String) -> [String: Any]? {
        if line.isEmpty {
            guard !event.isEmpty else { return nil }
            defer { event.removeAll(keepingCapacity: true) }
            let message = object(event)
            return message?["id"] as? String == id ? message : nil
        }
        let dataPrefix: [UInt8] = [100, 97, 116, 97, 58]
        if line.starts(with: dataPrefix) {
            var value = line.dropFirst(dataPrefix.count)
            if value.first == 32 { value = value.dropFirst() }
            event.append(contentsOf: value)
            event.append(10)
        }
        return nil
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func redact(_ value: String) -> String {
        secrets.reduce(value) { output, secret in output.replacingOccurrences(of: secret, with: "••••") }
    }

    private func scrub(_ value: Any) -> Any {
        if let text = value as? String { return redact(text) }
        if let children = value as? [String: Any] { return children.mapValues(scrub) }
        if let children = value as? [Any] { return children.map(scrub) }
        return value
    }
}

private final class MCPRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest, let from = original.url, let to = request.url,
              ReaderAIEndpoint.isAllowed(to), ReaderAIEndpoint.sameOrigin(from, to),
              original.httpMethod == request.httpMethod else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private enum ReaderAIMCPError: LocalizedError {
    case missingName, invalidEndpoint, invalidKey, invalidResponse, unsupportedProtocol(String)
    case expiredSession, oversizedResponse, repeatedCursor, tooManyPages, tooManyTools, invalidArguments
    case http(Int), rpc(Int?, String), connection(Int)

    var errorDescription: String? {
        switch self {
        case .missingName: "请填写 MCP 服务器名称。"
        case .invalidEndpoint: "请输入 MCP 的 HTTPS 完整地址，或本机、局域网的 HTTP 地址。"
        case .invalidKey: "MCP 密钥不能包含空格或换行。"
        case .invalidResponse: "MCP 服务器未返回与此请求对应的 JSON-RPC 响应。"
        case .unsupportedProtocol(let version): "当前不兼容 MCP 协议版本 \(version)。"
        case .expiredSession: "MCP 会话已过期，请重新发送请求。"
        case .oversizedResponse: "MCP 服务器返回的数据超过 1 MB。"
        case .repeatedCursor: "MCP 服务器重复返回同一个工具分页标记。"
        case .tooManyPages: "MCP 工具列表超过 20 页。"
        case .tooManyTools: "MCP 服务器提供的工具超过 128 个。"
        case .invalidArguments: "MCP 工具参数必须是 JSON 对象，且不超过 1 MB。"
        case .http(401), .http(403): "MCP 服务器拒绝了授权，请核对密钥和权限。"
        case .http(let code): "MCP 服务器返回 HTTP \(code)。"
        case .rpc(let code, let detail):
            ["MCP 请求失败", code.map(String.init) ?? "", detail].filter { !$0.isEmpty }.joined(separator: " · ")
        case .connection(let code): "无法连接 MCP 服务器（\(code)）。"
        }
    }
}
