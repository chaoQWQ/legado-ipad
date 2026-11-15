import Foundation

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

    var section: String {
        switch self {
        case .sources: "shuyuan"
        case .collections: "shuyuans"
        }
    }

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
    public var id: URL { detailURL }
}

public struct BookSourceMarketplaceClient: Sendable {
    public static let siteURL = URL(string: "https://yckceo.vip/")!
    static let primaryHost = "www.yckceo.com"
    private static let mirrorHosts = [primaryHost, "www.yck2026.fun"]
    private static let knownHosts = Set(mirrorHosts + ["yckceo.com", "yck2026.fun"])
    private let fetch: SourceDownload.Fetch

    public init() {
        fetch = { try await SourceDownload.load($0, $1) }
    }

    init(fetch: @escaping SourceDownload.Fetch) {
        self.fetch = fetch
    }

    public func entries(
        in category: BookSourceMarketplaceCategory, page: Int = 1, keyword: String? = nil
    ) async throws -> [BookSourceMarketplaceEntry] {
        for host in Self.mirrorHosts {
            try Task.checkCancellation()
            let address = category.indexURL(at: host, page: max(1, page), keyword: keyword)
            do {
                let (data, finalURL) = try await fetch(address, 4 * 1024 * 1024)
                let entries = try Self.parseEntries(data, finalURL: finalURL, category: category)
                if !entries.isEmpty || page > 1 || keyword?.nilIfBlank != nil { return entries }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
        }
        throw BookSourceSubscriptionError.marketplaceUnavailable
    }

    public func downloadURL(for entry: BookSourceMarketplaceEntry) async throws -> URL {
        try Task.checkCancellation()
        return try Self.downloadAddress(from: entry.detailURL)
    }

    static func downloadAddress(from url: URL) throws -> URL {
        let path = try detailRoute(url)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw BookSourceSubscriptionError.invalidMarketplaceEntry
        }
        // The repository publishes each detail page and its matching JSON at
        // the same section and numerical identifier.
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
        guard isMarketplaceURL(finalURL), let text = String(data: data, encoding: .utf8) else {
            throw BookSourceSubscriptionError.marketplaceUnavailable
        }
        let document = try HTMLDocument(text)
        let links = try document.root.xpath("//h2//a[@href]", field: "书源广场列表")
        var ids = Set<String>()
        return links.compactMap { value in
            guard case .html(let link) = value, let title = link.text.nilIfBlank,
                  let href = link.attribute("href").nilIfBlank,
                  let url = URL(string: href, relativeTo: finalURL)?.absoluteURL,
                  let route = try? detailRoute(url),
                  route.section == category.section, ids.insert(route.id).inserted else { return nil }

            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.fragment = nil
            components?.query = nil
            return components?.url.map { BookSourceMarketplaceEntry(title: title, detailURL: $0) }
        }
    }

    private static func isMarketplaceURL(_ url: URL) -> Bool {
        url.isWebURL && url.scheme?.lowercased() == "https"
            && url.host.map { knownHosts.contains($0.lowercased()) } == true
            && (url.port == nil || url.port == 443)
    }

    private static func detailRoute(_ url: URL) throws -> (section: String, id: String) {
        let parts = url.path.split(separator: "/")
        guard isMarketplaceURL(url), parts.count == 5, parts[0] == "yuedu",
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
}
