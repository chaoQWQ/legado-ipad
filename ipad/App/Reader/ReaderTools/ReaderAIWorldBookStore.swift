import Foundation

struct ReaderAIWorldBook: Codable, Identifiable, Sendable {
    struct Binding: Codable, Equatable, Sendable {
        var targetType: String
        var targetKey = ""
        var enabled = true

        static let global = Self(targetType: "global")
        static let readAI = Self(targetType: "companion", targetKey: "read_ai")

        func targets(_ binding: Self) -> Bool {
            targetType == binding.targetType && targetKey == binding.targetKey
        }
    }

    struct Entry: Codable, Identifiable, Sendable {
        var id = UUID().uuidString
        var name = ""
        var content = ""
        var keywords: [String] = []
        var secondaryKeys: [String] = []
        var excludeKeys: [String] = []
        var useRegex = false
        var caseSensitive = false
        var enabled = true
        var constantActive = false
        var priority = 50
        var position: Position = .afterSystemPrompt
        var injectDepth = 4
        var role: ReaderAIChatMessage.Role = .user
        var scanDepth = 8
        var maxMatches = 1
        var order = 0

        enum Position: String, CaseIterable, Codable, Identifiable, Sendable {
            case afterSystemPrompt = "after_system_prompt"
            case beforePrompt = "before_prompt"
            case beforeLastUser = "before_last_user"
            case injectDepth = "inject_depth"

            var id: Self { self }
            var title: String {
                switch self {
                case .afterSystemPrompt: "系统提示之后"
                case .beforePrompt: "对话历史之前"
                case .beforeLastUser: "本轮提问之前"
                case .injectDepth: "按深度插入"
                }
            }
        }
    }

    var id = UUID().uuidString
    var name = ""
    var description = ""
    var version = 1
    var enabled = true
    var maxEntries = 12
    var bindings: [Binding] = []
    var entries: [Entry] = []

    func isBound(to target: Binding) -> Bool { bindings.contains { $0.enabled && $0.targets(target) } }

    mutating func setBinding(_ target: Binding, enabled: Bool) {
        bindings.removeAll { $0.targets(target) }
        if enabled { bindings.append(target) }
    }
}

struct ReaderAIWorldBookInjection: Sendable {
    let message: ReaderAIChatMessage
    let position: ReaderAIWorldBook.Entry.Position
    let depth: Int
}

