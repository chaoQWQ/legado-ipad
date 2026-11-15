import Foundation

@MainActor
enum ReaderAILibraryTools {
    private static let timeFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = .autoupdatingCurrent
        format.dateFormat = "yyyy-MM-dd HH:mm"
        return format
    }()

    static let names: Set<String> = [
        "query_bookshelf", "get_bookshelf_book_info", "list_book_chapters",
        "read_book_chapter_content", "search_book_chapter_content", "list_book_characters"
    ]

    static func tools(library: LibraryStore?) -> [ReaderAITool] {
        let book = [
            "bookUrl": string("书籍 URL，优先用于精确定位。iPad 本地书使用书籍 ID。"),
            "name": string("书名。没有 URL 时使用。"),
            "author": string("作者名，可选，用于缩小书名匹配范围。")
        ]
        return [
            make("query_bookshelf", "查询用户本地书架，返回匹配书籍、最近阅读和未读章节等真实数据。", [
                "query": string("要查找的书名、作者、书源名或问题关键词。留空时返回整体书架概况。"),
                "limit": integer("每个列表最多返回多少项，默认 6。", within: 1...20)
            ]) { args in
                queryShelf(args, library: library)
            },
            make("get_bookshelf_book_info", "按书籍 URL、书名或作者查询书架中书籍的简介、封面、书源和阅读进度。",
                 book.merging([
                     "bookUrls": strings("批量查询时传多个书籍 URL。"),
                     "names": strings("批量查询时传多个书名。")
                 ]) { original, _ in original }) { args in
                getBookInfo(args, library: library)
            },
            make("list_book_chapters", "读取指定书籍的章节目录，可按关键词筛选并返回章节索引、标题和缓存状态。",
                 book.merging([
                     "keyword": string("可选，按章节标题模糊筛选。"),
                     "limit": integer("最多返回多少章目录，默认 80。", within: 1...200),
                     "offset": integer("可选，跳过筛选后开头的多少项。")
                 ]) { original, _ in original }) { args in
                guard let library, let item = resolve(args, library: library) else { return missingBook }
                return try await listChapters(args, book: item, library: library)
            },
            make("read_book_chapter_content", "读取指定书籍某章的正文。可按章节索引或标题定位，支持限制返回长度。没有缓存时通过该书书源读取。",
                 book.merging([
                     "chapterIndex": integer("全书章节索引，从 0 开始。"),
                     "chapterTitle": string("章节标题。未传 chapterIndex 时使用。"),
                     "maxChars": integer("正文最大返回字符数，默认 4000。", within: 200...20_000),
                     "offset": integer("可选，从正文中指定的字符位置开始返回。")
                 ]) { original, _ in original }) { args in
                guard let library, let item = resolve(args, library: library) else { return missingBook }
                return try await readChapter(args, book: item, library: library)
            },
            make("search_book_chapter_content", "在本地书架指定书籍的章节标题和已缓存正文中搜索关键词，返回少量命中片段。需要补充角色记忆或查找剧情细节时优先用它，再按需读取整章。",
                 book.merging([
                     "keyword": string("要搜索的剧情、人物、地点或台词关键词。"),
                     "scope": string("near_current 默认只搜当前阅读章节附近。all_cached 从书籍开头扫描更广的范围。",
                                     choices: ["near_current", "all_cached"]),
                     "startIndex": integer("可选，起始章节索引，从 0 开始。显式范围优先。"),
                     "endIndex": integer("可选，结束章节索引，包含此章。"),
                     "maxScanChapters": integer("最多扫描多少章。默认 near_current 为 240，all_cached 为 800。",
                                                within: 20...1_200),
                     "maxResults": integer("最多返回多少个命中片段，默认 8。", within: 1...20),
                     "contextChars": integer("每个命中前后各保留多少字符，默认 180。", within: 60...600)
                 ]) { original, _ in original }, required: ["keyword"]) { args in
                guard let library, let item = resolve(args, library: library) else { return missingBook }
                return try await searchChapters(args, book: item, library: library)
            },
            make("list_book_characters", "读取指定书籍已有的角色资料，含身份、技能、性格、形象和生平。优先传 bookUrl，或传 bookName 和 author。", [
                "bookUrl": string("书籍 URL，优先用于精确定位当前书。"),
                "bookName": string("书名。没有 bookUrl 时使用。"),
                "author": string("作者名。")
            ]) { args in
                guard let library, let item = resolveCharacterBook(args, library: library) else { return missingBook }
                let characters = try await ReaderBookCharacterStore.shared.characters(for: item.id)
                var info = summary(item, in: library)
                info["origin"] = item.sourceID.flatMap(publicAddress)
                info["originName"] = library.sourceName(for: item)
                return [
                    "ok": true, "book": info, "characters": characters.map(\.toolProfile)
                ]
            }
        ]
    }

    private static func string(_ description: String, choices: [String]? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let choices { schema["enum"] = choices }
        return schema
    }

    private static func strings(_ description: String) -> [String: Any] {
        ["type": "array", "description": description, "items": ["type": "string"]]
    }

    private static func integer(_ description: String, within bounds: ClosedRange<Int>? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer", "description": description]
        if let bounds {
            schema["minimum"] = bounds.lowerBound
            schema["maximum"] = bounds.upperBound
        }
        return schema
    }

    /// The public book detail address doubles as Android's tool identifier.
    /// Keep the existing shelf UUID for local books and private URLs.
    static func bookURL(for book: LibraryBook) -> String {
        guard let onlineID = book.onlineID else { return book.id.uuidString }
        let address = onlineBookAddress(in: onlineID, sourceID: book.sourceID) ?? onlineID
        return publicAddress(address) ?? book.id.uuidString
    }

    private static let missingBook: [String: Any] = ["ok": false, "error": "未找到书籍，可先调用 query_bookshelf。"]
    private static let missingChapter = ["ok": false, "error": "未找到章节。"] as [String: Any]

    private static func make(
        _ name: String, _ description: String, _ properties: [String: Any], required: [String] = [],
        handler: @escaping @MainActor (Arguments) async throws -> [String: Any]
    ) -> ReaderAITool {
        var schema: [String: Any] = [
            "type": "object", "properties": properties, "additionalProperties": false
        ]
        if !required.isEmpty { schema["required"] = required }
        return ReaderAITool(name: name, description: description, parameters: schema, invoke: { raw in
            let data = try JSONSerialization.jsonObject(with: Data(raw.utf8))
            guard let object = data as? [String: Any] else { return ReaderAITool.failure("参数必须是 JSON 对象。") }
            return try await ReaderAITool.json(handler(Arguments(values: object)))
        }, retriesTransientReads: true)
    }

    private static func queryShelf(_ args: Arguments, library: LibraryStore?) -> [String: Any] {
        let books = library?.books ?? []
        let query = args.string("query")
        let limit = args.clamped("limit", fallback: 6, to: 1...20)
        let ranked = byLastRead(books, library: library)
        let matched = matchingBooks(query, in: ranked, library: library)
        let recent = ranked.filter { library?.hasPosition(for: $0.id) == true }.prefix(limit)
        let unread = ranked.filter { unreadCount($0, in: library) > 0 }
            .sorted { unreadCount($0, in: library) > unreadCount($1, in: library) }
        let lastRead: Any = recent.first.map { summary($0, in: library) as Any } ?? NSNull()
        return [
            "ok": true, "query": query, "count": query.isEmpty ? books.count : matched.count,
            "books": (query.isEmpty ? ranked : matched).prefix(limit).map { summary($0, in: library) },
            "matchedBooks": matched.prefix(limit).map { summary($0, in: library) },
            "recentReading": recent.map { summary($0, in: library) },
            "unreadRanking": unread.prefix(limit).map { summary($0, in: library) },
            "summary": [
                "bookCount": books.count, "localCount": books.filter { $0.sourceID == nil }.count,
                "audioCount": 0, "videoCount": 0,
                "unreadChapterCount": books.reduce(0) { $0 + unreadCount($1, in: library) },
                "lastReadBook": lastRead
            ] as [String: Any]
        ]
    }

    private static func getBookInfo(_ args: Arguments, library: LibraryStore?) -> [String: Any] {
        guard let library else { return missingBook }
        let urls = Set(args.strings("bookUrls") + [args.string("bookUrl")].filter { !$0.isEmpty })
        let titles = args.strings("names")
        var matches: [LibraryBook] = []
        if !urls.isEmpty {
            matches = library.books.filter { urls.contains(bookURL(for: $0)) || urls.contains($0.id.uuidString) }
        } else if !titles.isEmpty {
            matches = library.books.filter { item in
                titles.contains(where: { !matchingBooks($0, in: [item], library: library).isEmpty })
            }
        }
        let book = matches.count == 1 ? matches.first : resolve(args, library: library)
        if matches.isEmpty, let book { matches = [book] }
        guard !matches.isEmpty else { return missingBook }
        var result: [String: Any] = ["ok": true, "books": matches.prefix(20).map { detail($0, in: library) }]
        if let book { result["book"] = detail(book, in: library) }
        return result
    }

    private static func listChapters(
        _ args: Arguments, book: LibraryBook, library: LibraryStore
    ) async throws -> [String: Any] {
        let keyword = args.string("keyword")
        let cache = try await library.cachedChapterIndexes(in: book)
        let indices = book.chapters.indices.filter {
            keyword.isEmpty || titleMatches(keyword, in: book, at: $0, library: library)
        }
        let limit = args.clamped("limit", fallback: 80, to: 1...200)
        let offset = min(indices.count, max(0, args.integer("offset") ?? 0))
        let listed = indices.dropFirst(offset).prefix(limit).map { index -> [String: Any] in
            var row = chapterInfo(book, at: index, in: library)
            row["cached"] = cache.contains(index)
            if let address = book.chapters[index].online?.url.absoluteString,
               let safeAddress = publicAddress(address) {
                row["url"] = safeAddress
            }
            return row
        }
        return ["ok": true, "book": summary(book, in: library), "chapterCount": book.chapters.count,
                "count": indices.count, "chapters": listed]
    }

    private static func readChapter(
        _ args: Arguments, book: LibraryBook, library: LibraryStore
    ) async throws -> [String: Any] {
        let name = args.string("chapterTitle")
        let index: Int?
        if let requested = args.integer("chapterIndex"), book.chapters.indices.contains(requested) {
            index = requested
        } else if !name.isEmpty {
            index = book.chapters.indices.first { book.chapters[$0].title == name }
                ?? book.chapters.indices.first { title(of: book, at: $0, in: library) == name }
                ?? book.chapters.indices.first { titleMatches(name, in: book, at: $0, library: library) }
        } else {
            index = library.position(for: book.id).chapterIndex
        }
        guard let index, book.chapters.indices.contains(index) else { return missingChapter }
        let raw: String
        do {
            raw = try await library.chapter(in: book, at: index)
        } catch {
            try Task.checkCancellation()
            if ReaderAITool.transientReadFailure(error) != nil { throw error }
            return ["ok": false, "error": "正文未缓存且读取失败。"]
        }
        let content = normalize(raw)
        let length = content.utf16.count
        let offset = min(length, max(0, args.integer("offset") ?? 0))
        let limit = args.clamped("maxChars", fallback: 4_000, to: 200...20_000)
        let end = min(length, offset + limit)
        let excerpt = ReaderContextText.excerpt(in: content, from: offset, to: end) ?? ""
        return ["ok": true, "book": summary(book, in: library), "chapter": chapterInfo(book, at: index, in: library),
                "chapterIndex": index, "chapterTitle": title(of: book, at: index, in: library), "offset": offset,
                "truncated": end < length, "hasMore": end < length, "content": excerpt]
    }

    private static func searchChapters(
        _ args: Arguments, book: LibraryBook, library: LibraryStore
    ) async throws -> [String: Any] {
        let suppliedKeyword = args.string("keyword")
        let keyword = suppliedKeyword.isEmpty ? args.string("query") : suppliedKeyword
        guard !keyword.isEmpty else { return ["ok": false, "error": "keyword 不能为空。"] }
        let usesLegacyArguments = suppliedKeyword.isEmpty || args.integer("startChapterIndex") != nil || args.integer("limit") != nil
        let scope = args.string("scope") == "all_cached" ? "all_cached" : "near_current"
        let maxScan = args.clamped("maxScanChapters", fallback: scope == "all_cached" ? 800 : 240, to: 20...1_200)
        let maxResults = min(20, max(1, args.integer("maxResults") ?? args.integer("limit") ?? 8))
        let context = args.clamped("contextChars", fallback: 180, to: 60...600)
        let current = library.position(for: book.id).chapterIndex
        let indices = searchRange(args, count: book.chapters.count, current: current, scope: scope, maxScan: maxScan)
        let cache = try await library.cachedChapterIndexes(in: book)
        var matches: [[String: Any]] = []
        var scannedCachedContent = 0
        var nextIndex = indices.lowerBound
        for index in indices {
            try Task.checkCancellation()
            nextIndex = index + 1
            let chapterTitle = title(of: book, at: index, in: library)
            let titleHit = titleMatches(keyword, in: book, at: index, library: library)
            let cached = cache.contains(index)
            let content: String
            if cached {
                content = normalize(try await library.cachedChapter(in: book, at: index) ?? "")
            } else {
                content = ""
            }
            if !content.isEmpty { scannedCachedContent += 1 }
            let match = content.range(of: keyword, options: .caseInsensitive)
            if titleHit || match != nil {
                let snippet = match.map { searchSnippet(content, match: $0, context: context) } ?? ""
                var row: [String: Any] = [
                    "chapterIndex": index, "chapterTitle": chapterTitle, "volume": "", "cached": cached,
                    "titleHit": titleHit, "contentHit": match != nil, "snippet": snippet
                ]
                if usesLegacyArguments { row["excerpt"] = snippet }
                matches.append(row)
                if matches.count == maxResults { break }
            }
        }
        var result: [String: Any] = [
            "ok": true, "book": summary(book, in: library), "keyword": keyword, "scope": scope,
            "chapterCount": book.chapters.count, "scannedChapters": indices.count,
            "scannedCachedContent": scannedCachedContent, "resultCount": matches.count, "results": matches
        ]
        if usesLegacyArguments {
            result["matches"] = matches
            result["nextChapterIndex"] = nextIndex
            result["hasMore"] = nextIndex < book.chapters.count
        }
        return result
    }

    private static func searchRange(_ args: Arguments, count: Int, current: Int, scope: String, maxScan: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let startIndex = args.integer("startIndex") ?? args.integer("startChapterIndex")
        let endIndex = args.integer("endIndex")
        if startIndex != nil || endIndex != nil {
            let start = min(count, max(0, startIndex ?? 0))
            let end = max(start, min(count - 1, endIndex ?? count - 1))
            return start..<min(count, start + maxScan, end + 1)
        }
        let start = scope == "all_cached" ? 0 : max(0, min(count - 1, current) - maxScan / 2)
        return start..<min(count, start + maxScan)
    }

    private static func searchSnippet(_ text: String, match: Range<String.Index>, context: Int) -> String {
        let range = NSRange(match, in: text)
        let start = max(0, range.location - context)
        let length = text.utf16.count
        let end = min(length, NSMaxRange(range) + context)
        let excerpt = ReaderContextText.excerpt(in: text, from: start, to: end) ?? ""
        return (start > 0 ? "…" : "") + excerpt + (end < length ? "…" : "")
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?is)(?:&lt;img\b.*?&gt;|<img\b[^>]*>)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolve(_ args: Arguments, library: LibraryStore) -> LibraryBook? {
        if let exact = resolveURL(args.string("bookUrl"), library: library) { return exact }
        let name = args.string("name").isEmpty ? args.string("bookName") : args.string("name")
        let author = args.string("author")
        if !name.isEmpty, !author.isEmpty,
           let book = library.books.first(where: { $0.title == name && $0.author == author }) {
            return book
        }
        let query = [name, author].filter { !$0.isEmpty }.joined(separator: " ")
        return byLastRead(matchingBooks(query, in: library.books, library: library), library: library).first
    }

    private static func resolveCharacterBook(_ args: Arguments, library: LibraryStore) -> LibraryBook? {
        if let exact = resolveURL(args.string("bookUrl"), library: library) { return exact }
        let suppliedName = args.string("bookName")
        let name = suppliedName.isEmpty ? args.string("name") : suppliedName
        guard !name.isEmpty else { return nil }
        let author = args.string("author")
        return library.books.first {
            (name == $0.title || name == library.displayTitle($0.title, sourceID: $0.sourceID))
                && (author.isEmpty || author == $0.author)
        }
    }

    private static func resolveURL(_ url: String, library: LibraryStore) -> LibraryBook? {
        if let id = UUID(uuidString: url), let book = library.currentBook(id) { return book }
        guard !url.isEmpty else { return nil }
        return library.books.first { bookURL(for: $0) == url }
    }

    private static func byLastRead(_ books: [LibraryBook], library: LibraryStore?) -> [LibraryBook] {
        books.sorted {
            (library?.lastReadAt(for: $0.id) ?? .distantPast) > (library?.lastReadAt(for: $1.id) ?? .distantPast)
        }
    }

    private static func matchingBooks(_ query: String, in books: [LibraryBook], library: LibraryStore?) -> [LibraryBook] {
        guard query.utf16.count >= 2 else { return [] }
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let tokens = query.components(separatedBy: separators).filter { $0.utf16.count >= 2 }
        return books.filter { book in
            let fields = [book.title, book.author, library?.sourceName(for: book) ?? ""]
            return fields.contains { field in
                (field.utf16.count >= 2 && query.localizedCaseInsensitiveContains(field))
                    || tokens.contains { field.localizedCaseInsensitiveContains($0) }
            }
        }
    }

    private static func summary(_ book: LibraryBook, in library: LibraryStore?) -> [String: Any] {
        let position = library?.position(for: book.id) ?? ReaderPosition()
        return [
            "bookUrl": bookURL(for: book), "bookId": book.id.uuidString, "name": book.title, "author": book.author,
            "source": book.sourceID == nil ? "本地书籍" : library?.sourceName(for: book) ?? "",
            "currentChapter": title(of: book, at: position.chapterIndex, in: library),
            "latestChapter": title(of: book, at: book.chapters.count - 1, in: library),
            "unreadChapterCount": unreadCount(book, in: library),
            "chapterCount": book.chapters.count, "chapterIndex": position.chapterIndex, "offset": position.offset,
            "lastReadTime": library?.lastReadAt(for: book.id).map { timeFormat.string(from: $0) } ?? ""
        ]
    }

    private static func detail(_ book: LibraryBook, in library: LibraryStore) -> [String: Any] {
        let position = library.position(for: book.id)
        var data = summary(book, in: library)
        data["totalChapterNum"] = book.chapters.count
        data["durChapterIndex"] = position.chapterIndex
        data["durChapterPos"] = position.offset
        data["intro"] = book.introduction ?? ""
        data["tocUrl"] = book.tocURL.flatMap { publicAddress($0.absoluteString) }
        data["origin"] = book.sourceID.flatMap(publicAddress)
        if let address = book.coverURL?.absoluteString, let safeAddress = publicAddress(address) {
            data["coverUrl"] = safeAddress
        }
        return data
    }

    private static func unreadCount(_ book: LibraryBook, in library: LibraryStore?) -> Int {
        let index = max(0, library?.position(for: book.id).chapterIndex ?? 0)
        return max(0, book.chapters.count - index - 1)
    }

    private static func chapterInfo(_ book: LibraryBook, at index: Int, in library: LibraryStore) -> [String: Any] {
        ["index": index, "title": title(of: book, at: index, in: library), "volume": ""]
    }

    private static func title(of book: LibraryBook, at index: Int, in library: LibraryStore?) -> String {
        guard book.chapters.indices.contains(index) else { return "" }
        let title = book.chapters[index].title
        return library?.displayTitle(title, sourceID: book.sourceID) ?? title
    }

    private static func titleMatches(_ keyword: String, in book: LibraryBook, at index: Int, library: LibraryStore) -> Bool {
        let raw = book.chapters[index].title
        return raw.range(of: keyword, options: .caseInsensitive) != nil
            || library.displayTitle(raw, sourceID: book.sourceID).range(of: keyword, options: .caseInsensitive) != nil
    }

    private static func publicAddress(_ address: String) -> String? {
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil else { return nil }
        return components.url?.absoluteString
    }

    private static func onlineBookAddress(in identity: String, sourceID: String?) -> String? {
        let bytes = identity.utf8
        guard let sourceID, let separator = bytes.firstIndex(of: 58),
              let size = Int(String(decoding: bytes[..<separator], as: UTF8.self)),
              size == sourceID.utf8.count else { return nil }
        let payload = bytes[bytes.index(after: separator)...]
        guard payload.starts(with: sourceID.utf8) else { return nil }
        let request = payload.dropFirst(size)
        guard let space = request.firstIndex(of: 32) else { return nil }
        let addressField = request[request.index(after: space)...]
        guard let separator = addressField.firstIndex(of: 58),
              let length = Int(String(decoding: addressField[..<separator], as: UTF8.self)),
              length > 0 else { return nil }
        let addressBytes = addressField[addressField.index(after: separator)...]
        guard length <= addressBytes.count else { return nil }
        return String(bytes: addressBytes.prefix(length), encoding: .utf8)
    }

    private struct Arguments {
        let values: [String: Any]
        func string(_ key: String) -> String { (values[key] as? String)?.aiTrimmed ?? "" }
        func strings(_ key: String) -> [String] {
            (values[key] as? [String] ?? []).map(\.aiTrimmed).filter { !$0.isEmpty }
        }
        func integer(_ key: String) -> Int? { values[key] as? Int }
        func clamped(_ key: String, fallback: Int, to range: ClosedRange<Int>) -> Int {
            min(range.upperBound, max(range.lowerBound, integer(key) ?? fallback))
        }
    }
}
