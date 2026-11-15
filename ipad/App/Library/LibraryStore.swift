import BookSources
import CryptoKit
import Foundation
import LocalBooks
import SwiftUI

struct LibraryBook: Codable, Identifiable {
    struct Chapter: Codable {
        let title: String
        let online: SourceChapter?
    }

    let id: UUID
    let title: String
    let author: String
    let coverURL: URL?
    let sourceID: String?
    let onlineID: String?
    let chapters: [Chapter]
    let initialOnlineID: String?
    let indexedOnlineCache: Bool?
    let readingRevision: UUID?
    let initialSwitchPosition: ReaderPosition?

    var readerIdentity: String { readingRevision?.uuidString ?? id.uuidString }

    var readerBookmarkKey: String {
        let base = ReaderBookmarks.key(for: id)
        guard let onlineID, let initialOnlineID, initialOnlineID != onlineID else { return base }
        return "\(base).\(libraryDigest(onlineID))"
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    private struct Catalog: Codable {
        var books: [LibraryBook] = []
        var sources: [BookSource] = []
    }

    private struct SavedPosition: Codable, Equatable {
        let position: ReaderPosition
        let revision: UUID?
    }

    @Published private var catalog = Catalog()
    @Published private var positions: [UUID: SavedPosition] = [:]
    @Published private(set) var startupError: String?

    let client: BookSourceClient
    var books: [LibraryBook] { catalog.books }
    var sources: [BookSource] { catalog.sources }

    private let defaults: UserDefaults
    private let files: LibraryFiles
    private let catalogURL: URL
    private let positionKey = "library.readingPositions"

    init(
        defaults: UserDefaults = .standard,
        root: URL = URL.applicationSupportDirectory.appending(path: "LegadoPad", directoryHint: .isDirectory),
        client: BookSourceClient = BookSourceClient()
    ) {
        self.defaults = defaults
        self.client = client
        files = LibraryFiles(root: root)
        catalogURL = root.appending(path: "library.json")

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                let data = try Data(contentsOf: catalogURL)
                catalog = try JSONDecoder().decode(Catalog.self, from: data)
            } catch where isMissingFile(error) {
                catalog = Catalog()
            }
        } catch {
            startupError = error.localizedDescription
        }