actor ReaderAIWorldBookStore {
    static let shared = ReaderAIWorldBookStore()

    private let file: URL
    private var cache: [ReaderAIWorldBook]?

    init(file: URL = URL.applicationSupportDirectory.appending(path: "LegadoPad/ReaderAI/world-books.json")) {
        self.file = file
    }

    func books() throws -> [ReaderAIWorldBook] {
        if let cache { return cache }
        let records: [ReaderAIWorldBook]
        do {
            records = try JSONDecoder().decode([ReaderAIWorldBook].self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            records = []
        }
        cache = records
        return records
    }

    func save(_ book: ReaderAIWorldBook) throws {
        var records = try books()
        if let index = records.firstIndex(where: { $0.id == book.id }) {
            records[index] = book
        } else {
            records.append(book)
        }
        try write(records)
    }

    func remove(_ id: String) throws {
        try write(books().filter { $0.id != id })
    }

    func bind(_ target: ReaderAIWorldBook.Binding, to id: String, enabled: Bool) throws {
        guard var book = try books().first(where: { $0.id == id }) else { return }
        book.setBinding(target, enabled: enabled)
        try save(book)
    }

    func importBooks(from url: URL) throws -> Int {
        let data = try ReaderAIContextFiles.importData(from: url)
        let records = try Self.decodeImport(data, isAndroidPreferences: url.pathExtension.lowercased() == "xml")
        var combined = try books()
        var ids = Set(combined.map(\.id))
        for var imported in records {
            if !ids.insert(imported.id).inserted {
                imported.id = UUID().uuidString
                ids.insert(imported.id)
            }
            combined.append(imported)
        }
        try write(combined)
        return records.count
    }

    func injections(for context: ReaderAIMemoryContext?, messages: [ReaderAIChatMessage]) throws -> [ReaderAIWorldBookInjection] {
        let books = try books().filter { book in
            book.enabled && (book.isBound(to: .global) || (context?.companionID == "read_ai" && book.isBound(to: .readAI)))
        }
        var scanText: [Int: String] = [:]
        var all: [(entry: ReaderAIWorldBook.Entry, score: Int)] = []
        func rankedFirst(_ lhs: (entry: ReaderAIWorldBook.Entry, score: Int), _ rhs: (entry: ReaderAIWorldBook.Entry, score: Int)) -> Bool {
            lhs.score == rhs.score ? lhs.entry.order < rhs.entry.order : lhs.score > rhs.score
        }

        for book in books {
            var matches: [(entry: ReaderAIWorldBook.Entry, score: Int)] = []
            for entry in book.entries where entry.enabled {
                let depth = min(64, max(1, entry.scanDepth))
                if scanText[depth] == nil {
                    scanText[depth] = String(messages.suffix(depth).map(\.content).joined(separator: "\n").prefix(12_000))
                }
                let text = scanText[depth, default: ""]
                let matchingKeys = entry.keywords.filter { entry.matches($0, in: text) }.prefix(entry.maxMatches)
                guard !entry.excludeKeys.contains(where: { entry.matches($0, in: text) }),
                      entry.constantActive || (!matchingKeys.isEmpty && (entry.secondaryKeys.isEmpty || entry.secondaryKeys.contains { entry.matches($0, in: text) })) else {
                    continue
                }
                let score = entry.priority * 10 + matchingKeys.reduce(0) { $0 + min(30, $1.count) } + (entry.constantActive ? 120 : 0)
                matches.append((entry, score))
            }
            all += matches.sorted(by: rankedFirst).prefix(book.maxEntries)
        }
        return all.sorted(by: rankedFirst).prefix(12).map { entry, _ in
            .init(message: .init(role: entry.role, content: entry.content), position: entry.position, depth: entry.injectDepth)
        }
    }

    private func write(_ books: [ReaderAIWorldBook]) throws {
        try ReaderAIContextFiles.write(books, to: file)
        cache = books
    }

    private static func decodeImport(_ data: Data, isAndroidPreferences: Bool) throws -> [ReaderAIWorldBook] {
        let jsonData: Data
        if isAndroidPreferences {
            let preference = AndroidWorldBookPreference()
            let parser = XMLParser(data: data)
            parser.delegate = preference
            parser.shouldResolveExternalEntities = false
            guard parser.parse(), !preference.value.isEmpty else { throw ReaderAIContextFiles.ImportError.invalidWorldBook }
            jsonData = Data(preference.value.utf8)
        } else {
            jsonData = data
        }
        let json = try JSONSerialization.jsonObject(with: jsonData)
        let candidates: [[String: Any]]
        if let list = json as? [[String: Any]] {
            candidates = list
        } else if let object = json as? [String: Any] {
            candidates = [object]
        } else {
            candidates = []
        }
        let records = candidates.enumerated().compactMap { index, object in
            parseBook(object, order: index, isPreferences: isAndroidPreferences)
        }.sorted { $0.order < $1.order }.map(\.book)
        guard !records.isEmpty else { throw ReaderAIContextFiles.ImportError.invalidWorldBook }
        return records
    }

    private static func parseBook(_ root: [String: Any], order: Int, isPreferences: Bool) -> (order: Int, book: ReaderAIWorldBook)? {
        let data = root["data"] as? [String: Any] ?? root
        let name = data.text("name")
        let type = root["type"] as? String ?? data["type"] as? String ?? "lorebook"
        guard type == "lorebook", !name.isEmpty else { return nil }
        let entries = (data["entries"] as? [[String: Any]] ?? []).enumerated().compactMap { index, entry in
            parseEntry(entry, order: index, isPreferences: isPreferences)
        }
        var entryIDs = Set<String>()
        let uniqueEntries = entries.filter { entryIDs.insert($0.id).inserted }
            .sorted { $0.priority == $1.priority ? $0.order < $1.order : $0.priority > $1.priority }.enumerated().map { index, entry in
                var entry = entry
                entry.order = index
                return entry
            }
        let bindings: [ReaderAIWorldBook.Binding]
        if isPreferences {
            let source = data["bindings"] as? [[String: Any]] ?? []
            if source.isEmpty, (data["bindingVersion"] as? Int ?? 0) <= 0, (data["scope"] as? String ?? "global") == "global" {
                bindings = [.global]
            } else {
                bindings = source.compactMap { row in
                    let type = row.text("targetType")
                    guard type == "global" || type == "companion" else { return nil }
                    return .init(targetType: type, targetKey: row.text("targetKey"), enabled: row["enabled"] as? Bool ?? true)
                }
            }
        } else {
            bindings = []
        }
        let book = ReaderAIWorldBook(
            id: data.text("id", default: UUID().uuidString), name: name, description: data.text("description"),
            version: max(1, root["version"] as? Int ?? data["version"] as? Int ?? 1), enabled: data["enabled"] as? Bool ?? true,
            maxEntries: data.integer("maxEntries", default: 12, in: 1...40), bindings: bindings, entries: uniqueEntries
        )
        return (data["order"] as? Int ?? order, book)
    }

    private static func parseEntry(_ data: [String: Any], order: Int, isPreferences: Bool) -> ReaderAIWorldBook.Entry? {
        let name = data.text("name", default: data.text("title"))
        let content = data.text("content")
        guard !name.isEmpty, !content.isEmpty else { return nil }
        let keywords = data.strings("keywords")
        return .init(
            id: data.text("id", default: UUID().uuidString), name: name, content: String(content.prefix(8_000)),
            keywords: keywords.isEmpty ? data.strings("keys") : keywords,
            secondaryKeys: data.strings("secondaryKeys"), excludeKeys: data.strings("excludeKeys"),
            useRegex: data["useRegex"] as? Bool == true || data["regexEnabled"] as? Bool == true,
            caseSensitive: data["caseSensitive"] as? Bool ?? false, enabled: data["enabled"] as? Bool ?? true,
            constantActive: data["constantActive"] as? Bool == true || data["constant"] as? Bool == true,
            priority: data.integer("priority", default: isPreferences ? 50 : 0, in: 0...100),
            position: .init(rawValue: data.text("position")) ?? .afterSystemPrompt,
            injectDepth: data.integer("injectDepth", default: 4, in: 0...64),
            role: .init(rawValue: data.text("role")) ?? .user,
            scanDepth: data.integer("scanDepth", default: isPreferences ? 8 : 4, in: 1...64),
            maxMatches: data.integer("maxMatches", default: 1, in: 1...20), order: data["order"] as? Int ?? order
        )
    }
}

private extension ReaderAIWorldBook.Entry {
    func matches(_ key: String, in text: String) -> Bool {
        guard !key.aiTrimmed.isEmpty, !text.aiTrimmed.isEmpty else { return false }
        if useRegex {
            let options: NSRegularExpression.Options = caseSensitive ? [.anchorsMatchLines] : [.anchorsMatchLines, .caseInsensitive]
            return (try? NSRegularExpression(pattern: key, options: options))?
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return text.range(of: key, options: caseSensitive ? [] : .caseInsensitive) != nil
    }
}

private extension Dictionary where Key == String, Value == Any {
    func text(_ key: String, default fallback: String = "") -> String {
        let value = (self[key] as? String ?? "").aiTrimmed
        return value.isEmpty ? fallback : value
    }

    func integer(_ key: String, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self[key] as? Int ?? fallback))
    }

    func strings(_ key: String) -> [String] {
        var seen = Set<String>()
        return Array((self[key] as? [String] ?? []).map(\.aiTrimmed).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(40))
    }
}

private final class AndroidWorldBookPreference: NSObject, XMLParserDelegate {
    private var reading = false
    private(set) var value = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        reading = elementName == "string" && attributes["name"] == "aiWorldBookList"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if reading { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "string" { reading = false }
    }
}
