import Foundation
import Security

enum ReaderAIAPIMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletions = "chat_completions"
    case responses

    var id: Self { self }
    var title: String { self == .responses ? "Responses" : "Chat Completions" }
    var route: String { self == .responses ? "responses" : "chat/completions" }
}

struct ReaderAIProvider: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = ""
    var address = "https://api.openai.com/v1"
    var key = ""
    var headers = ""
    var apiMode: ReaderAIAPIMode = .chatCompletions
    var promptCache = false

    var title: String { name.aiTrimmed.isEmpty ? (URL(string: address)?.host ?? "供应商") : name.aiTrimmed }
}

struct ReaderAIModel: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var providerID = ""
    var model = ""
}

struct ReaderAIModelChoice: Equatable, Identifiable, Sendable {
    let record: ReaderAIModel
    let provider: ReaderAIProvider

    var id: String { record.id }
    var model: String { record.model.aiTrimmed }
    var title: String { "\(model) · \(provider.title)" }
}

struct ReaderAIImageProvider: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var name = ""
    var address = "https://api.openai.com/v1"
    var key = ""
    var headers = ""
    var model = ""
    var imageToolModel: String?
    var parametersJSON = ""
    var stylePrompt = ""
    var timeoutMilliseconds = 120_000
    var enabled = true

    var title: String {
        if !name.aiTrimmed.isEmpty { return name.aiTrimmed }
        if !model.aiTrimmed.isEmpty { return model.aiTrimmed }
        return URL(string: address)?.host ?? "生图供应商"
    }

    var resolvedModelName: String {
        let parameters = (try? parameters()) ?? [:]
        if usesResponses(parameters: parameters), let imageModel = resolvedImageToolModel(parameters: parameters) {
            return imageModel
        }
        return resolvedModel(parameters: parameters)
    }

    func usesResponses(parameters: [String: Any]) -> Bool {
        if let route = parameters["endpoint"] as? String { return route.aiTrimmed.lowercased() == "responses" }
        return URLComponents(string: address.aiTrimmed)?.path.split(separator: "/").last == "responses"
    }

    func resolvedModel(parameters: [String: Any]) -> String {
        let candidates = [model, parameters["model"] as? String ?? ""]
        if let explicit = candidates.map(\.aiTrimmed).first(where: { !$0.isEmpty }) { return explicit }
        if usesResponses(parameters: parameters) { return "gpt-5" }
        let official = URLComponents(string: address.aiTrimmed)?.host?.lowercased() == "api.openai.com"
        return official ? "gpt-image-2.6-flare" : "gpt-image-1"
    }

    func resolvedImageToolModel(parameters: [String: Any]) -> String? {
        let candidates = [imageToolModel, (parameters["tool"] as? [String: Any])?["model"] as? String]
        return candidates.compactMap { $0?.aiTrimmed }.first { !$0.isEmpty }
    }

    func parameters() throws -> [String: Any] {
        let raw = parametersJSON.aiTrimmed
        guard !raw.isEmpty else { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            throw ReaderAIError.invalidImageParameters
        }
        return object
    }
}

struct ReaderAIChatMessage: Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    let role: Role
    let content: String
}

struct ReaderAISettings: Codable, Sendable {
    static let defaultAskPrompt = "你是阅读页里的问 AI 助手。请围绕当前书籍和选中文本回答，优先解释原文含义、上下文、人物关系、伏笔或用户提问，不要编造未给出的剧情。"

    var enabled = true
    var providers: [ReaderAIProvider] = []
    var models: [ReaderAIModel] = []
    var imageProviders: [ReaderAIImageProvider] = []
    var defaultModelID: String?
    var askModelID: String?
    var imageProviderID: String?
    var askPrompt = Self.defaultAskPrompt
    var skills: [ReaderAISkill] = []
    private var configuredMCPServers: [ReaderAIMCPServer]?
    var disabledNativeToolNames: Set<String>?
    var configuredToolRoundLimit: Int?
    var configuredReadToolScope: ReaderAIToolScope?
    var configuredReturnToSend: Bool?
    var configuredThinkingToolbar: Bool?
    private var configuredTavily: ReaderAITavilyConfig?

    private enum CodingKeys: String, CodingKey {
        case enabled, providers, models, imageProviders, defaultModelID, askModelID, imageProviderID, askPrompt
        case configuredMCPServers, disabledNativeToolNames, configuredToolRoundLimit, configuredReadToolScope
        case configuredReturnToSend, configuredThinkingToolbar
        case configuredTavily
    }