        if let data = defaults.data(forKey: positionKey) {
            let decoder = JSONDecoder()
            if let saved = try? decoder.decode([UUID: SavedPosition].self, from: data) {
                positions = saved
            } else if let saved = try? decoder.decode([UUID: ReaderPosition].self, from: data) {
                positions = saved.mapValues { SavedPosition(position: $0, revision: nil) }
            }
        }
    }

    func position(for id: UUID) -> ReaderPosition {
        storedPosition(for: id) ?? ReaderPosition()
    }

    func currentBook(_ id: UUID) -> LibraryBook? { books.first { $0.id == id } }

    func sourceName(for book: LibraryBook) -> String {
        sources.first { $0.id == book.sourceID }?.name ?? book.sourceID.flatMap { URL(string: $0)?.host } ?? "在线书源"
    }

    func hasPosition(for id: UUID) -> Bool {
        storedPosition(for: id) != nil
    }

    private func storedPosition(for id: UUID) -> ReaderPosition? {
        guard let book = currentBook(id) else { return nil }
        if let saved = positions[id], saved.revision == book.readingRevision { return saved.position }
        return book.initialSwitchPosition
    }

    func savePosition(_ position: ReaderPosition, for id: UUID) {
        guard let book = currentBook(id) else { return }
        let saved = SavedPosition(position: position, revision: book.readingRevision)
        guard saved != positions[id] else { return }
        positions[id] = saved
        persistPositions()
    }

    func savePosition(_ position: ReaderPosition, for book: LibraryBook) {
        guard currentBook(book.id)?.readerIdentity == book.readerIdentity else { return }
        savePosition(position, for: book.id)
    }

    func importLocalBook(from url: URL) async throws -> LibraryBook {
        let id = UUID()
        let imported = try await files.importBook(from: url, id: id)
        let book = LibraryBook(
            id: id,
            title: imported.title,
            author: imported.author ?? "",
            coverURL: nil,
            sourceID: nil,
            onlineID: nil,
            chapters: imported.chapters.map { .init(title: $0.title, online: nil) },
            initialOnlineID: nil,
            indexedOnlineCache: nil,
            readingRevision: nil,
            initialSwitchPosition: nil
        )
        do {
            var next = catalog
            next.books.insert(book, at: 0)
            try commit(next)
            return book
        } catch {
            await files.removeBook(id)
            throw error
        }
    }

    func existingBook(_ result: SourceBook) -> LibraryBook? {
        books.first { $0.onlineID == result.id }
    }

    func addOnlineBook(_ result: SourceBook, chapters: [SourceChapter]) throws -> LibraryBook {
        if let existing = existingBook(result) { return existing }
        guard !chapters.isEmpty else { throw LibraryError.noChapters }

        let book = LibraryBook(
            id: UUID(),
            title: result.title,
            author: result.author,
            coverURL: result.coverURL,
            sourceID: result.sourceID,
            onlineID: result.id,
            chapters: chapters.map { .init(title: $0.title, online: $0) },
            initialOnlineID: nil,
            indexedOnlineCache: false,
            readingRevision: nil,
            initialSwitchPosition: nil
        )
        var next = catalog
        next.books.insert(book, at: 0)
        try commit(next)
        return book
    }

    func removeBook(_ id: UUID) async throws {
        var next = catalog
        next.books.removeAll { $0.id == id }
        try commit(next)
        positions.removeValue(forKey: id)
        persistPositions()
        let bookmarkKey = ReaderBookmarks.key(for: id)
        ReaderBookmarks.removeAll(for: id, defaults: defaults)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(bookmarkKey + ".") {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: ReaderReplacementRule.storageKey(bookID: id))
        await files.removeBook(id)
    }

    func cachedChapter(in book: LibraryBook, at index: Int) async throws -> String? {
        guard book.chapters.indices.contains(index) else { throw LibraryError.noChapters }
        try verifyCurrent(book)
        let cached = try await files.readChapter(in: book, at: index)
        try verifyCurrent(book)
        return cached
    }

    func chapter(in book: LibraryBook, at index: Int) async throws -> String {
        if let stored = try await cachedChapter(in: book, at: index) { return stored }
        let text = try await fetchChapter(in: book, at: index, bypassCache: false)
        try Task.checkCancellation()
        try verifyCurrent(book)
        try? await files.writeChapter(text, in: book, at: index, replaces: false)
        return text
    }

    func refreshChapter(in book: LibraryBook, at index: Int) async throws -> String {
        let text = try await fetchChapter(in: book, at: index, bypassCache: true)
        try Task.checkCancellation()
        try verifyCurrent(book)
        try await files.writeChapter(text, in: book, at: index, replaces: true)
        return text
    }

    func downloadChapter(in book: LibraryBook, at index: Int) async throws {
        if try await cachedChapter(in: book, at: index) != nil { return }
        let text = try await fetchChapter(in: book, at: index, bypassCache: false)
        try Task.checkCancellation()
        try verifyCurrent(book)
        try await files.writeChapter(text, in: book, at: index, replaces: false)
    }

    func switchSource(for book: LibraryBook, to result: SourceBook, at index: Int) async throws -> LibraryBook {
        try verifyCurrent(book)
        guard let onlineID = book.onlineID, book.chapters.indices.contains(index) else { throw LibraryError.noChapters }
        guard let source = sources.first(where: { $0.id == result.sourceID && $0.isEnabled && $0.canSearch }),
              source.id != book.sourceID else { throw LibraryError.missingSource }
        if existingBook(result) != nil { throw LibraryError.editionAlreadyOnShelf }

        let details = try await client.details(for: result, in: source)
        let chapters = try await client.chapters(for: details, in: source)
        guard !chapters.isEmpty else { throw LibraryError.noChapters }
        let title = normalizedChapterTitle(book.chapters[index].title)
        let matching = chapters.indices.filter { !title.isEmpty && normalizedChapterTitle(chapters[$0].title) == title }
        let target = matching.min(by: { abs($0 - index) < abs($1 - index) }) ?? min(index, chapters.count - 1)
        let replacement = LibraryBook(
            id: book.id,
            title: details.title,
            author: details.author.isEmpty ? book.author : details.author,
            coverURL: details.coverURL,
            sourceID: details.sourceID,
            onlineID: details.id,
            chapters: chapters.map { .init(title: $0.title, online: $0) },
            initialOnlineID: book.initialOnlineID ?? onlineID,
            indexedOnlineCache: false,
            readingRevision: UUID(),
            initialSwitchPosition: ReaderPosition(chapterIndex: target, offset: 0)
        )

        try verifyCurrent(book)
        if try await files.readChapter(in: replacement, at: target) == nil {
            let text = try await client.content(of: chapters[target], in: source)
            try Task.checkCancellation()
            try verifyCurrent(book)
            try await files.writeChapter(text, in: replacement, at: target, replaces: false)
        }
        try await files.migrateIndexedCache(for: book)
        try Task.checkCancellation()
        try verifyCurrent(book)
        guard sources.contains(where: { $0.id == source.id && $0.isEnabled }) else { throw LibraryError.missingSource }
        if existingBook(details) != nil { throw LibraryError.editionAlreadyOnShelf }

        var next = catalog
        guard let shelfIndex = next.books.firstIndex(where: { $0.id == book.id }) else { throw LibraryError.bookUnavailable }
        next.books[shelfIndex] = replacement
        try commit(next)
        return replacement
    }

    private func verifyCurrent(_ book: LibraryBook) throws {
        guard currentBook(book.id)?.readerIdentity == book.readerIdentity else { throw LibraryError.bookUnavailable }
    }

    private func fetchChapter(in book: LibraryBook, at index: Int, bypassCache: Bool) async throws -> String {
        try verifyCurrent(book)
        guard book.chapters.indices.contains(index) else { throw LibraryError.noChapters }
        guard let chapter = book.chapters[index].online else { throw LibraryError.missingChapter }
        guard let source = sources.first(where: { $0.id == book.sourceID }) else { throw LibraryError.missingSource }
        return try await client.content(of: chapter, in: source, bypassCache: bypassCache)
    }

    func importSources(from url: URL) async throws -> Int {
        let additions = try await files.readSources(from: url)
        var next = catalog
        for source in additions {
            if let index = next.sources.firstIndex(where: { $0.id == source.id }) {
                next.sources[index] = source
            } else {
                next.sources.append(source)
            }
        }
        try commit(next)
        return additions.count
    }

    func setEnabled(_ enabled: Bool, for id: String) throws {
        var next = catalog
        guard let index = next.sources.firstIndex(where: { $0.id == id }) else { return }
        next.sources[index].isEnabled = enabled
        try commit(next)
    }

    func removeSource(_ id: String) throws {
        var next = catalog
        next.sources.removeAll { $0.id == id }
        try commit(next)
    }

    private func commit(_ next: Catalog) throws {
        if let startupError { throw LibraryError.catalogUnavailable(startupError) }
        let data = try JSONEncoder().encode(next)
        try data.write(to: catalogURL, options: .atomic)
        catalog = next
    }

    private func persistPositions() {
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: positionKey)
        }
    }
}

