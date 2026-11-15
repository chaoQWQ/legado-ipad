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
        var sourceSubscriptions: [BookSourceSubscription]?
        var subscriptionSignatures: [UUID: [String: String]]?
        var pendingSubscriptionUpdates: Set<UUID>?
        var feeds: [FeedSubscription]?
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
    var sourceSubscriptions: [BookSourceSubscription] { catalog.sourceSubscriptions ?? [] }
    var subscriptionsWithUpdates: Set<UUID> { catalog.pendingSubscriptionUpdates ?? [] }
    var feeds: [FeedSubscription] { catalog.feeds ?? [] }

    private let defaults: UserDefaults
    private let files: LibraryFiles
    private let subscriptionClient: BookSourceSubscriptionClient
    private let catalogURL: URL
    private let positionKey = "library.readingPositions"
    private var isCheckingSubscriptions = false

    init(
        defaults: UserDefaults = .standard,
        root: URL = URL.applicationSupportDirectory.appending(path: "LegadoPad", directoryHint: .isDirectory),
        client: BookSourceClient = BookSourceClient(),
        subscriptionClient: BookSourceSubscriptionClient = BookSourceSubscriptionClient()
    ) {
        self.defaults = defaults
        self.client = client
        self.subscriptionClient = subscriptionClient
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

    func sourceSimplifiesText(for book: LibraryBook) -> Bool {
        sources.first { $0.id == book.sourceID }?.simplifiesChapterText == true
    }

    func sourceSimplifiesTitles(for book: LibraryBook) -> Bool {
        sources.first { $0.id == book.sourceID }?.simplifiesTitles == true
    }

    func displayTitle(_ title: String, sourceID: String?) -> String {
        guard let sourceID else { return title }
        return sources.first { $0.id == sourceID }?.displayTitle(title) ?? title
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
        let cached = try await readCachedChapter(in: book, at: index)
        return cached.map { chapterTextForReading($0, in: book) }
    }

    func chapter(in book: LibraryBook, at index: Int) async throws -> String {
        if let stored = try await cachedChapter(in: book, at: index) { return stored }
        let cacheGeneration = await files.cacheGeneration(for: book.id)
        let text = try await fetchChapter(in: book, at: index, bypassCache: false)
        try Task.checkCancellation()
        try verifyCurrent(book)
        _ = try? await files.writeChapter(text, in: book, at: index, replaces: false,
                                          expectedCacheGeneration: cacheGeneration)
        return chapterTextForReading(text, in: book)
    }

    func refreshChapter(in book: LibraryBook, at index: Int) async throws -> String {
        let cacheGeneration = await files.cacheGeneration(for: book.id)
        let text = try await fetchChapter(in: book, at: index, bypassCache: true)
        try Task.checkCancellation()
        try verifyCurrent(book)
        try await files.writeChapter(text, in: book, at: index, replaces: true, expectedCacheGeneration: cacheGeneration)
        return chapterTextForReading(text, in: book)
    }

    func downloadChapter(in book: LibraryBook, at index: Int) async throws {
        if try await readCachedChapter(in: book, at: index) != nil { return }
        let cacheGeneration = await files.cacheGeneration(for: book.id)
        let text = try await fetchChapter(in: book, at: index, bypassCache: false)
        try Task.checkCancellation()
        try verifyCurrent(book)
        guard try await files.writeChapter(text, in: book, at: index, replaces: false,
                                            expectedCacheGeneration: cacheGeneration) else {
            throw LibraryError.cacheWasCleared
        }
    }

    func storageSnapshot() async throws -> LibraryStorageSnapshot {
        let currentBooks = books
        let appRoot = catalogURL.deletingLastPathComponent()
        let auxiliaryMeasurement = Task.detached(priority: .utility) {
            try LibraryAuxiliaryStorage.scan(appRoot: appRoot)
        }
        return try await withTaskCancellationHandler {
            defer { auxiliaryMeasurement.cancel() }
            var measured: [LibraryStorageBook] = []
            for book in currentBooks {
                try Task.checkCancellation()
                let usage = try await files.chapterStorage(for: book)
                let chapters = usage.chapterBytes.keys.sorted().compactMap { index -> LibraryStorageChapter? in
                    guard book.chapters.indices.contains(index), let bytes = usage.chapterBytes[index] else { return nil }
                    let title = displayTitle(book.chapters[index].title, sourceID: book.sourceID)
                    return LibraryStorageChapter(index: index, title: title, bytes: bytes)
                }
                measured.append(LibraryStorageBook(
                    id: book.id, revision: book.readingRevision, title: displayTitle(book.title, sourceID: book.sourceID),
                    author: book.author, coverURL: book.coverURL, sourceName: book.sourceID == nil ? nil : sourceName(for: book),
                    isOnline: book.sourceID != nil, totalChapters: book.chapters.count, usage: usage, chapters: chapters
                ))
            }
            let auxiliary = try await auxiliaryMeasurement.value
            return LibraryStorageSnapshot(books: measured, galleryBytes: auxiliary.galleryBytes,
                                          workspaceBytes: auxiliary.workspaceBytes, configurationBytes: auxiliary.configurationBytes)
        } onCancel: {
            auxiliaryMeasurement.cancel()
        }
    }

    func removeChapterCache(bookID: UUID, revision: UUID?, indices: Set<Int>? = nil) async throws -> LibraryCacheRemoval {
        guard let book = currentBook(bookID), book.readingRevision == revision, book.sourceID != nil else {
            throw LibraryError.bookUnavailable
        }
        return try await files.clearChapterCache(in: book, indices: indices)
    }

    func removeChapterCaches(in items: [LibraryStorageBook]) async throws -> LibraryCacheRemoval {
        let onlineBooks = try items.filter(\.isOnline).map { item in
            guard let book = currentBook(item.id), book.readingRevision == item.revision, book.sourceID != nil else {
                throw LibraryError.bookUnavailable
            }
            return book
        }
        return try await files.clearChapterCaches(in: onlineBooks)
    }

    func switchSource(for book: LibraryBook, to result: SourceBook, at index: Int) async throws -> LibraryBook {
        try verifyCurrent(book)
        guard let onlineID = book.onlineID, book.chapters.indices.contains(index) else { throw LibraryError.noChapters }
        guard let source = sources.first(where: { $0.id == result.sourceID && $0.isEnabled && $0.canSearch }),
              source.id != book.sourceID else { throw LibraryError.missingSource }
        if existingBook(result) != nil { throw LibraryError.editionAlreadyOnShelf }

        let cacheGeneration = await files.cacheGeneration(for: book.id)
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
            let text = try await client.content(of: chapters[target], in: source, applyingTextConversion: false)
            try Task.checkCancellation()
            try verifyCurrent(book)
            try await files.writeChapter(text, in: replacement, at: target, replaces: false, expectedCacheGeneration: cacheGeneration)
        }
        try await files.migrateIndexedCache(for: book, expectedCacheGeneration: cacheGeneration)
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

    private func readCachedChapter(in book: LibraryBook, at index: Int) async throws -> String? {
        guard book.chapters.indices.contains(index) else { throw LibraryError.noChapters }
        try verifyCurrent(book)
        let cached = try await files.readChapter(in: book, at: index)
        try verifyCurrent(book)
        return cached
    }

    private func chapterTextForReading(_ text: String, in book: LibraryBook) -> String {
        guard let sourceID = book.sourceID, let source = sources.first(where: { $0.id == sourceID }) else { return text }
        return source.convertCachedContent(text)
    }

    private func fetchChapter(in book: LibraryBook, at index: Int, bypassCache: Bool) async throws -> String {
        try verifyCurrent(book)
        guard book.chapters.indices.contains(index) else { throw LibraryError.noChapters }
        guard let chapter = book.chapters[index].online else { throw LibraryError.missingChapter }
        guard let source = sources.first(where: { $0.id == book.sourceID }) else { throw LibraryError.missingSource }
        return try await client.content(of: chapter, in: source, bypassCache: bypassCache, applyingTextConversion: false)
    }

    func importSources(from url: URL) async throws -> Int {
        let additions = try await files.readSources(from: url)
        var next = catalog
        mergeSources(additions, into: &next, preservingEnabledState: false)
        try commit(next)
        return additions.count
    }

    func saveSource(_ source: BookSource, replacing sourceID: String?) throws {
        var next = catalog
        if let sourceID, !next.sources.contains(where: { $0.id == sourceID }) {
            throw LibraryError.missingSource
        }
        if let index = next.sources.firstIndex(where: { $0.id == source.id }) {
            guard source.id == sourceID else { throw LibraryError.duplicateSource }
            next.sources[index] = source
        } else {
            next.sources.append(source)
        }
        try commit(next)
    }

    func saveSourceSubscription(_ subscription: BookSourceSubscription) throws {
        guard !sourceSubscriptions.contains(where: { $0.url == subscription.url && $0.id != subscription.id }) else {
            throw LibraryError.duplicateSubscription
        }
        var next = catalog
        var subscriptions = sourceSubscriptions
        var item = subscription
        if let index = subscriptions.firstIndex(where: { $0.id == item.id }) {
            if subscriptions[index].url != item.url {
                item.lastRefreshedAt = nil
                next.subscriptionSignatures?.removeValue(forKey: item.id)
                next.pendingSubscriptionUpdates?.remove(item.id)
            } else {
                item.lastRefreshedAt = subscriptions[index].lastRefreshedAt
            }
            subscriptions[index] = item
        } else {
            subscriptions.append(item)
        }
        next.sourceSubscriptions = subscriptions
        try commit(next)
    }

    func removeSourceSubscription(_ id: UUID) throws {
        var next = catalog
        next.sourceSubscriptions?.removeAll { $0.id == id }
        next.subscriptionSignatures?.removeValue(forKey: id)
        next.pendingSubscriptionUpdates?.remove(id)
        try commit(next)
    }

    func previewSourceSubscription(_ url: URL) async throws -> [BookSource] {
        try await subscriptionClient.preview(url)
    }

    func markSourceSubscriptionRefreshed(_ id: UUID, expecting url: URL? = nil) throws {
        guard let index = sourceSubscriptions.firstIndex(where: { $0.id == id && (url == nil || $0.url == url) }) else {
            throw LibraryError.subscriptionUnavailable
        }
        var next = catalog
        next.sourceSubscriptions?[index].lastRefreshedAt = Date()
        try commit(next)
    }

    func importSubscribedSources(_ additions: [BookSource], subscriptionID: UUID? = nil, expecting url: URL? = nil) throws -> Int {
        guard !additions.isEmpty else { return 0 }
        var next = catalog
        if let subscriptionID {
            guard let index = sourceSubscriptions.firstIndex(where: { $0.id == subscriptionID && (url == nil || $0.url == url) }) else {
                throw LibraryError.subscriptionUnavailable
            }
            var signatures = next.subscriptionSignatures ?? [:]
            for source in additions {
                signatures[subscriptionID, default: [:]][source.id] = try sourceSignature(source)
            }
            next.subscriptionSignatures = signatures
            next.sourceSubscriptions?[index].lastRefreshedAt = Date()
            next.pendingSubscriptionUpdates?.remove(subscriptionID)
        }
        mergeSources(additions, into: &next, preservingEnabledState: true)
        try commit(next)
        return additions.count
    }

    func refreshDueSourceSubscriptions() async {
        guard !isCheckingSubscriptions else { return }
        isCheckingSubscriptions = true
        defer { isCheckingSubscriptions = false }
        for subscription in sourceSubscriptions where subscription.isDue() {
            if Task.isCancelled { break }
            do {
                let remote = try await previewSourceSubscription(subscription.url)
                try Task.checkCancellation()
                try recordSubscriptionCheck(subscription, remote: remote)
            } catch {
                // A failed check leaves the last successful refresh and imported rules intact.
                continue
            }
        }
    }

    private func recordSubscriptionCheck(_ checked: BookSourceSubscription, remote: [BookSource]) throws {
        guard let index = sourceSubscriptions.firstIndex(of: checked) else { return }
        let localByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let managedSignatures = catalog.subscriptionSignatures?[checked.id] ?? [:]
        var updatedSignatures = managedSignatures
        var eligible: [BookSource] = []
        var hasUnappliedChanges = false
        for candidate in remote {
            let local = localByID[candidate.id]
            if let localTime = local?.lastUpdateTimestamp, let remoteTime = candidate.lastUpdateTimestamp, remoteTime < localTime {
                continue
            }
            let localSignature = try local.map(sourceSignature)
            let remoteSignature = try sourceSignature(candidate)
            guard localSignature != remoteSignature else { continue }
            if checked.silentUpdate, let localSignature, managedSignatures[candidate.id] == localSignature {
                eligible.append(candidate)
                updatedSignatures[candidate.id] = remoteSignature
            } else {
                hasUnappliedChanges = true
            }
        }

        var next = catalog
        next.sourceSubscriptions?[index].lastRefreshedAt = Date()
        if !eligible.isEmpty {
            mergeSources(eligible, into: &next, preservingEnabledState: true)
            next.subscriptionSignatures?[checked.id] = updatedSignatures
        }
        var pending = subscriptionsWithUpdates
        if hasUnappliedChanges { pending.insert(checked.id) }
        else { pending.remove(checked.id) }
        next.pendingSubscriptionUpdates = pending
        try commit(next)
    }

    func saveFeed(_ feed: FeedSubscription) throws {
        guard !feeds.contains(where: { $0.url == feed.url && $0.id != feed.id }) else {
            throw LibraryError.duplicateSubscription
        }
        var next = catalog
        var entries = feeds
        if let index = entries.firstIndex(where: { $0.id == feed.id }) { entries[index] = feed }
        else { entries.append(feed) }
        next.feeds = entries
        try commit(next)
    }

    func removeFeed(_ id: UUID) throws {
        var next = catalog
        next.feeds?.removeAll { $0.id == id }
        try commit(next)
    }

    private func mergeSources(_ additions: [BookSource], into next: inout Catalog, preservingEnabledState: Bool) {
        var indices = Dictionary(next.sources.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for var source in additions {
            if let index = indices[source.id] {
                if preservingEnabledState {
                    source.isEnabled = next.sources[index].isEnabled
                    source.simplifiesTitles = next.sources[index].simplifiesTitles
                }
                next.sources[index] = source
            } else {
                indices[source.id] = next.sources.count
                next.sources.append(source)
            }
        }
    }

    private func sourceSignature(_ source: BookSource) throws -> String {
        var normalized = source
        normalized.isEnabled = true
        normalized.simplifiesTitles = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(normalized))).base64EncodedString()
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

struct LibraryBookStorage: Sendable {
    var chapterBytes: [Int: Int64] = [:]
    var totalBytes: Int64 = 0
    var totalFileCount = 0
    var archivedBytes: Int64 = 0
    var archivedFileCount = 0
    var latestModification: Date?
}

struct LibraryCacheRemoval: Sendable {
    var bytes: Int64 = 0
    var fileCount = 0
}

private actor LibraryFiles {
    private static let initialCacheGeneration = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    let root: URL
    private var removedBooks = Set<UUID>()
    private var cacheGenerations: [UUID: UUID] = [:]

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

    func cacheGeneration(for bookID: UUID) -> UUID {
        cacheGenerations[bookID] ?? Self.initialCacheGeneration
    }

    @discardableResult
    func writeChapter(
        _ text: String, in book: LibraryBook, at index: Int, replaces: Bool, expectedCacheGeneration: UUID? = nil
    ) throws -> Bool {
        try Task.checkCancellation()
        guard !removedBooks.contains(book.id) else { throw LibraryError.bookUnavailable }
        if let expectedCacheGeneration, expectedCacheGeneration != cacheGeneration(for: book.id) { return false }
        let url = onlineChapterURL(in: book, at: index) ?? chapterURL(in: book.id, at: index)
        if !replaces, FileManager.default.fileExists(atPath: url.path) { return true }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    func migrateIndexedCache(for book: LibraryBook, expectedCacheGeneration: UUID? = nil) throws {
        if let expectedCacheGeneration, expectedCacheGeneration != cacheGeneration(for: book.id) { return }
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
        cacheGenerations.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    private func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func chapterURL(in id: UUID, at index: Int) -> URL {
        directory(for: id).appending(path: indexedChapterName(index))
    }

    private func onlineChapterURL(in book: LibraryBook, at index: Int) -> URL? {
        guard let edition = book.onlineID, let chapter = book.chapters[index].online else { return nil }
        return editionFolder(in: book.id, edition: edition)
            .appending(path: scopedChapterName(chapter))
    }

    private func editionFolder(in id: UUID, edition: String) -> URL {
        directory(for: id).appending(path: editionFolderName(edition), directoryHint: .isDirectory)
    }

    private func indexedChapterName(_ index: Int) -> String { "\(index).txt" }
    private func scopedChapterName(_ chapter: SourceChapter) -> String { "\(libraryDigest(chapter.id)).txt" }
    private func editionFolderName(_ edition: String) -> String { "edition-\(libraryDigest(edition))" }
}

extension LibraryFiles {
    private struct ChapterFile {
        let url: URL
        let relativePath: String
        let bytes: Int64
        let modified: Date?
    }

    private static let chapterFileKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey
    ]

    func chapterStorage(for book: LibraryBook) throws -> LibraryBookStorage {
        guard !removedBooks.contains(book.id) else { throw LibraryError.bookUnavailable }
        let inventory = try chapterFiles(for: book)
        guard !inventory.isEmpty else { return LibraryBookStorage() }
        let filesByPath = Dictionary(uniqueKeysWithValues: inventory.map { ($0.relativePath, $0) })
        var currentPaths = Set<String>()
        var usage = LibraryBookStorage()
        let currentEdition = book.onlineID.map(editionFolderName)
        let hasCurrentEditionFiles = currentEdition.map { edition in
            filesByPath.keys.contains { $0.hasPrefix(edition + "/") }
        } ?? false
        for index in book.chapters.indices {
            try Task.checkCancellation()
            let candidates = chapterStoragePaths(
                in: book, at: index, currentEdition: currentEdition, includesScopedFile: hasCurrentEditionFiles
            )
            for path in candidates {
                if let file = filesByPath[path] {
                    usage.chapterBytes[index, default: 0] += file.bytes
                    currentPaths.insert(path)
                }
            }
        }
        usage.totalFileCount = inventory.count
        for file in inventory {
            usage.totalBytes += file.bytes
            if !currentPaths.contains(file.relativePath) {
                usage.archivedBytes += file.bytes
                usage.archivedFileCount += 1
            }
            if let modified = file.modified, usage.latestModification.map({ $0 < modified }) ?? true {
                usage.latestModification = modified
            }
        }
        return usage
    }

    func clearChapterCache(in book: LibraryBook, indices: Set<Int>? = nil) throws -> LibraryCacheRemoval {
        guard !removedBooks.contains(book.id) else { throw LibraryError.bookUnavailable }
        guard book.onlineID != nil, book.sourceID != nil else { return LibraryCacheRemoval() }
        if let indices {
            guard !indices.isEmpty else { return LibraryCacheRemoval() }
            guard indices.allSatisfy(book.chapters.indices.contains) else { throw LibraryError.noChapters }
        }
        try Task.checkCancellation()
        let inventory = try chapterFiles(for: book)
        let targets: [ChapterFile]
        if let indices {
            let currentEdition = book.onlineID.map(editionFolderName)
            let paths = Set(indices.flatMap { chapterStoragePaths(in: book, at: $0, currentEdition: currentEdition) })
            targets = inventory.filter { paths.contains($0.relativePath) }
        } else {
            targets = inventory
        }
        try Task.checkCancellation()
        cacheGenerations[book.id] = UUID()

        var result = LibraryCacheRemoval()
        for file in targets {
            do {
                try FileManager.default.removeItem(at: file.url)
                result.bytes += file.bytes
                result.fileCount += 1
            } catch where missingChapterFile(error) {
                continue
            }
        }
        return result
    }

    func clearChapterCaches(in books: [LibraryBook]) throws -> LibraryCacheRemoval {
        var result = LibraryCacheRemoval()
        for book in books where !removedBooks.contains(book.id) {
            let removed = try clearChapterCache(in: book)
            result.bytes += removed.bytes
            result.fileCount += removed.fileCount
        }
        return result
    }

    private func chapterStoragePaths(
        in book: LibraryBook, at index: Int, currentEdition: String?, includesScopedFile: Bool = true
    ) -> [String] {
        let indexed = indexedChapterName(index)
        guard let currentEdition, let chapter = book.chapters[index].online else { return [indexed] }
        var paths = includesScopedFile ? ["\(currentEdition)/\(scopedChapterName(chapter))"] : []
        if book.indexedOnlineCache != false { paths.append(indexed) }
        return paths
    }

    private func chapterFiles(for book: LibraryBook) throws -> [ChapterFile] {
        guard try isChapterFolder(root) else { return [] }
        let bookFolder = directory(for: book.id)
        let includesEditions = book.onlineID != nil
        var inventory: [ChapterFile] = []
        for child in try chapterFolderContents(bookFolder) {
            try Task.checkCancellation()
            let name = child.lastPathComponent
            if isIndexedChapterName(name), let file = try inspectChapterFile(child) {
                inventory.append(file)
            } else if includesEditions, name.hasPrefix("edition-"), isLowercaseDigest(name.dropFirst(8)) {
                for file in try chapterFolderContents(child) where file.pathExtension == "txt" {
                    try Task.checkCancellation()
                    if isLowercaseDigest(file.deletingPathExtension().lastPathComponent[...]),
                       let chapter = try inspectChapterFile(file, inEdition: name) {
                        inventory.append(chapter)
                    }
                }
            }
        }
        return inventory
    }

    private func chapterFolderContents(_ folder: URL) throws -> [URL] {
        do {
            guard try isChapterFolder(folder) else { return [] }
            return try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: Array(Self.chapterFileKeys), options: [.skipsHiddenFiles]
            )
        } catch where missingChapterFile(error) {
            return []
        }
    }

    private func isChapterFolder(_ folder: URL) throws -> Bool {
        do {
            let values = try folder.resourceValues(forKeys: Self.chapterFileKeys)
            return values.isDirectory == true && values.isSymbolicLink != true
        } catch where missingChapterFile(error) {
            return false
        }
    }

    private func inspectChapterFile(_ url: URL, inEdition edition: String? = nil) throws -> ChapterFile? {
        do {
            let values = try url.resourceValues(forKeys: Self.chapterFileKeys)
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { return nil }
            let path = edition.map { "\($0)/\(url.lastPathComponent)" } ?? url.lastPathComponent
            return ChapterFile(url: url, relativePath: path, bytes: Int64(size), modified: values.contentModificationDate)
        } catch where missingChapterFile(error) {
            return nil
        }
    }

    private func isIndexedChapterName(_ name: String) -> Bool {
        guard name.hasSuffix(".txt"), let index = Int(name.dropLast(4)), index >= 0 else { return false }
        return indexedChapterName(index) == name
    }

    private func isLowercaseDigest(_ digest: Substring) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func missingChapterFile(_ error: Error) -> Bool {
        isMissingFile(error) || (error as? CocoaError)?.code == .fileNoSuchFile
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
    case duplicateSource
    case duplicateSubscription
    case subscriptionUnavailable
    case bookUnavailable
    case cacheWasCleared
    case editionAlreadyOnShelf
    case catalogUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noChapters: "没有可阅读的章节。"
        case .missingChapter: "章节文件已丢失，请重新导入这本书。"
        case .missingSource: "找不到原书源。请重新导入书源以加载这一章。"
        case .duplicateSource: "已有使用该地址的书源，请在列表中编辑它。"
        case .duplicateSubscription: "此地址已经订阅。"
        case .subscriptionUnavailable: "此订阅已移除。"
        case .bookUnavailable: "书架中的书籍已删除或书源已更换。"
        case .cacheWasCleared: "下载期间清理了缓存，请重新下载这一章。"
        case .editionAlreadyOnShelf: "这个书源的版本已在书架中，可从书架单独打开。"
        case .catalogUnavailable(let detail): "无法打开书架。\(detail)"
        }
    }
}
