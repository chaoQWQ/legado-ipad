import Foundation
import Security

enum ReaderAIKind: String, CaseIterable, Identifiable {
    case question, image

    var id: Self { self }
    var title: String { self == .question ? "问 AI" : "生图" }
    var route: String { self == .question ? "chat/completions" : "images/generations" }
}

struct ReaderAIProvider: Codable {
    var address = "https://api.openai.com/v1"
    var model: String
    var key = ""

    func endpoint(for kind: ReaderAIKind) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              Self.secureURL(url), url.query == nil, url.fragment == nil else {
            throw ReaderAIError.invalidAddress
        }
        if url.pathComponents.suffix(2).joined(separator: "/") == kind.route { return url }
        return url.appending(path: kind.route)
    }

    static func secureURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    var canSend: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ReaderAISettings: Codable {
    var question = ReaderAIProvider(model: "gpt-4.1-mini")
    var image = ReaderAIProvider(model: "gpt-image-1")

    subscript(_ kind: ReaderAIKind) -> ReaderAIProvider {
        kind == .question ? question : image
    }

    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.legado.ipad.reader.ai",
            kSecAttrAccount as String: "providers"
        ]
    }

    static func load() throws -> Self {
        var query = item
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return .init() }
        guard status == errSecSuccess, let data = value as? Data else { throw ReaderAIError.keychain }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        for kind in ReaderAIKind.allCases where !self[kind].key.isEmpty {
            _ = try self[kind].endpoint(for: kind)
            guard self[kind].canSend else { throw ReaderAIError.missingSettings }
        }
        let data = try JSONEncoder().encode(self)
        let fields = [kSecValueData as String: data]
        let status = SecItemUpdate(Self.item as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            var record = Self.item
            record[kSecValueData as String] = data
            record[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else { throw ReaderAIError.keychain }
        } else if status != errSecSuccess {
            throw ReaderAIError.keychain
        }
    }
}

enum ReaderAIError: LocalizedError {
    case invalidAddress, missingSettings, keychain, emptyResponse, oversizedResponse, status(Int)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入有效的 HTTPS 接口地址。"
        case .missingSettings: "请在 AI 设置中填写模型和 API 密钥。"
        case .keychain: "无法读取或保存 AI 设置。请解锁设备后重试。"
        case .emptyResponse: "服务未返回可显示的内容。"
        case .oversizedResponse: "服务返回的内容过大。"
        case .status(401), .status(403): "服务拒绝了请求。请检查 API 密钥和模型权限。"
        case .status(429): "请求达到服务限额。请检查账户用量或稍后重试。"
        case .status(let code): "AI 服务请求失败（HTTP \(code)）。"
        }
    }
}

enum ReaderAIClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        return URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }()

    static func answer(question: String, excerpt: String, provider: ReaderAIProvider) async throws -> String {
        let content = "选中文本\n\(excerpt)\n\n读者问题\n\(question)"
        let request = ChatRequest(model: provider.model, messages: [
            .init(role: "system", content: "你是阅读助手。围绕读者选中的小说片段回答。只有片段能支持时才说明情节，避免剧透。"),
            .init(role: "user", content: content)
        ])
        let data = try await fetch(request, provider: provider, kind: .question, limit: 2 * 1024 * 1024)
        guard let answer = try? JSONDecoder().decode(ChatResponse.self, from: data).choices.first?.message.content,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReaderAIError.emptyResponse
        }
        return answer
    }

    static func generateImage(prompt: String, provider: ReaderAIProvider) async throws -> Data {
        let limit = 24 * 1024 * 1024
        let data = try await fetch(
            ImageRequest(model: provider.model, prompt: prompt),
            provider: provider, kind: .image, limit: limit
        )
        guard let picture = try? JSONDecoder().decode(ImageResponse.self, from: data).data.first else {
            throw ReaderAIError.emptyResponse
        }
        if let encoded = picture.b64_json, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty { return bytes }
        if let url = picture.url, ReaderAIProvider.secureURL(url) {
            return try await load(URLRequest(url: url), limit: limit)
        }
        throw ReaderAIError.emptyResponse
    }

    private static func fetch(
        _ body: some Encodable, provider: ReaderAIProvider, kind: ReaderAIKind, limit: Int
    ) async throws -> Data {
        guard provider.canSend else { throw ReaderAIError.missingSettings }
        var request = URLRequest(url: try provider.endpoint(for: kind))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(provider.key.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return try await load(request, limit: limit)
    }

    private static func load(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw ReaderAIError.emptyResponse }
        guard (200..<300).contains(response.statusCode) else { throw ReaderAIError.status(response.statusCode) }
        guard response.expectedContentLength <= limit else { throw ReaderAIError.oversizedResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ReaderAIError.oversizedResponse }
            data.append(byte)
        }
        return data
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ImageRequest: Encodable {
        let model: String
        let prompt: String
    }

    private struct ImageResponse: Decodable {
        struct Picture: Decodable {
            let b64_json: String?
            let url: URL?
        }
        let data: [Picture]
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            // A generated image may live on a CDN. API requests must keep their keys on the configured endpoint.
            let isImageDownload = task.originalRequest?.httpMethod != "POST"
            let isSecure = request.url.map(ReaderAIProvider.secureURL) == true
            completionHandler(isImageDownload && isSecure ? request : nil)
        }
    }
}
