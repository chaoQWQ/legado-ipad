import Foundation

struct ReaderAskAIContext: Codable {
    static let defaultQuestion = "请解释这段文字。"

    let bookTitle: String
    let author: String
    let sourceName: String?
    let chapterTitle: String
    let excerpt: String

    func requestText(for question: String) -> String {
        guard !bookTitle.isEmpty else { return question }
        var parts = ["书名：\(bookTitle)"]
        if !author.isEmpty { parts.append("作者：\(author)") }
        if let sourceName, !sourceName.isEmpty { parts.append("书源：\(sourceName)") }
        if !chapterTitle.isEmpty { parts.append("章节：\(chapterTitle)") }
        if !excerpt.isEmpty { parts.append("选中文本\n\(excerpt)") }
        parts.append("读者问题\n\(question)")
        return parts.joined(separator: "\n\n")
    }
}

struct ReaderAskAITurn: Codable, Identifiable {
    enum Status: String, Codable {
        case waiting, answered, stopped, failed
    }

    var id = UUID()
    let question: String
    let context: ReaderAskAIContext
    var answer = ""
    var status: Status = .waiting
    var error: String?
}

struct ReaderAskAIConversation: Codable, Identifiable {
    var id = UUID()
    var updatedAt = Date()
    var turns: [ReaderAskAITurn] = []

    var title: String {
        guard let first = turns.first else { return "新对话" }
        let title = first.question == ReaderAskAIContext.defaultQuestion && !first.context.excerpt.isEmpty
            ? first.context.excerpt : first.question
        return String((title.split(whereSeparator: \.isNewline).first ?? "新对话").prefix(50))
    }

    var chapterTitle: String { turns.first?.context.chapterTitle ?? "" }

    func requestMessages(prompt: String) -> [ReaderAIChatMessage] {
        guard let current = turns.last else { return [] }
        var messages = [ReaderAIChatMessage(role: .system, content: prompt)]
        for turn in turns.dropLast().filter({ $0.status == .answered }).suffix(6) {
            messages.append(.init(role: .user, content: turn.context.requestText(for: turn.question)))
            messages.append(.init(role: .assistant, content: turn.answer))
        }
        messages.append(.init(role: .user, content: current.context.requestText(for: current.question)))
        return messages
    }
}

struct ReaderAskAIHistory: Codable {
    var currentID: UUID?
    var conversations: [ReaderAskAIConversation] = []

    func conversation(_ id: UUID?) -> ReaderAskAIConversation? {
        conversations.first { $0.id == id }
    }

    mutating func update(_ conversation: ReaderAskAIConversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.insert(conversation, at: 0)
    }

    static func load(for bookID: UUID) throws -> Self {
        let location = try location(for: bookID)
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: location))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .init()
        }
    }

    func save(for bookID: UUID) throws {
        guard !conversations.isEmpty else {
            try Self.remove(for: bookID)
            return
        }
        let location = try Self.location(for: bookID)
        var directory = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(self)
        #if os(iOS)
        try data.write(to: location, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: location, options: .atomic)
        #endif
    }

    static func remove(for bookID: UUID) throws {
        do {
            try FileManager.default.removeItem(at: location(for: bookID))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // A book can be removed before its first conversation is saved.
        }
    }

    private static func location(for bookID: UUID) throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return support.appending(path: "LegadoPad/ReaderAI", directoryHint: .isDirectory)
            .appending(path: bookID.uuidString + ".json", directoryHint: .notDirectory)
    }
}