    var mcpServers: [ReaderAIMCPServer] {
        get { configuredMCPServers ?? [] }
        set { configuredMCPServers = newValue }
    }

    var toolRoundLimit: Int {
        get { min(64, max(4, configuredToolRoundLimit ?? 32)) }
        set { configuredToolRoundLimit = min(64, max(4, newValue)) }
    }

    var readToolScope: ReaderAIToolScope {
        get { configuredReadToolScope ?? .enabled }
        set { configuredReadToolScope = newValue }
    }

    var returnToSend: Bool {
        get { configuredReturnToSend ?? true }
        set { configuredReturnToSend = newValue }
    }

    var showsThinkingToolbar: Bool {
        get { configuredThinkingToolbar ?? true }
        set { configuredThinkingToolbar = newValue }
    }

    var tavily: ReaderAITavilyConfig {
        get { configuredTavily ?? .init() }
        set { configuredTavily = newValue }
    }

    var questionChoices: [ReaderAIModelChoice] {
        let byID = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return models.compactMap { record in
            guard let provider = byID[record.providerID], !record.model.aiTrimmed.isEmpty else { return nil }
            return ReaderAIModelChoice(record: record, provider: provider)
        }
    }

    var defaultQuestionChoice: ReaderAIModelChoice? {
        let choices = questionChoices
        return choices.first(where: { $0.id == askModelID })
            ?? choices.first(where: { $0.id == defaultModelID })
            ?? choices.first
    }

    var defaultChatChoice: ReaderAIModelChoice? {
        let choices = questionChoices
        return choices.first(where: { $0.id == defaultModelID }) ?? choices.first
    }

    var enabledImageProviders: [ReaderAIImageProvider] { imageProviders.filter(\.enabled) }

    var defaultImageProvider: ReaderAIImageProvider? {
        enabledImageProviders.first(where: { $0.id == imageProviderID }) ?? enabledImageProviders.first
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
        var settings = Self()
        if status != errSecItemNotFound {
            guard status == errSecSuccess, let data = value as? Data else { throw ReaderAIError.keychain }
            settings = try decode(data)
        }
        settings.skills = (try? ReaderAISkill.loadLibrary()) ?? []
        return settings
    }

    func saveSkills() throws { try ReaderAISkill.saveLibrary(skills) }

    mutating func installDefaultSkill(_ imported: ReaderAISkill) {
        var skill = imported
        let matching = skills.filter {
            $0.name == imported.name || (!imported.sourceURL.isEmpty && $0.sourceURL == imported.sourceURL)
        }
        if let existing = matching.first {
            skill.id = existing.id
        }
        let replaced = Set(matching.map(\.id))
        skills.removeAll { replaced.contains($0.id) }
        skills.append(skill)
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let settings = try? decoder.decode(Self.self, from: data) { return settings }
        let prior = try decoder.decode(LegacySettings.self, from: data)
        var migrated = Self()
        if prior.question.wasConfigured(defaultModel: "gpt-4.1-mini") {
            let provider = ReaderAIProvider(
                id: "legacy-reader-chat", name: "原问 AI 供应商",
                address: prior.question.address, key: prior.question.key,
                apiMode: URLComponents(string: prior.question.address.aiTrimmed)?.path.split(separator: "/").last
                    == "responses" ? .responses : .chatCompletions
            )
            let model = ReaderAIModel(id: "legacy-reader-model", providerID: provider.id, model: prior.question.model)
            migrated.providers = [provider]
            migrated.models = [model]
            migrated.askModelID = model.id
            migrated.defaultModelID = model.id
        }
        if prior.image.wasConfigured(defaultModel: "gpt-image-1") {
            let provider = ReaderAIImageProvider(
                id: "legacy-reader-image", name: "原生图供应商",
                address: prior.image.address, key: prior.image.key, model: prior.image.model
            )
            migrated.imageProviders = [provider]
            migrated.imageProviderID = provider.id
        }
        return migrated
    }

