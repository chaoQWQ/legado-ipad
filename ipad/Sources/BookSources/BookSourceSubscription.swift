import Foundation

public struct BookSourceSubscription: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var autoUpdate: Bool
    public var updateIntervalHours: Int
    public var silentUpdate: Bool
    public var lastRefreshedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        autoUpdate: Bool = false,
        updateIntervalHours: Int = 24,
        silentUpdate: Bool = false,
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.name = name.trimmed
        self.url = url
        self.autoUpdate = autoUpdate
        self.updateIntervalHours = max(0, updateIntervalHours)
        self.silentUpdate = silentUpdate
        self.lastRefreshedAt = lastRefreshedAt
    }

    public func isDue(at now: Date = Date()) -> Bool {
        guard autoUpdate else { return false }
        guard let lastRefreshedAt else { return true }
        return now.timeIntervalSince(lastRefreshedAt) >= Double(max(0, updateIntervalHours)) * 3_600
    }

    public static func address(from input: String) throws -> URL {
        guard let components = URLComponents(string: input.trimmed) else {
            throw BookSourceSubscriptionError.invalidAddress
        }
        if let scheme = components.scheme?.lowercased(), ["legado", "yuedu"].contains(scheme) {
            let host = components.host?.lowercased()
            let path = components.path.lowercased()
            let importRoute = host == "import" && ["/booksource", "/auto"].contains(path)
            let legacyRoute = host == "booksource" && path == "/importonline"
            guard components.user == nil, components.password == nil, components.port == nil,
                  importRoute || legacyRoute,
                  let source = components.queryItems?.first(where: { $0.name == "src" })?.value,
                  let download = URLComponents(string: source.trimmed) else {
                throw BookSourceSubscriptionError.invalidAddress
            }
            return try normalizedAddress(download)
        }
        return try normalizedAddress(components)
    }

    private static func normalizedAddress(_ input: URLComponents) throws -> URL {
        var components = input
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.fragment != "requestWithoutUA" { components.fragment = nil }
        if components.port == 80 && components.scheme == "http" ||
            components.port == 443 && components.scheme == "https" {
            components.port = nil
        }
        guard let url = components.url, url.isWebURL else {
            throw BookSourceSubscriptionError.invalidAddress
        }
        return (try? BookSourceMarketplaceClient.downloadAddress(from: url)) ?? url
    }
}

public enum BookSourceSubscriptionError: LocalizedError, Equatable, Sendable {
    case invalidAddress
    case invalidPayload
    case marketplaceUnavailable
    case invalidMarketplaceEntry

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "请输入有效的 HTTP(S) 订阅地址或阅读书源导入链接。"
        case .invalidPayload:
            "地址返回的内容格式不受支持，或包含无效的阅读 3.0 书源。"
        case .marketplaceUnavailable:
            "暂时无法读取书源广场。可打开源仓库网站查找书源。"
        case .invalidMarketplaceEntry:
            "无法识别这条书源的下载地址。"
        }
    }
}

public struct BookSourceSubscriptionClient: Sendable {
    private let fetch: SourceDownload.Fetch

    public init() {
        fetch = { try await SourceDownload.load($0, $1) }
    }

    init(fetch: @escaping SourceDownload.Fetch) {
        self.fetch = fetch
    }

    public func preview(_ url: URL) async throws -> [BookSource] {
        guard url.isWebURL else { throw BookSourceSubscriptionError.invalidAddress }
        let (data, _) = try await fetch(url, 64 * 1024 * 1024)
        try Task.checkCancellation()
        do {
            return try BookSourceImport.decode(data)
        } catch {
            throw BookSourceSubscriptionError.invalidPayload
        }
    }

    public static func download(_ url: URL, maxBytes: Int = 8 * 1024 * 1024) async throws -> (Data, URL) {
        try await SourceDownload.load(url, maxBytes)
    }
}

enum SourceDownload {
    typealias Fetch = @Sendable (URL, Int) async throws -> (Data, URL)

    private static let session = makeSession()
    private static let marketplaceSession = makeSession(allowedHosts: BookSourceMarketplaceClient.downloadHosts)

    private static func makeSession(allowedHosts: Set<String>? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let redirects = WebRedirects(allowedHosts: allowedHosts)
        return URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    static func load(_ url: URL, _ maxBytes: Int, marketplace: Bool = false) async throws -> (Data, URL) {
        guard url.isWebURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw BookSourceSubscriptionError.invalidAddress
        }
        if marketplace, !BookSourceMarketplaceClient.isAllowed(url, hosts: BookSourceMarketplaceClient.downloadHosts) {
            throw BookSourceSubscriptionError.invalidAddress
        }
        let omitUserAgent = components.fragment == "requestWithoutUA"
        components.fragment = nil
        guard let address = components.url else { throw BookSourceSubscriptionError.invalidAddress }

        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData)
        if omitUserAgent { request.setValue("null", forHTTPHeaderField: "User-Agent") }
        let client = marketplace ? marketplaceSession : session
        let (bytes, response) = try await client.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, let finalURL = http.url, finalURL.isWebURL else {
            throw BookSourceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BookSourceError.badStatus(http.statusCode)
        }
        let expected = http.expectedContentLength
        guard maxBytes > 0, expected <= maxBytes else { throw BookSourceError.responseTooLarge }

        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(expected)) }
        for try await byte in bytes {
            guard data.count < maxBytes else { throw BookSourceError.responseTooLarge }
            data.append(byte)
        }
        return (data, finalURL)
    }

    private final class WebRedirects: NSObject, URLSessionTaskDelegate {
        private let allowedHosts: Set<String>?

        init(allowedHosts: Set<String>?) {
            self.allowedHosts = allowedHosts
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let url = request.url, url.isWebURL else {
                completionHandler(nil)
                return
            }
            if let allowedHosts, !BookSourceMarketplaceClient.isAllowed(url, hosts: allowedHosts) {
                completionHandler(nil)
            } else {
                completionHandler(request)
            }
        }
    }
}
