import BookSources
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
}

@MainActor
final class LibraryStore: ObservableObject {
    private struct Catalog: Codable {
        var books: [LibraryBook] = []
        var sources: [BookSource] = []
    }

    @Published private var catalog = Catalog()
    @Published private var positions: [UUID: ReaderPosition] = [:]
    @Published private(set) var startupError: String?

    let client = BookSourceClient()
    var books: [LibraryBook] { catalog.books }
    var sources: [BookSource] { catalog.sources }

    private let defaults: UserDefaults
    private let files: LibraryFiles
    private let catalogURL: URL
    private let positionKey = "library.readingPositions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let root = URL.applicationSupportDirectory.appending(path: "LegadoPad", directoryHint: .isDirectory)
        files = LibraryFiles(root: root)
        catalogURL = root.appending(path: "library.json")

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                let data = try Data(contentsOf: catalogURL)
                catalog = try JSONDecoder().decode(Catalog.self, from: data)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                catalog = Catalog()
            }
        } catch {
            startupError = error.localizedDescription
        }

        if let data = defaults.data(forKey: positionKey),
           let saved = try? JSONDecoder().decode([UUID: ReaderPosition].self, from: data) {
            positions = saved
        }
    }

    func position(for id: UUID) -> ReaderPosition {
        positions[id] ?? ReaderPosition()
    }

    func hasPosition(for id: UUID) -> Bool {
        positions[id] != nil
    }

    func savePosition(_ position: ReaderPosition, for id: UUID) {
        guard position != positions[id], books.contains(where: { $0.id == id }) else { return }
        positions[id] = position
        persistPositions()
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
            chapters: imported.chapters.map { .init(title: $0.title, online: nil) }
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
            chapters: chapters.map { .init(title: $0.title, online: $0) }
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
        ReaderBookmarks.removeAll(for: id, defaults: defaults)
        await files.removeBook(id)
    }

    func chapter(in book: LibraryBook, at index: Int) async throws -> String {
        guard book.chapters.indices.contains(index) else { throw LibraryError.noChapters }

        if let stored = try await files.readChapter(in: book.id, at: index) { return stored }
        guard let online = book.chapters[index].online else { throw LibraryError.missingChapter }
        guard let source = sources.first(where: { $0.id == book.sourceID }) else {
            throw LibraryError.missingSource
        }

        let text = try await client.content(of: online, in: source)
        try Task.checkCancellation()
        if books.contains(where: { $0.id == book.id }) {
            try? await files.writeChapter(text, in: book.id, at: index)
        }
        return text
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

    func readChapter(in id: UUID, at index: Int) throws -> String? {
        do {
            return try String(contentsOf: chapterURL(in: id, at: index), encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeChapter(_ text: String, in id: UUID, at index: Int) throws {
        try FileManager.default.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
        try text.write(to: chapterURL(in: id, at: index), atomically: true, encoding: .utf8)
    }

    func removeBook(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    private func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func chapterURL(in id: UUID, at index: Int) -> URL {
        directory(for: id).appending(path: "\(index).txt")
    }
}

enum LibraryError: LocalizedError {
    case noChapters
    case missingChapter
    case missingSource
    case catalogUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noChapters: "没有可阅读的章节。"
        case .missingChapter: "章节文件已丢失，请重新导入这本书。"
        case .missingSource: "找不到原书源。请重新导入书源以加载这一章。"
        case .catalogUnavailable(let detail): "无法打开书架。\(detail)"
        }
    }
}
