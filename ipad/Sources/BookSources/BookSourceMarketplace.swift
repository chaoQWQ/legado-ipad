import Foundation

public enum BookSourceMarketplaceProvider: String, CaseIterable, Identifiable, Sendable {
    case yiove
    case yuanRepository

    public var id: Self { self }
    public var categories: [BookSourceMarketplaceCategory] { BookSourceMarketplaceCategory.allCases }

    public var title: String {
        switch self {
        case .yiove: "Yiove 书源仓库"
        case .yuanRepository: "源仓库"
        }
    }

    public var siteURL: URL {
        switch self {
        case .yiove: URL(string: "https://shuyuan.yiove.com/")!
        case .yuanRepository: BookSourceMarketplaceClient.siteURL
        }
    }

    public func webURL(for category: BookSourceMarketplaceCategory) -> URL {
        switch self {
        case .yiove: siteURL.appending(path: category.yioveList)
        case .yuanRepository: category.webURL
        }
    }
}

public enum BookSourceMarketplaceCategory: String, CaseIterable, Identifiable, Sendable {
    case sources
    case collections

    public var id: Self { self }

    public var title: String {
        switch self {
        case .sources: "书源"
        case .collections: "书源合集"
        }
    }

    public var webURL: URL {
        indexURL(at: BookSourceMarketplaceClient.primaryHost, page: 1, keyword: nil)
    }

    var section: String { self == .sources ? "shuyuan" : "shuyuans" }
    fileprivate var yioveList: String { self == .sources ? "book-sources" : "book-source-collections" }
    fileprivate var yioveDetail: String { self == .sources ? "book-source" : "book-source-collection" }

    func indexURL(at host: String, page: Int, keyword: String?) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/yuedu/\(section)/index.html"
        var query: [URLQueryItem] = []
        if let keyword = keyword?.nilIfBlank { query.append(URLQueryItem(name: "keys", value: keyword)) }
        if page > 1 { query.append(URLQueryItem(name: "page", value: String(page))) }
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }
}

public struct BookSourceMarketplaceEntry: Identifiable, Sendable, Equatable {
    public let title: String
    public let detailURL: URL
    public let provider: BookSourceMarketplaceProvider
    public var id: URL { detailURL }
}

public struct BookSourceMarketplacePage: Sendable {
    public let entries: [BookSourceMarketplaceEntry]
    public let hasNextPage: Bool
}

public struct BookSourceMarketplaceClient: Sendable {
    public static let siteURL = URL(string: "https://yckceo.vip/")!
    static let primaryHost = "www.yckceo.com"
    private static let mirrorHosts = [primaryHost, "www.yck2026.fun"]
    private static let repositoryHosts = Set(mirrorHosts + ["yckceo.com", "yck2026.fun"])
    private static let yioveHost = "shuyuan.yiove.com"
    private static let yioveAPIHost = "shuyuan-api.yiove.com"
    private static let yioveAPI = URL(string: "https://\(yioveAPIHost)")!
    static let downloadHosts = repositoryHosts.union([yioveAPIHost])
    private let fetch: SourceDownload.Fetch

    public init() {
        fetch = { try await SourceDownload.load($0, $1, marketplace: true) }
    }

    init(fetch: @escaping SourceDownload.Fetch) {
        self.fetch = fetch
    }

    public func entries(
        in category: BookSourceMarketplaceCategory, page: Int = 1, keyword: String? = nil,
        provider: BookSourceMarketplaceProvider = .yuanRepository
    ) async throws -> [BookSourceMarketplaceEntry] {
        try await self.page(in: category, page: page, keyword: keyword, provider: provider).entries
    }

    public func page(
        in category: BookSourceMarketplaceCategory, page: Int = 1, keyword: String? = nil,
        provider: BookSourceMarketplaceProvider = .yuanRepository
    ) async throws -> BookSourceMarketplacePage {
        let number = max(1, page)
        let keyword = keyword?.nilIfBlank
        switch provider {
        case .yiove:
            let url = Self.yioveIndexURL(category: category, page: number, keyword: keyword)
            return try await reachable([url]) { url in
                let (data, finalURL) = try await fetch(url, 4 * 1024 * 1024)
                guard Self.isAllowed(finalURL, hosts: [Self.yioveAPIHost]) else { throw ResponseIssue.unexpectedAddress }
                return try Self.parseYiovePage(data, category: category, page: number)
            }
        case .yuanRepository:
            let candidates = Self.mirrorHosts.map { category.indexURL(at: $0, page: number, keyword: keyword) }
            return try await reachable(candidates) { url in
                let (data, finalURL) = try await fetch(url, 4 * 1024 * 1024)
                let entries = try Self.parseEntries(data, finalURL: finalURL, category: category)
                if entries.isEmpty {
                    guard (number > 1 || keyword != nil), try Self.isRepositoryListing(data, category: category) else {
                        throw ResponseIssue.unrecognizedListing
                    }
                }
                return BookSourceMarketplacePage(entries: entries, hasNextPage: !entries.isEmpty)
            }
        }
    }

