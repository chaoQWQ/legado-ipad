import Foundation

public struct FeedSubscription: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var url: URL

    public init(id: UUID = UUID(), name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
    }

    public static func address(from input: String) throws -> URL {
        guard let url = feedURL(input, relativeTo: nil) else { throw FeedError.invalidAddress }
        return url
    }
}

public struct SubscriptionFeed: Sendable {
    public struct Article: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let summary: String
        public let url: URL?
        public let publishedAt: Date?
    }

    public let title: String
    public let articles: [Article]
}

public struct SubscriptionFeedClient: Sendable {
    private let download: @Sendable (URL) async throws -> (Data, URL)

    public init() {
        download = { try await BookSourceSubscriptionClient.download($0, maxBytes: 4 * 1024 * 1024) }
    }

    init(download: @escaping @Sendable (URL) async throws -> (Data, URL)) {
        self.download = download
    }

    public func load(_ url: URL) async throws -> SubscriptionFeed {
        let (data, address) = try await download(url)
        try Task.checkCancellation()
        let parser = XMLParser(data: data)
        let decoder = FeedXMLDecoder(address: address)
        parser.delegate = decoder
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), decoder.isFeed else { throw FeedError.invalidFeed }
        return SubscriptionFeed(title: decoder.title, articles: decoder.articles)
    }
}

private final class FeedXMLDecoder: NSObject, XMLParserDelegate {
    private struct Entry {
        var id = ""
        var title = ""
        var summary = ""
        var link: URL?
        var date: Date?
    }

    private struct Capture {
        let name: String
        let depth: Int
        let base: URL
        var value = ""
    }

    private let address: URL
    private var path: [String] = []
    private var bases: [URL] = []
    private var entry: Entry?
    private var capture: Capture?
    private var seen = Set<String>()
    private(set) var isFeed = false
    private(set) var title = ""
    private(set) var articles: [SubscriptionFeed.Article] = []

    init(address: URL) { self.address = address }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let name = elementName.lowercased()
        let base = bases.last ?? address
        let parent = path.last
        path.append(name)
        bases.append(attributes["xml:base"].flatMap { feedURL($0, relativeTo: base) } ?? base)

        if path.count == 1 { isFeed = ["rss", "feed", "rdf"].contains(name) }
        if (name == "entry" && path.count == 2 && parent == "feed") ||
            (name == "item" && (parent == "channel" || parent == "rdf")) {
            if articles.count < 200 { entry = Entry() }
            return
        }
        if let parent, entry != nil, parent == "item" || parent == "entry" {
            if name == "link", let href = attributes["href"] {
                if attributes["rel"] == nil || attributes["rel"] == "alternate" {
                    entry?.link = feedURL(href, relativeTo: bases.last ?? base)
                }
            } else if ["id", "guid", "title", "link", "description", "summary", "content", "encoded", "pubdate", "date", "published", "updated"].contains(name) {
                capture = Capture(name: name, depth: path.count, base: bases.last ?? base)
            }
        } else if name == "title", (path.count == 2 && parent == "feed") || (path.count == 3 && parent == "channel") {
            capture = Capture(name: name, depth: path.count, base: bases.last ?? base)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let value = String(data: data, encoding: .utf8) { append(value) }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = path.dropLast().last
        if let field = capture, field.depth == path.count {
            capture = nil
            use(field)
        }
        if let entry, (path.last == "entry" && parent == "feed") ||
            (path.last == "item" && (parent == "channel" || parent == "rdf")) {
            self.entry = nil
            add(entry)
        }
        _ = path.popLast()
        _ = bases.popLast()
    }

    private func append(_ value: String) {
        guard let length = capture?.value.utf8.count, length < 8192 else { return }
        capture?.value += String(value.prefix(8192 - length))
    }

    private func use(_ capture: Capture) {
        let value = capture.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if entry == nil {
            if capture.name == "title" { title = plain(value) }
            return
        }
        switch capture.name {
        case "id", "guid": entry?.id = value
        case "title": entry?.title = plain(value)
        case "link": entry?.link = feedURL(value, relativeTo: capture.base)
        case "description", "summary": entry?.summary = plain(value)
        case "encoded", "content":
            if entry?.summary.isEmpty == true { entry?.summary = plain(value) }
        case "date", "pubdate", "published":
            if let date = date(value) { entry?.date = date }
        case "updated":
            if entry?.date == nil { entry?.date = date(value) }
        default: break
        }
    }

    private func add(_ entry: Entry) {
        guard !entry.title.isEmpty || !entry.summary.isEmpty || entry.link != nil else { return }
        let identifier = entry.id.nilIfBlank ?? entry.link?.absoluteString ?? "entry-\(articles.count)"
        guard seen.insert(identifier).inserted else { return }
        articles.append(.init(
            id: identifier,
            title: entry.title.nilIfBlank ?? entry.link?.host ?? "无标题",
            summary: String(entry.summary.prefix(2400)),
            url: entry.link,
            publishedAt: entry.date
        ))
    }

    private func plain(_ value: String) -> String { (try? readableHTML(value)) ?? value }

    private func date(_ value: String) -> Date? {
        if let result = try? Date.ISO8601FormatStyle().parse(value) { return result }
        if let result = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return result }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let result = formatter.date(from: value) { return result }
        }
        return nil
    }
}

private func feedURL(_ value: String, relativeTo base: URL?) -> URL? {
    guard let address = value.nilIfBlank,
          let url = URL(string: address, relativeTo: base)?.absoluteURL,
          url.isWebURL, url.user == nil, url.password == nil else { return nil }
    return url
}

private enum FeedError: LocalizedError {
    case invalidAddress, invalidFeed

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入完整的 HTTP 或 HTTPS 订阅地址。"
        case .invalidFeed: "这个地址没有返回有效的 RSS 或 Atom 订阅。"
        }
    }
}
