import Foundation

@MainActor
enum ReaderAILibraryTools {
    static let names: Set<String> = [
        "query_bookshelf", "get_bookshelf_book_info", "list_book_chapters",
        "read_book_chapter_content", "search_book_chapter_content"
    ]

    static func tools(library: LibraryStore?) -> [ReaderAITool] {
        let text = ["type": "string"]
        let number = ["type": "integer"]
        let book = ["bookUrl": text, "name": text, "author": text]
        let paging = ["offset": number, "limit": number]
        return [
            make("query_bookshelf", "按书名或作者查找书架上的书。", ["query": text, "limit": number]) { args in
                let query = args.string("query")
                let books = library?.books.filter { item in
                    query.isEmpty || [item.title, item.author].contains { $0.localizedCaseInsensitiveContains(query) }
                } ?? []
                return ["count": books.count, "books": books.prefix(args.limit(20)).map { summary($0, library: library) }]
            },
            make("get_bookshelf_book_info", "按书架书籍 ID（bookUrl）或书名查询书籍和当前阅读进度。", book) { args in
                guard let item = find(args, in: library) else { return missingBook }
                return ["book": summary(item, library: library)]
            },
            make("list_book_chapters", "列出书架书籍的目录。返回的 chapterIndex 从 0 开始。", book.merging(paging) { first, _ in first }) { args in
                guard let item = find(args, in: library) else { return missingBook }
                let chapters = item.chapters.enumerated().dropFirst(args.offset).prefix(args.limit(100)).map { index, chapter in
                    ["index": index, "title": chapter.title] as [String: Any]
                }
                return ["count": item.chapters.count, "chapters": chapters]
            },
            make("read_book_chapter_content", "阅读已经缓存的本地正文，chapterIndex 和 offset 都从 0 开始。", book.merging([
                "chapterIndex": number, "offset": number, "maxChars": number
            ]) { first, _ in first }) { args in
                guard let library, let item = find(args, in: library) else { return missingBook }
                let index = args.integer("chapterIndex") ?? library.position(for: item.id).chapterIndex
                guard item.chapters.indices.contains(index) else { return ["ok": false, "error": "章节不存在。"] }
                guard let content = try await library.cachedChapter(in: item, at: index) else {
                    return ["ok": false, "error": "这一章尚未缓存。请在阅读页先打开或下载。"]
                }
                let limit = min(12_000, max(1, args.integer("maxChars") ?? 6_000))
                let chunk = String(content.dropFirst(args.offset).prefix(limit))
                return ["chapterIndex": index, "chapterTitle": item.chapters[index].title, "content": chunk,
                        "offset": args.offset, "hasMore": max(0, content.count - args.offset) > chunk.count]
            },
            make("search_book_chapter_content", "在书架上某本书的已缓存正文中搜索关键词。", book.merging([
                "query": text, "keyword": text, "startChapterIndex": number, "limit": number
            ]) { first, _ in first }) { args in
                guard let library, let item = find(args, in: library) else { return missingBook }
                let query = args.string("query").isEmpty ? args.string("keyword") : args.string("query")
                guard !query.isEmpty else { return ["ok": false, "error": "请提供搜索关键词。"] }
                let start = min(item.chapters.count, max(0, args.integer("startChapterIndex") ?? 0))
                let end = min(item.chapters.count, start + 100)
                var matches: [[String: Any]] = []
                var checked = start
                for index in start..<end {
                    try Task.checkCancellation()
                    checked = index + 1
                    guard let content = try await library.cachedChapter(in: item, at: index),
                          let match = content.range(of: query, options: [.caseInsensitive]) else { continue }
                    let before = content[..<match.lowerBound].suffix(72)
                    let after = content[match.upperBound...].prefix(112)
                    matches.append(["chapterIndex": index, "chapterTitle": item.chapters[index].title,
                                    "excerpt": String(before) + content[match] + after])
                    if matches.count >= args.limit(20) { break }
                }
                return ["matches": matches, "nextChapterIndex": checked, "hasMore": checked < item.chapters.count]
            }
        ]
    }

    private static let missingBook = ["ok": false, "error": "找不到这本书。可先调用 query_bookshelf。"] as [String: Any]

    private static func make(
        _ name: String, _ description: String, _ properties: [String: Any],
        handler: @escaping @MainActor (Arguments) async throws -> [String: Any]
    ) -> ReaderAITool {
        ReaderAITool(name: name, description: description, parameters: [
            "type": "object", "properties": properties, "additionalProperties": false
        ]) { raw in
            let data = try JSONSerialization.jsonObject(with: Data(raw.utf8))
            guard let object = data as? [String: Any] else { return ReaderAITool.failure("参数必须是 JSON 对象。") }
            return try await ReaderAITool.json(handler(Arguments(values: object)))
        }
    }

    private static func find(_ args: Arguments, in library: LibraryStore?) -> LibraryBook? {
        if let id = UUID(uuidString: args.string("bookUrl")) { return library?.currentBook(id) }
        let title = args.string("name")
        let author = args.string("author")
        guard !title.isEmpty || !author.isEmpty else { return nil }
        return library?.books.first { item in
            (title.isEmpty || item.title.localizedCaseInsensitiveContains(title))
                && (author.isEmpty || item.author.localizedCaseInsensitiveContains(author))
        }
    }

    private static func summary(_ book: LibraryBook, library: LibraryStore?) -> [String: Any] {
        let position = library?.position(for: book.id) ?? ReaderPosition()
        return ["bookUrl": book.id.uuidString, "name": book.title, "author": book.author,
                "chapterCount": book.chapters.count, "chapterIndex": position.chapterIndex, "offset": position.offset]
    }

    private struct Arguments {
        let values: [String: Any]
        func string(_ key: String) -> String { (values[key] as? String)?.aiTrimmed ?? "" }
        func integer(_ key: String) -> Int? { values[key] as? Int }
        func limit(_ maximum: Int) -> Int { min(maximum, max(1, integer("limit") ?? maximum)) }
        var offset: Int { max(0, integer("offset") ?? 0) }
    }
}