    public func downloadURL(for entry: BookSourceMarketplaceEntry) async throws -> URL {
        try Task.checkCancellation()
        return try Self.downloadAddress(from: entry.detailURL)
    }

    public func preview(for entry: BookSourceMarketplaceEntry) async throws -> (sources: [BookSource], url: URL) {
        let address = try Self.downloadAddress(from: entry.detailURL)
        let hosts: Set<String>
        let candidates: [URL]
        switch entry.provider {
        case .yiove:
            hosts = [Self.yioveAPIHost]
            candidates = [address]
        case .yuanRepository:
            hosts = Self.repositoryHosts
            candidates = [address] + Self.mirrorHosts.compactMap { host in
                guard address.host != host else { return nil }
                return Self.address(address, replacingHost: host)
            }
        }
        return try await reachable(candidates) { url in
            let (data, finalURL) = try await fetch(url, 64 * 1024 * 1024)
            try Task.checkCancellation()
            guard Self.isAllowed(finalURL, hosts: hosts) else { throw ResponseIssue.unexpectedAddress }
            do {
                return (try BookSourceImport.decode(data), url)
            } catch {
                throw BookSourceSubscriptionError.invalidPayload
            }
        }
    }

    static func downloadAddress(from url: URL) throws -> URL {
        if isAllowed(url, hosts: [yioveHost]) {
            let parts = url.path.split(separator: "/")
            guard parts.count == 2, let route = BookSourceMarketplaceCategory.allCases.first(where: { $0.yioveDetail == parts[0] }),
                  let id = UUID(uuidString: String(parts[1])) else {
                throw BookSourceSubscriptionError.invalidMarketplaceEntry
            }
            return yioveAPI.appending(path: "import/\(route.yioveDetail)/\(id.uuidString.lowercased())")
        }
        let path = try detailRoute(url)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw BookSourceSubscriptionError.invalidMarketplaceEntry
        }
        components.path = "/yuedu/\(path.section)/json/id/\(path.id).json"
        components.query = nil
        components.fragment = nil
        guard let address = components.url else {
            throw BookSourceSubscriptionError.invalidMarketplaceEntry
        }
        return address
    }

    static func parseEntries(
        _ data: Data, finalURL: URL, category: BookSourceMarketplaceCategory
    ) throws -> [BookSourceMarketplaceEntry] {
        guard isAllowed(finalURL, hosts: repositoryHosts), let host = finalURL.host else { throw ResponseIssue.unexpectedAddress }
        guard let text = String(data: data, encoding: .utf8) else { throw ResponseIssue.unrecognizedListing }
        let document = try HTMLDocument(text)
        let links = try document.root.xpath("//h2//a[@href]", field: "书源广场列表")
        var ids = Set<String>()
        return links.compactMap { value in
            guard case .html(let link) = value, let title = link.text.nilIfBlank,
                  let href = link.attribute("href").nilIfBlank,
                  let url = URL(string: href, relativeTo: finalURL)?.absoluteURL,
                  let route = try? detailRoute(url),
                  route.section == category.section, ids.insert(route.id).inserted,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
            components.host = host
            components.port = finalURL.port
            components.fragment = nil
            components.query = nil
            return components.url.map { BookSourceMarketplaceEntry(title: title, detailURL: $0, provider: .yuanRepository) }
        }
    }

    private static func isRepositoryListing(_ data: Data, category: BookSourceMarketplaceCategory) throws -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let document = try HTMLDocument(text)
        return try !document.root.xpath(
            "//a[contains(@href, '/yuedu/\(category.section)/index.html')]", field: "书源广场分类"
        ).isEmpty
    }

    private static func yioveIndexURL(category: BookSourceMarketplaceCategory, page: Int, keyword: String?) -> URL {
        let path = keyword == nil ? category.yioveList : "search"
        var components = URLComponents(url: yioveAPI.appending(path: "shuyuan/\(path)"), resolvingAgainstBaseURL: true)!
        var query = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "page_size", value: "20")]
        if let keyword {
            query.append(URLQueryItem(name: "search_key", value: keyword))
            query.append(URLQueryItem(name: "search_type", value: category.yioveList))
        }
        components.queryItems = query
        return components.url!
    }

    private static func parseYiovePage(
        _ data: Data, category: BookSourceMarketplaceCategory, page: Int
    ) throws -> BookSourceMarketplacePage {
        struct Response: Decodable {
            struct Row: Decodable {
                let id: String
                let name: String
            }

            let items: [Row]
            let pages: Int
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw ResponseIssue.unrecognizedListing }
        var ids = Set<UUID>()
        let entries = response.items.compactMap { row -> BookSourceMarketplaceEntry? in
            guard let id = UUID(uuidString: row.id), let name = row.name.nilIfBlank, ids.insert(id).inserted else { return nil }
            let detail = BookSourceMarketplaceProvider.yiove.siteURL.appending(path: "\(category.yioveDetail)/\(id.uuidString.lowercased())")
            return BookSourceMarketplaceEntry(title: name, detailURL: detail, provider: .yiove)
        }
        guard response.items.isEmpty || !entries.isEmpty else { throw ResponseIssue.unrecognizedListing }
        return BookSourceMarketplacePage(entries: entries, hasNextPage: page < response.pages)
    }

    static func isAllowed(_ url: URL, hosts: Set<String>) -> Bool {
        url.isWebURL && url.scheme?.lowercased() == "https"
            && url.host.map { hosts.contains($0.lowercased()) } == true
            && (url.port == nil || url.port == 443)
    }

    private static func detailRoute(_ url: URL) throws -> (section: String, id: String) {
        let parts = url.path.split(separator: "/")
        guard isAllowed(url, hosts: repositoryHosts), parts.count == 5, parts[0] == "yuedu",
              ["shuyuan", "shuyuans"].contains(parts[1]), parts[2] == "content", parts[3] == "id",
              parts[4].hasSuffix(".html") else {
            throw BookSourceSubscriptionError.invalidMarketplaceEntry
        }
        let id = parts[4].dropLast(".html".count)
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw BookSourceSubscriptionError.invalidMarketplaceEntry
        }
        return (String(parts[1]), String(id))
    }

    private static func address(_ url: URL, replacingHost host: String) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.host = host
        components?.port = nil
        return components?.url
    }

    private func reachable<Value: Sendable>(
        _ candidates: [URL], operation: @escaping @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Attempt<Value>.self) { tasks in
            for (index, url) in candidates.enumerated() {
                tasks.addTask {
                    if index > 0 { try await Task.sleep(for: .milliseconds(350 * index)) }
                    do {
                        return .success(try await operation(url))
                    } catch {
                        try Task.checkCancellation()
                        return .failure(index, Failure(host: url.host ?? "书源网站", error: error))
                    }
                }
            }
            defer { tasks.cancelAll() }
            var failures: [(Int, Failure)] = []
            for try await attempt in tasks {
                try Task.checkCancellation()
                switch attempt {
                case .success(let value): return value
                case .failure(let index, let failure): failures.append((index, failure))
                }
            }
            throw LoadFailure(attempts: failures.sorted { $0.0 < $1.0 }.map { $0.1 })
        }
    }

    private enum ResponseIssue: Error {
        case unexpectedAddress
        case unrecognizedListing
    }

    private enum Attempt<Value: Sendable>: Sendable {
        case success(Value)
        case failure(Int, Failure)
    }

    private struct Failure: Sendable {
        let host: String
        let reason: String
        let certificateFailure: Bool

        init(host: String, error: Error) {
            self.host = host
            let requestError = error as NSError
            let urlError = requestError.domain == NSURLErrorDomain ? URLError.Code(rawValue: requestError.code) : nil
            let certificateReason: String?
            switch urlError {
            case .serverCertificateUntrusted: certificateReason = "设备不信任服务器证书"
            case .serverCertificateHasBadDate: certificateReason = "服务器证书日期无效"
            case .serverCertificateHasUnknownRoot: certificateReason = "服务器证书的签发机构不受信任"
            case .serverCertificateNotYetValid: certificateReason = "服务器证书尚未生效"
            default: certificateReason = nil
            }
            certificateFailure = certificateReason != nil
            switch error {
            case BookSourceError.badStatus(403): reason = "HTTP 403，网站拒绝此请求"
            case BookSourceError.badStatus(let status): reason = "HTTP \(status)"
            case BookSourceError.responseTooLarge: reason = "响应超过大小限制"
            case BookSourceError.invalidResponse: reason = "无法识别服务器响应"
            case BookSourceSubscriptionError.invalidPayload: reason = "响应不是有效的阅读书源 JSON"
            case ResponseIssue.unexpectedAddress: reason = "响应来自未识别的 HTTPS 地址"
            case ResponseIssue.unrecognizedListing: reason = "响应未包含可识别的目录条目"
            default:
                let domain = requestError.domain.utf8.prefix(80).filter { byte in
                    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 46 || byte == 95
                }
                let summary: String
                switch urlError {
                case .secureConnectionFailed: summary = "无法建立 HTTPS 安全连接"
                case .cannotFindHost, .dnsLookupFailed: summary = "无法解析域名"
                case .timedOut: summary = "连接超时"
                case .notConnectedToInternet: summary = "设备未连接互联网"
                default: summary = certificateReason ?? "网络错误"
                }
                reason = "\(summary) \(String(decoding: domain, as: UTF8.self)) \(requestError.code)"
            }
        }
    }

    private struct LoadFailure: LocalizedError {
        let attempts: [Failure]
        var errorDescription: String? {
            var messages = attempts.map { "\($0.host)（\($0.reason)）" }
            if attempts.contains(where: \.certificateFailure) {
                messages.append("请检查设备日期与时间，或切换网络后重试。")
            }
            return messages.joined(separator: "\n")
        }
    }
}
