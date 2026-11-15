import CoreFoundation
import Foundation

struct ReaderAskAIToolTrace: Codable {
    struct Step: Codable, Identifiable {
        enum Status: String, Codable {
            case running, succeeded, failed, interrupted
        }

        let id: UUID
        let name: String
        let argumentsPreview: String?
        var status: Status
        var resultPreview: String? = nil
        var attempts: Int? = nil
    }

    let count: Int
    let steps: [Step]

    private static let previewTools: Set<String> = [
        "query_bookshelf", "get_bookshelf_book_info", "list_book_chapters",
        "search_book_chapter_content", "read_book_chapter_content", "list_book_characters"
    ]
    private static let credentialPattern = #"(?i)\b(?:bearer|authorization|password|api[_ -]?key)\b|\b(?:sk|ghp|github_pat)[-_][a-z0-9_-]+|\b[a-z0-9_-]{24,}\b"#

    static func acceptsArguments(for tool: String) -> Bool { previewTools.contains(tool) }

    static func argumentsPreview(_ raw: String, context: ReaderAskAIContext, question: String = "") -> String? {
        guard raw.utf8.count <= 8_192, let decoded = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let arguments = decoded as? [String: Any] else { return nil }
        let trustedText = [context.bookTitle, context.author, context.chapterTitle, context.excerpt, question]
            .filter { !$0.isEmpty }
            .map(normalized)
        let approvedText = ["query", "keyword", "name", "bookName", "author", "chapterTitle"]
        let approvedNumbers = [
            "chapterIndex", "offset", "limit", "startIndex", "endIndex", "startChapterIndex",
            "maxResults", "maxScanChapters", "maxChars", "contextChars"
        ]
        var displayed: [String: Any] = [:]
        for key in approvedText {
            guard let value = arguments[key] as? String, (1...64).contains(value.count),
                  value.rangeOfCharacter(from: .controlCharacters) == nil,
                  value.range(of: credentialPattern, options: .regularExpression) == nil else { continue }
            let term = normalized(value)
            guard !term.isEmpty, trustedText.contains(where: { $0.contains(term) }) else { continue }
            displayed[key] = value
        }
        for key in approvedNumbers {
            guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  let integer = Int(exactly: value.doubleValue), (0...1_000_000).contains(integer) else { continue }
            displayed[key] = integer
        }
        if let scope = arguments["scope"] as? String, ["near_current", "all_cached"].contains(scope) {
            displayed["scope"] = scope
        }
        guard !displayed.isEmpty, let json = try? ReaderAITool.json(displayed) else { return nil }
        return json.count > 200 ? String(json.prefix(199)) + "…" : json
    }

    static func resultPreview(for tool: String, result: [String: Any]?, succeeded: Bool) -> String? {
        guard previewTools.contains(tool) else { return nil }
        guard succeeded, let result else { return "工具未返回可用结果。" }
        switch tool {
        case "query_bookshelf":
            let size = count(in: result["matchedBooks"])
            let total = (result["summary"] as? [String: Any]).flatMap { number($0["bookCount"]) }
            return ["命中 \(size) 本", total.map { "书架共 \($0) 本" }].compactMap { $0 }.joined(separator: " · ")
        case "get_bookshelf_book_info":
            return "返回 \(count(in: result["books"])) 本书的资料"
        case "list_book_chapters":
            let chapters = result["chapters"] as? [[String: Any]] ?? []
            let cached = chapters.filter { $0["cached"] as? Bool == true }.count
            return "返回 \(chapters.count) 章目录，其中 \(cached) 章有缓存"
        case "search_book_chapter_content":
            let chapters = number(result["scannedChapters"]) ?? 0
            let cached = number(result["scannedCachedContent"]) ?? 0
            let matches = result["results"] as? [[String: Any]] ?? []
            let indices = matches.prefix(8).compactMap { number($0["chapterIndex"]) }.map { String($0 + 1) }
            let locations = indices.isEmpty ? "" : " · 章序 \(indices.joined(separator: "、"))"
            return "扫描范围 \(chapters) 章 · 查到 \(cached) 章缓存正文 · \(matches.count) 处命中\(locations)"
        case "read_book_chapter_content":
            let chapter = result["chapter"] as? [String: Any]
            let index = number(chapter?["index"])
            let source = index.map { "第 \($0 + 1) 章 · " } ?? ""
            let length = (result["content"] as? String)?.utf16.count ?? 0
            let truncated = result["truncated"] as? Bool == true ? " · 已按长度截断" : ""
            return "\(source)返回 \(length) 字\(truncated)"
        case "list_book_characters":
            return "返回 \(count(in: result["characters"])) 条角色资料"
        default:
            return nil
        }
    }

    private static func number(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              let integer = Int(exactly: value.doubleValue), (0...1_000_000).contains(integer) else { return nil }
        return integer
    }

    private static func count(in value: Any?) -> Int { (value as? [Any])?.count ?? 0 }

    private static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }
}
