import Foundation

struct ReaderAskAIReadingContext: Codable, Equatable {
    let chapterIndex: Int
    let chapterCount: Int
    let offset: Int
    let chapterLength: Int

    var progressLabel: String {
        let chapterNumber = chapterIndex + 1
        let chapter = chapterCount >= chapterNumber ? "第 \(chapterNumber) / \(chapterCount) 章" : "第 \(chapterNumber) 章"
        guard chapterLength > 0 else { return chapter }
        let percent = Int((100 * Double(min(max(offset, 0), chapterLength)) / Double(chapterLength)).rounded())
        return "\(chapter) · 章内 \(percent)%"
    }
}

struct ReaderAskAIContext: Codable {
    static let defaultQuestion = "请解释这段文字。"

    let bookTitle: String
    let author: String
    let sourceName: String?
    let chapterTitle: String
    let excerpt: String
    var bookID: UUID? = nil
    var bookURL: String? = nil
    var readingContext: ReaderAskAIReadingContext? = nil

    var initialQuestion: String { excerpt.aiTrimmed }

    func requestText(for question: String) -> String {
        guard !bookTitle.isEmpty else { return question }
        let chapterNumber = readingContext.map { "（第 \($0.chapterIndex + 1) 章）" } ?? ""
        return """
        \(ReaderAISettings.defaultAskPrompt)

        书名：\(bookTitle)
        作者：\(author.isEmpty ? "未知" : author)
        书源：\(sourceName.flatMap { $0.isEmpty ? nil : $0 } ?? "未知")
        当前章节：\(chapterTitle.isEmpty ? "未知" : chapterTitle)\(chapterNumber)
        bookUrl：\(bookURL ?? bookID?.uuidString ?? bookTitle)

        用户选中或追问：
        \(question)
        """
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
    var toolTrace: ReaderAskAIToolTrace?
    var reasoning: [String]?
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
        let finished = turns.dropLast().filter { $0.status == .answered }
        for turn in finished.suffix(6) {
            messages.append(.init(role: .user, content: turn.question))
            messages.append(.init(role: .assistant, content: turn.answer))
        }
        messages.append(.init(role: .user, content: current.context.requestText(for: current.question)))
        return messages
    }

    func readingRequestMessages() -> [ReaderAIChatMessage] {
        guard let current = turns.last else { return [] }
        let history = turns.dropLast().flatMap { turn -> [ReaderAIChatMessage] in
            var messages = [ReaderAIChatMessage(role: .user, content: turn.question)]
            let reply: String
            switch turn.status {
            case .answered: reply = turn.answer
            case .stopped: reply = turn.answer.isEmpty ? "已取消" : turn.answer
            case .failed: reply = "上一轮 AI 请求失败。"
            case .waiting: reply = "上一轮请求中断。"
            }
            messages.append(ReaderAIChatMessage(role: .assistant, content: reply))
            return messages
        }
        return Array(history.filter { !$0.content.aiTrimmed.isEmpty }.suffix(12)) + [
            ReaderAIChatMessage(role: .user, content: current.context.requestText(for: current.question))
        ]
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