    func save() throws {
        for provider in providers {
            _ = try ReaderAIEndpoint.make(provider.address, route: provider.apiMode.route)
            _ = try ReaderAIHeaders.parse(provider.headers)
        }
        for provider in imageProviders {
            _ = try ReaderAIEndpoint.make(provider.address, route: "images/generations")
            _ = try provider.parameters()
            _ = try ReaderAIHeaders.parse(provider.headers)
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

    private struct LegacySettings: Decodable {
        struct Provider: Decodable {
            let address: String
            let model: String
            let key: String

            func wasConfigured(defaultModel: String) -> Bool {
                !key.aiTrimmed.isEmpty || address.aiTrimmed != "https://api.openai.com/v1" || model.aiTrimmed != defaultModel
            }
        }
        let question: Provider
        let image: Provider
    }
}

enum ReaderAIError: LocalizedError {
    case invalidAddress, invalidHeaders, invalidImageParameters, missingSettings, keychain
    case emptyResponse, oversizedResponse, http(Int, String?), provider(String)
    case connection(host: String, code: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请填写 HTTPS 接口地址，或使用 HTTP 的本机、局域网地址。"
        case .invalidHeaders: return "自定义请求头应为 JSON 对象，或每行一组「名称: 值」。"
        case .invalidImageParameters: return "生图参数必须是 JSON 对象。"
        case .missingSettings: return "请在 AI 设置中添加供应商和模型。"
        case .keychain: return "无法读取或保存 AI 设置。请解锁设备后重试。"
        case .emptyResponse: return "服务返回格式有误，或未返回可显示的内容。"
        case .oversizedResponse: return "服务返回的内容过大。"
        case .http(let status, let detail):
            if let detail, !detail.isEmpty { return "HTTP \(status) · \(detail)" }
            switch status {
            case 401, 403: return "服务拒绝了请求（HTTP \(status)）。请检查密钥、请求头和模型权限。"
            case 404: return "接口或模型不存在（HTTP 404）。请检查接口地址、接口模式和模型 ID。"
            case 429: return "请求达到服务限额（HTTP 429）。请检查账户用量或稍后重试。"
            default: return "AI 服务请求失败（HTTP \(status)）。"
            }
        case .provider(let message): return message
        case .connection(let host, let code, let detail): return "\(host) · \(detail)（\(code)）"
        }
    }
}

enum ReaderAIEndpoint {
    static func make(_ raw: String, route: String) throws -> URL {
        guard var parts = URLComponents(string: raw.aiTrimmed), let original = parts.url,
              isAllowed(original), parts.fragment == nil else {
            throw ReaderAIError.invalidAddress
        }
        var path = parts.percentEncodedPath
        while path.last == "/" { path.removeLast() }
        if let knownRoute = ["/chat/completions", "/images/generations", "/responses", "/models"].first(where: {
            path.hasSuffix($0)
        }) {
            path.removeLast(knownRoute.count)
        } else if !path.split(separator: "/").contains(where: { part in
            part.range(of: #"^v[0-9]+(?:(?:alpha|beta)[0-9]*)?$"#, options: .regularExpression) != nil
        }) {
            path += "/v1"
        }
        parts.percentEncodedPath = "\(path)/\(route)"
        guard let url = parts.url else { throw ReaderAIError.invalidAddress }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http" else { return false }
        if host == "localhost" || host == "[::1]" || host == "::1" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { UInt8($0) }
        guard parts.count == 4, numbers.count == 4 else { return false }
        return numbers[0] == 127 || numbers[0] == 10
            || (numbers[0] == 192 && numbers[1] == 168)
            || (numbers[0] == 172 && (16...31).contains(numbers[1]))
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }
}

enum ReaderAIHeaders {
    static func parse(_ input: String) throws -> [String: String] {
        let raw = input.aiTrimmed
        guard !raw.isEmpty else { return [:] }
        var result: [String: String] = [:]
        if raw.hasPrefix("{") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                throw ReaderAIError.invalidHeaders
            }
            for (name, value) in object {
                try insert(name, String(describing: value), into: &result)
            }
        } else {
            for rawLine in raw.split(whereSeparator: \.isNewline) {
                let line = String(rawLine).aiTrimmed
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                guard let split = line.firstIndex(of: ":") ?? line.firstIndex(of: "=") else {
                    throw ReaderAIError.invalidHeaders
                }
                try insert(String(line[..<split]), String(line[line.index(after: split)...]), into: &result)
            }
        }
        return result
    }

    private static func insert(_ name: String, _ value: String, into result: inout [String: String]) throws {
        let name = name.aiTrimmed.lowercased()
        let value = value.aiTrimmed
        guard !name.isEmpty, name.utf8.allSatisfy({
            (97...122).contains($0) || (48...57).contains($0) || $0 == 96 || "!#$%&'*+-.^_|~".utf8.contains($0)
        }), !value.contains(where: { $0.isNewline }), !value.utf8.contains(0) else {
            throw ReaderAIError.invalidHeaders
        }
        if !value.isEmpty { result[name] = value }
    }
}

extension String {
    var aiTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