private actor LibraryFiles {
    let root: URL
    private var removedBooks = Set<UUID>()

    init(root: URL) {
        self.root = root.appending(path: "Books", directoryHint: .isDirectory)
    }

    func importBook(from url: URL, id: UUID) throws -> LocalBook {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let book = try LocalBookImporter.read(url: url)

        do {
            try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
            for (index, chapter) in book.chapters.enumerated() {
                try Task.checkCancellation()
                try chapter.text.write(to: chapterURL(in: id, at: index), atomically: true, encoding: .utf8)
            }
        } catch {
            removeBook(id)
            throw error
        }
        return book
    }

    func readSources(from url: URL) throws -> [BookSource] {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try BookSourceImport.decode(data)
    }

    func readChapter(in book: LibraryBook, at index: Int) throws -> String? {
        guard !removedBooks.contains(book.id) else { throw LibraryError.bookUnavailable }
        if let url = onlineChapterURL(in: book, at: index) {
            if let text = try readText(at: url) { return text }
            guard book.indexedOnlineCache != false else { return nil }
        }
        return try readText(at: chapterURL(in: book.id, at: index))
    }

    private func readText(at url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch where isMissingFile(error) {
            return nil
        }
    }

    func writeChapter(_ text: String, in book: LibraryBook, at index: Int, replaces: Bool) throws {
        try Task.checkCancellation()
        guard !removedBooks.contains(book.id) else { throw LibraryError.bookUnavailable }
        let url = onlineChapterURL(in: book, at: index) ?? chapterURL(in: book.id, at: index)
        if !replaces, FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func migrateIndexedCache(for book: LibraryBook) throws {
        guard book.indexedOnlineCache != false else { return }
        for index in book.chapters.indices {
            try Task.checkCancellation()
            let legacy = chapterURL(in: book.id, at: index)
            guard let destination = onlineChapterURL(in: book, at: index),
                  FileManager.default.fileExists(atPath: legacy.path),
                  !FileManager.default.fileExists(atPath: destination.path),
                  let text = try readText(at: legacy) else { continue }
            try writeChapter(text, in: book, at: index, replaces: false)
        }
    }

    func removeBook(_ id: UUID) {
        removedBooks.insert(id)
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    private func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func chapterURL(in id: UUID, at index: Int) -> URL {
        directory(for: id).appending(path: "\(index).txt")
    }

    private func onlineChapterURL(in book: LibraryBook, at index: Int) -> URL? {
        guard let edition = book.onlineID, let chapter = book.chapters[index].online else { return nil }
        return directory(for: book.id)
            .appending(path: "edition-\(libraryDigest(edition))", directoryHint: .isDirectory)
            .appending(path: "\(libraryDigest(chapter.id)).txt")
    }
}

private func libraryDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func normalizedChapterTitle(_ title: String) -> String {
    title.precomposedStringWithCompatibilityMapping
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        .filter { $0.isLetter || $0.isNumber }
}

private func isMissingFile(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
}

enum LibraryError: LocalizedError {
    case noChapters
    case missingChapter
    case missingSource
    case bookUnavailable
    case editionAlreadyOnShelf
    case catalogUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noChapters: "没有可阅读的章节。"
        case .missingChapter: "章节文件已丢失，请重新导入这本书。"
        case .missingSource: "找不到原书源。请重新导入书源以加载这一章。"
        case .bookUnavailable: "书架中的书籍已删除或书源已更换。"
        case .editionAlreadyOnShelf: "这个书源的版本已在书架中，可从书架单独打开。"
        case .catalogUnavailable(let detail): "无法打开书架。\(detail)"
        }
    }
}
