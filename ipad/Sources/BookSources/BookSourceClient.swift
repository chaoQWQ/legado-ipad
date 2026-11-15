import Foundation

public struct BookSourceClient: Sendable {
    typealias Transport = @Sendable (URLRequest, Bool) async throws -> (Data, URLResponse)

    private let transport: Transport
    private static let responseLimit = 8 * 1024 * 1024
    private static let pagesLimit = 40

    public init() {
        let sessionWithCookies = Self.makeSession(usesCookies: true)
        let sessionWithoutCookies = Self.makeSession(usesCookies: false)
        transport = { request, usesCookies in
            let session = usesCookies ? sessionWithCookies : sessionWithoutCookies
            let (bytes, response) = try await session.bytes(for: request)
            try Self.check(response)
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.responseLimit else { throw BookSourceError.responseTooLarge }
                data.append(byte)
            }
            return (data, response)
        }
    }

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    public func search(_ keyword: String, in source: BookSource) async throws -> [SourceBook] {
        try check(source)
        guard let keyword = keyword.nilIfBlank else { return [] }
        guard let searchURL = source.searchURL?.nilIfBlank else { throw BookSourceError.missingRule("搜索") }
        let request = try SourceRequest.parse(searchURL, relativeTo: source.baseURL, field: "搜索", keyword: keyword)
        let page = try await load(request, in: source)
        let matchesDetails = try matchesBookURL(page.url, pattern: source.bookURLPattern)
        let listing = source.searchRule?.bookList?.nilIfBlank
        if matchesDetails || (listing == nil && source.bookURLPattern?.nilIfBlank == nil) {
            guard let book = try directResult(page, requested: request, from: source) else { return [] }
            return [book]
        }
        guard let rule = source.searchRule, var listing else { throw BookSourceError.missingRule("搜索结果列表") }
        let isReversed = listing.hasPrefix("-")
        if isReversed || listing.hasPrefix("+") { listing.removeFirst() }
        let nodes = try page.root.select(listing, field: "搜索结果列表")
        if nodes.isEmpty, source.bookURLPattern?.nilIfBlank == nil,
           let book = try directResult(page, requested: request, from: source) {
            return [book]
        }
        let ordered = isReversed ? Array(nodes.reversed()) : nodes
        var seen = Set<String>()
        return try ordered.compactMap { node in
            let title = try node.string(rule.name, field: "书名")
            guard !title.isEmpty else { return nil }
            let address = try node.strings(rule.bookUrl, field: "书籍链接").first
            let bookRequest: SourceRequest
            do {
                bookRequest = try resolvedRequest(address, page: page, requested: request, field: "书籍")
            } catch BookSourceError.invalidURL {
                return nil
            }
            guard seen.insert(bookRequest.identity).inserted else { return nil }
            return SourceBook(
                title: title,
                author: try node.string(rule.author, field: "作者"),
                introduction: try readableHTML(node.string(rule.intro, field: "简介")),
                coverURL: try imageURL(node.strings(rule.coverUrl, field: "封面").first, relativeTo: page.url),
                bookRequest: bookRequest,
                sourceID: source.id
            )
        }
    }

    public func details(for book: SourceBook, in source: BookSource) async throws -> SourceBook {
        try check(source, matches: book)
        guard let rule = source.infoRule else { return book }
        let page = try await load(book.bookRequest, in: source)
        return try applyDetails(rule, to: book, page: page)
    }

    private func directResult(_ page: Page, requested: SourceRequest, from source: BookSource) throws -> SourceBook? {
        guard let rule = source.infoRule else { return nil }
        let request = try resolvedRequest(nil, page: page, requested: requested, field: "书籍")
        let book = SourceBook(title: "", author: "", introduction: "", coverURL: nil, bookRequest: request, sourceID: source.id)
        let result = try applyDetails(rule, to: book, page: page)
        return result.title.isEmpty ? nil : result
    }

    private func matchesBookURL(_ url: URL, pattern: String?) throws -> Bool {
        guard let pattern = pattern?.nilIfBlank else { return false }
        guard let regex = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else {
            throw BookSourceError.invalidRule("详情地址匹配")
        }
        let address = url.absoluteString
        return regex.firstMatch(in: address, range: NSRange(address.startIndex..<address.endIndex, in: address)) != nil
    }

    private func resolvedRequest(_ address: String?, page: Page, requested: SourceRequest, field: String) throws -> SourceRequest {
        if let address { return try SourceRequest.parse(address, relativeTo: page.url, field: field) }
        return requested.url == page.url ? requested : SourceRequest(url: page.url)
    }

    private func applyDetails(_ rule: InfoRule, to book: SourceBook, page: Page) throws -> SourceBook {
        let root: RuleValue
        if let initRule = rule.`init`?.nilIfBlank {
            guard let selected = try page.root.select(initRule, field: "详情初始化").first else {
                throw BookSourceError.invalidRule("详情初始化")
            }
            root = selected
        } else {
            root = page.root
        }
        var result = book
        if let title = try root.string(rule.name, field: "书名").nilIfBlank { result.title = title }
        if let author = try root.string(rule.author, field: "作者").nilIfBlank { result.author = author }
        if let introduction = try readableHTML(root.string(rule.intro, field: "简介")).nilIfBlank { result.introduction = introduction }
        if let cover = try imageURL(root.strings(rule.coverUrl, field: "封面").first, relativeTo: page.url) { result.coverURL = cover }
        if let toc = try root.strings(rule.tocUrl, field: "目录地址").first {
            result.tocRequest = try SourceRequest.parse(toc, relativeTo: page.url, field: "目录")
        }
        return result
    }

    public func chapters(for book: SourceBook, in source: BookSource) async throws -> [SourceChapter] {
        try check(source, matches: book)
        guard let rule = source.tocRule, var listing = rule.chapterList?.nilIfBlank else {
            throw BookSourceError.missingRule("目录")
        }
        if rule.preUpdateJs?.nilIfBlank != nil || rule.formatJs?.nilIfBlank != nil {
            throw BookSourceError.unsupported("目录 JavaScript")
        }
        let isReversed = listing.hasPrefix("-")
        if isReversed || listing.hasPrefix("+") { listing.removeFirst() }

        var chapters: [SourceChapter] = []
        var seen = Set<String>()
        var traversal = Pagination(start: book.tocRequest ?? book.bookRequest)
        while let request = try traversal.next() {
            let page = try await load(request, in: source)
            let items = try page.root.select(listing, field: "章节列表")
            for item in items {
                let name = try item.string(rule.chapterName, field: "章节名")
                guard !name.isEmpty, let link = try item.strings(rule.chapterUrl, field: "章节链接").first else { continue }
                do {
                    let chapterRequest = try SourceRequest.parse(link, relativeTo: page.url, field: "章节")
                    if seen.insert(chapterRequest.identity).inserted {
                        chapters.append(SourceChapter(title: name, request: chapterRequest))
                    }
                } catch BookSourceError.invalidURL {
                    continue
                }
            }
            let links = try page.root.strings(rule.nextTocUrl, field: "目录下一页")
            try traversal.append(links, relativeTo: page.url, field: "目录下一页")
        }
        guard !chapters.isEmpty else { throw BookSourceError.emptyChapters }
        if isReversed { chapters.reverse() }
        for index in chapters.indices.dropLast() {
            chapters[index].nextChapterURL = chapters[index + 1].url
        }
        return chapters
    }

    public func content(
        of chapter: SourceChapter, in source: BookSource, bypassCache: Bool = false, applyingTextConversion: Bool = true
    ) async throws -> String {
        try check(source)
        guard let rule = source.contentRule, let content = rule.content?.nilIfBlank else {
            throw BookSourceError.missingRule("正文")
        }
        if rule.webJs?.nilIfBlank != nil || rule.sourceRegex?.nilIfBlank != nil {
            throw BookSourceError.unsupported("网页渲染或正文定位脚本")
        }
        var pages: [String] = []
        var totalBytes = 0
        var traversal = Pagination(start: chapter.request)
        while let request = try traversal.next() {
            let page = try await load(request, in: source, bypassCache: bypassCache)
            let main = try readableHTML(page.root.string(content, field: "正文"))
            let supplement = try readableHTML(page.root.string(rule.subContent, field: "副文"))
            let text = [main, supplement].filter { !$0.isEmpty }.joined(separator: "\n\n")
            totalBytes += text.utf8.count
            guard totalBytes <= Self.responseLimit else { throw BookSourceError.responseTooLarge }
            if !text.isEmpty { pages.append(text) }
            let links = try page.root.strings(rule.nextContentUrl, field: "正文下一页")
            try traversal.append(links, relativeTo: page.url, field: "正文下一页", stoppingAt: chapter.nextChapterURL)
        }
        let formatted = try applyReplacement(rule.replaceRegex, to: pages.joined(separator: "\n\n"),
                                             applyingTextConversion: applyingTextConversion).trimmed
        guard !formatted.isEmpty else { throw BookSourceError.emptyContent }
        return formatted
    }

    private func check(_ source: BookSource, matches book: SourceBook? = nil) throws {
        guard source.type == 0 else { throw BookSourceError.unsupported("非文本书源") }
        guard book == nil || book?.sourceID == source.id else { throw BookSourceError.invalidSource }
        if source.loginCheck?.nilIfBlank != nil { throw BookSourceError.unsupported("登录检测 JavaScript") }
    }

    private static func makeSession(usesCookies: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 50
        configuration.httpShouldSetCookies = usesCookies
        if !usesCookies { configuration.httpCookieStorage = nil }
        return URLSession(configuration: configuration)
    }

    private static func check(_ response: URLResponse) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, response.url?.isWebURL == true else {
            throw BookSourceError.invalidResponse
        }
        guard (200..<300).contains(status) else { throw BookSourceError.badStatus(status) }
        guard response.expectedContentLength <= responseLimit else { throw BookSourceError.responseTooLarge }
    }

    private func load(_ request: SourceRequest, in source: BookSource, bypassCache: Bool = false) async throws -> Page {
        var urlRequest = try request.request(sourceHeaders: source.headers)
        if bypassCache {
            urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
            urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        let (data, response) = try await transport(urlRequest, source.usesCookies)
        try Self.check(response)
        guard data.count <= Self.responseLimit else { throw BookSourceError.responseTooLarge }
        guard let url = response.url, let text = Self.responseText(data, response: response) else {
            throw BookSourceError.invalidResponse
        }
        return try Page(root: RuleValue.document(text), url: url)
    }

    private static func responseText(_ data: Data, response: URLResponse) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        let prefix = String(decoding: data.prefix(4_096), as: UTF8.self)
        let charsetRange = prefix.range(of: #"charset\s*=\s*["']?([\w-]+)"#, options: [.regularExpression, .caseInsensitive])
        let documentEncoding = charsetRange.map { String(prefix[$0]).split(separator: "=").last.map(String.init) ?? "" }
        let name = response.textEncodingName ?? documentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r'\""))
        if let name, let encoding = stringEncoding(name), let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(data: data, encoding: .utf8)
            ?? stringEncoding("gb18030").flatMap { String(data: data, encoding: $0) }
    }

    private func imageURL(_ address: String?, relativeTo baseURL: URL) throws -> URL? {
        guard let address else { return nil }
        return try? SourceRequest.parse(address, relativeTo: baseURL, field: "封面").url
    }

    private struct Page {
        let root: RuleValue
        let url: URL
    }

    private struct Pagination {
        private var queue: [SourceRequest]
        private var visited: Set<String>
        private var index = 0

        init(start: SourceRequest) {
            queue = [start]
            visited = [start.identity]
        }

        mutating func next() throws -> SourceRequest? {
            guard index < queue.count else { return nil }
            guard index < pagesLimit else { throw BookSourceError.paginationLimit }
            defer { index += 1 }
            return queue[index]
        }

        mutating func append(_ links: [String], relativeTo base: URL, field: String, stoppingAt end: URL? = nil) throws {
            for link in links {
                if link.hasPrefix("#") { continue }
                let request: SourceRequest
                do {
                    request = try SourceRequest.parse(link, relativeTo: base, field: field)
                } catch BookSourceError.invalidURL {
                    continue
                }
                if request.url == end { break }
                if visited.insert(request.identity).inserted {
                    guard queue.count < pagesLimit else { throw BookSourceError.paginationLimit }
                    queue.append(request)
                }
            }
        }
    }
}
