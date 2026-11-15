import Foundation

struct ReaderBookCharacter: Codable, Sendable {
    let id: Int64?
    let name: String
    let gender: String?
    let identity: String?
    let skills: String?
    let attributes: String?
    let appearance: String?
    let personality: String?
    let biography: String?
    let roleLevel: Int?
    let sortOrder: Int?
}

actor ReaderBookCharacterStore {
    static let shared = ReaderBookCharacterStore()

    struct ImportBook: Sendable {
        let id: UUID
        let title: String
        let author: String
        let legacyBookURL: String
    }

    struct ImportResult: Sendable {
        let bookCount: Int
        let characterCount: Int
        let unmatchedCount: Int
    }

    private struct BackupRecord: Decodable {
        let bookKey: String
        let character: ReaderBookCharacter

        private enum CodingKeys: String, CodingKey { case bookUrl }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bookKey = try container.decode(String.self, forKey: .bookUrl)
            character = try ReaderBookCharacter(from: decoder)
        }
    }

    private let file: URL
    private var stored: [UUID: [ReaderBookCharacter]]?

    init(file: URL = URL.applicationSupportDirectory.appending(path: "LegadoPad/ReaderAI/book-characters.json")) {
        self.file = file
    }

    func characters(for bookID: UUID) throws -> [ReaderBookCharacter] {
        try load()[bookID] ?? []
    }

    func importBackup(from url: URL, books: [ImportBook]) throws -> ImportResult {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let sizeLimit = 16 * 1024 * 1024
        guard fileSize <= sizeLimit else { throw ImportError.fileTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= sizeLimit else { throw ImportError.fileTooLarge }
        guard let records = try? JSONDecoder().decode([BackupRecord].self, from: data) else {
            throw ImportError.invalidBackup
        }

        var booksForKey: [String: Set<UUID>] = [:]
        for book in books {
            if let key = Self.workKey(title: book.title, author: book.author) {
                booksForKey[key, default: []].insert(book.id)
            }
            if !book.legacyBookURL.isEmpty {
                booksForKey[book.legacyBookURL, default: []].insert(book.id)
            }
        }

        var unmatched = 0
        var imported: [UUID: [String: ReaderBookCharacter]] = [:]
        // Earlier versions used the book URL. Prefer a work's profile when a
        // backup contains both the legacy location and the migrated work key.
        let ordered = records.filter { !$0.bookKey.hasPrefix("work:") } + records.filter { $0.bookKey.hasPrefix("work:") }
        for record in ordered {
            let name = record.character.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let ids = booksForKey[record.bookKey], !ids.isEmpty else {
                unmatched += 1
                continue
            }
            for id in ids { imported[id, default: [:]][name] = record.character }
        }

        if !imported.isEmpty {
            var next = try load()
            for (id, additions) in imported {
                var byName = additions
                for record in next[id] ?? [] {
                    let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if byName[name] == nil { byName[name] = record }
                }
                next[id] = byName.values.sorted { first, second in
                    let firstLevel = first.roleLevel ?? 0
                    let secondLevel = second.roleLevel ?? 0
                    if firstLevel != secondLevel { return firstLevel > secondLevel }
                    return (first.sortOrder ?? 0, first.id ?? 0, first.name) <
                        (second.sortOrder ?? 0, second.id ?? 0, second.name)
                }
            }
            try save(next)
        }
        return ImportResult(
            bookCount: imported.count,
            characterCount: imported.values.reduce(0) { $0 + $1.count },
            unmatchedCount: unmatched
        )
    }

    func remove(bookID: UUID) throws {
        var next = try load()
        guard next.removeValue(forKey: bookID) != nil else { return }
        try save(next)
    }

    private func load() throws -> [UUID: [ReaderBookCharacter]] {
        if let stored { return stored }
        let records: [UUID: [ReaderBookCharacter]]
        do {
            records = try JSONDecoder().decode([UUID: [ReaderBookCharacter]].self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            records = [:]
        }
        stored = records
        return records
    }

    private func save(_ records: [UUID: [ReaderBookCharacter]]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: [.atomic])
        #endif
        stored = records
    }

    private static func workKey(title: String, author: String) -> String? {
        func normalized(_ value: String) -> String {
            value.precomposedStringWithCompatibilityMapping
                .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                .lowercased()
        }

        let title = normalized(title)
        guard !title.isEmpty else { return nil }
        let realAuthor = author.replacingOccurrences(
            of: "^\\s*作\\s*者[:：\\s]+|\\s+著", with: "", options: .regularExpression
        )
        let author = normalized(realAuthor.isEmpty ? author : realAuthor)
        return author.isEmpty ? "work:\(title)" : "work:\(author)/\(title)"
    }

    private enum ImportError: LocalizedError {
        case invalidBackup, fileTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidBackup: "请选择安卓阅读备份中的 bookCharacters.json。"
            case .fileTooLarge: "角色资料文件超过 16 MB。"
            }
        }
    }
}
