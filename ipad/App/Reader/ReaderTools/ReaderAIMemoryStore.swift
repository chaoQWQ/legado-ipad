import Foundation

struct ReaderAIMemoryContext: Sendable {
    var bookTitle = ""
    var author = ""
    let sessionID: UUID

    var isBook: Bool { !bookTitle.aiTrimmed.isEmpty }
    var bookKey: String { [bookTitle, author].map(\.aiTrimmed).filter { !$0.isEmpty }.joined(separator: "::") }
    var scope: String { isBook ? "book" : "global" }
    var companionID: String { isBook ? "read_ai" : "" }
}

actor ReaderAIMemoryStore {
    static let shared = ReaderAIMemoryStore()

    struct Entry: Codable, Identifiable, Sendable {
        enum Kind: String, Codable, Sendable { case item, fragment }

        var id = UUID().uuidString
        let kind: Kind
        let scope: String
        var bookKey = ""
        var sessionID = ""
        let title: String
        var chapterTitle = ""
        let content: String
        let importance: Int
        let signature: String
        var updatedAt = Date()
        var lastUsedAt = Date.distantPast

        var rankingText: String { "\(title) \(chapterTitle) \(content)" }
    }

    private let file: URL
    private var cached: [Entry]?

    init(file: URL = URL.applicationSupportDirectory.appending(path: "LegadoPad/ReaderAI/long-term-memory.json")) {
        self.file = file
    }

    func entries() throws -> [Entry] {
        if let cached { return cached }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            entries = []
        }
        cached = entries
        return entries
    }

    func prompt(for context: ReaderAIMemoryContext?, messages: [ReaderAIChatMessage]) throws -> String {
        guard let context else { return "" }
        let query = String(messages.suffix(6).map(\.content).joined(separator: "\n").prefix(4_000))
        guard !query.aiTrimmed.isEmpty else { return "" }
        let tokens = keywords(query)
        let scoped = try entries().filter { entry in
            (entry.scope == context.scope || entry.scope == "global") &&
                (context.bookKey.isEmpty || entry.bookKey.isEmpty || entry.bookKey == context.bookKey) &&
                (entry.sessionID.isEmpty || entry.sessionID == context.sessionID.uuidString)
        }
        let items = ranked(scoped.filter { $0.kind == .item }, keywords: tokens)
        let fragments = ranked(scoped.filter { $0.kind == .fragment }, keywords: tokens)
        guard !items.isEmpty || !fragments.isEmpty else { return "" }

        let used = Set((items + fragments).map(\.id))
        let now = Date()
        var data = try entries()
        for index in data.indices where used.contains(data[index].id) { data[index].lastUsedAt = now }
        try save(data)

        var result = "Relevant long-term memories:\n"
        for entry in items + fragments {
            let content = entry.kind == .item ? entry.content : entry.content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).aiTrimmed
            let label = entry.title.isEmpty ? "" : "\(entry.title): "
            let line = "- \(label)\(content)"
            let limit = entry.kind == .item ? 360 : 520
            if line.count > 2, result.count + line.count < 2_800 {
                result += String(line.prefix(limit)) + "\n"
            }
        }
        return result.aiTrimmed
    }

    func record(answer: String, question: String, context: ReaderAIMemoryContext) throws {
        let question = question.aiTrimmed
        let answer = answer.aiTrimmed
        guard !question.isEmpty, !answer.isEmpty else { return }
        var additions: [Entry] = []
        let combined = "User: \(question.prefix(2_000))\nAssistant: \(answer.prefix(2_000))"
        if combined.count >= 40 {
            additions.append(.init(
                kind: .fragment, scope: context.scope, bookKey: context.bookKey, sessionID: context.sessionID.uuidString,
                title: context.isBook ? context.bookTitle : "AI 对话", content: combined, importance: 40,
                signature: [context.scope, context.bookKey, context.sessionID.uuidString, combined].joined(separator: "|")
            ))
        }
        let normalized = question.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let preferences = ["我希望", "我喜欢", "我不希望", "我不喜欢", "以后", "记住"]
        if let keyword = preferences.first(where: { normalized.contains($0) }) {
            let text = String(normalized.prefix(500))
            additions.append(.init(
                kind: .item, scope: "global", sessionID: context.sessionID.uuidString,
                title: "用户偏好", content: text, importance: 75,
                signature: ["global", context.sessionID.uuidString, keyword, text].joined(separator: "|")
            ))
        }
        guard !additions.isEmpty else { return }
        try merge(additions)
    }

    func remove(id: String) throws {
        try save(entries().filter { $0.id != id })
    }

    func removeConversation(_ id: UUID) throws {
        let records = try entries()
        let filtered = records.filter { $0.sessionID != id.uuidString }
        if filtered.count != records.count { try save(filtered) }
    }

    func removeBook(title: String, author: String) throws {
        let key = [title, author].map(\.aiTrimmed).filter { !$0.isEmpty }.joined(separator: "::")
        guard !key.isEmpty else { return }
        let data = try entries()
        let filtered = data.filter { $0.scope != "book" || $0.bookKey != key }
        if filtered.count != data.count { try save(filtered) }
    }

    // The Android app keeps memories in its Room database instead of its standard backup.
    // Accept explicit JSON exports of those tables without conflating them with the backup.
    func importRecords(from url: URL) throws -> Int {
        let data = try ReaderAIContextFiles.importData(from: url)
        let json = try JSONSerialization.jsonObject(with: data)
        let entries: [Entry]
        if let rows = json as? [[String: Any]] {
            entries = rows.compactMap(decodeAndroidEntry)
        } else if let object = json as? [String: Any] {
            let keys = ["ai_memory_items", "ai_memory_fragments", "items", "fragments"]
            entries = keys.flatMap { (object[$0] as? [[String: Any]] ?? []).compactMap(decodeAndroidEntry) }
        } else {
            entries = []
        }
        guard !entries.isEmpty else { throw ReaderAIContextFiles.ImportError.invalidMemory }
        try merge(entries)
        return entries.count
    }

    private func decodeAndroidEntry(_ row: [String: Any]) -> Entry? {
        func value(_ key: String) -> String { (row[key] as? String ?? "").aiTrimmed }
        let fragment = value("fragmentId")
        let item = value("memoryId")
        guard !fragment.isEmpty || !item.isEmpty else { return nil }
        let kind: Entry.Kind = fragment.isEmpty ? .item : .fragment
        let scope = value("scope").isEmpty ? "global" : value("scope")
        let title = kind == .item ? value("subject") : value("title")
        let rawContent = value("content")
        let content = rawContent.isEmpty && kind == .item
            ? [value("subject"), value("predicate"), value("objectValue")].filter { !$0.isEmpty }.joined(separator: " ")
            : rawContent
        guard !content.isEmpty else { return nil }
        let id = kind == .item ? item : fragment
        let signature = value(kind == .item ? "fingerprint" : "contentHash")
        let updated = (row["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000) } ?? .now
        let lastUsed = (row["lastUsedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000) } ?? .distantPast
        return .init(
            id: id, kind: kind, scope: scope, bookKey: value("bookKey"), sessionID: value("sessionId"),
            title: title, chapterTitle: value("chapterTitle"), content: String(content.prefix(8_000)),
            importance: row["importance"] as? Int ?? 50, signature: signature.isEmpty ? id : signature,
            updatedAt: updated, lastUsedAt: lastUsed
        )
    }

    private func ranked(_ data: [Entry], keywords: [String]) -> ArraySlice<Entry> {
        let recent = data.sorted {
            ($0.importance, $0.lastUsedAt, $0.updatedAt) > ($1.importance, $1.lastUsedAt, $1.updatedAt)
        }
        let scores = recent.map { entry in
            (entry, keywords.filter { entry.rankingText.range(of: $0, options: .caseInsensitive) != nil }.count)
        }
        let relevant = scores.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(8)
        var seen = Set<String>()
        return (Array(relevant) + Array(scores.prefix(80))).filter { seen.insert($0.0.id).inserted }
            .sorted { $0.1 * 10 + $0.0.importance > $1.1 * 10 + $1.0.importance }.map { $0.0 }.prefix(8)
    }

    private func keywords(_ text: String) -> [String] {
        let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.filter { $0.count >= 2 }.map(String.init)
        let compact = Array(text.filter { !$0.isWhitespace }.prefix(48))
        let pairs = stride(from: 0, to: max(0, compact.count - 1), by: 2).map { String(compact[$0...($0 + 1)]) }
        var seen = Set<String>()
        return Array((words + pairs).filter { seen.insert($0).inserted }.prefix(48))
    }

    private func merge(_ additions: [Entry]) throws {
        var records = try entries()
        for entry in additions {
            records.removeAll { $0.id == entry.id || ($0.kind == entry.kind && $0.signature == entry.signature) }
            records.append(entry)
        }
        try save(records)
    }

    private func save(_ entries: [Entry]) throws {
        try ReaderAIContextFiles.write(entries, to: file)
        cached = entries
    }
}

enum ReaderAIContextFiles {
    static func write(_ value: some Encodable, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }

    static func importData(from url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let limit = 16 * 1024 * 1024
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limit else { throw ImportError.tooLarge }
        return data
    }

    enum ImportError: LocalizedError {
        case tooLarge, invalidMemory, invalidWorldBook

        var errorDescription: String? {
            switch self {
            case .tooLarge: "文件超过 16 MB。"
            case .invalidMemory: "文件中没有可识别的 AI 长期记忆记录。"
            case .invalidWorldBook: "文件中没有可识别的阅读 Archive 世界书。"
            }
        }
    }
}
