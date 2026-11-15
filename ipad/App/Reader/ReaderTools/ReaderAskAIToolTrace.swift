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
    }

    let count: Int
    let steps: [Step]

    private static let previewTools: Set<String> = [
        "query_bookshelf", "get_bookshelf_book_info", "list_book_chapters",
        "search_book_chapter_content", "read_book_chapter_content", "list_book_characters"
    ]
    private static let credentialPattern = #"(?i)\b(?:bearer|authorization|password|api[_ -]?key)\b|\b(?:sk|ghp|github_pat)[-_][a-z0-9_-]+|\b[a-z0-9_-]{24,}\b"#

    static func acceptsArguments(for tool: String) -> Bool { previewTools.contains(tool) }

    static func argumentsPreview(_ raw: String, context: ReaderAskAIContext) -> String? {
        guard raw.utf8.count <= 8_192, let decoded = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let arguments = decoded as? [String: Any] else { return nil }
        let trustedText = [context.bookTitle, context.author, context.chapterTitle, context.excerpt]
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

    private static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }
}
