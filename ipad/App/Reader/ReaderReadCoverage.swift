import CryptoKit
import Foundation

@MainActor
final class ReaderReadCoverage {
    static let shared = ReaderReadCoverage()

    struct Fingerprint: Codable, Equatable {
        fileprivate let digest: Data
        fileprivate let utf16Length: Int
    }

    private struct Span: Codable {
        var lower: Int
        var upper: Int

        var range: NSRange { NSRange(location: lower, length: upper - lower) }
    }

    private struct Chapter: Codable {
        var fingerprint: Fingerprint
        var spans: [Span] = []

        mutating func record(_ range: NSRange) -> Bool {
            var merged = Span(lower: range.location, upper: NSMaxRange(range))
            let first = spans.firstIndex { $0.upper >= merged.lower } ?? spans.endIndex
            if first < spans.endIndex, spans[first].lower <= merged.lower, spans[first].upper >= merged.upper {
                return false
            }
            var end = first
            while end < spans.endIndex, spans[end].lower <= merged.upper {
                merged.lower = min(merged.lower, spans[end].lower)
                merged.upper = max(merged.upper, spans[end].upper)
                end += 1
            }
            spans.replaceSubrange(first..<end, with: [merged])
            return true
        }
    }

    private struct Book: Codable {
        var sources: [String: [Int: Chapter]] = [:]
    }

    private let directory: URL?
    private var books: [UUID: Book] = [:]
    private var dirty: Set<UUID> = []
    private var writes: [UUID: Task<Void, Never>] = [:]

    init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appending(path: "LegadoPad/ReadCoverage", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    nonisolated static func fingerprint(of text: String) -> Fingerprint {
        Fingerprint(digest: Data(SHA256.hash(data: Data(text.utf8))), utf16Length: text.utf16.count)
    }

    nonisolated static func paragraph(in text: String, at offset: Int) -> NSRange? {
        let string = text as NSString
        guard string.length > 0 else { return nil }
        // NSString returns an empty paragraph at EOF for text with a final newline.
        let location = min(max(0, offset), string.length - 1)
        let range = string.paragraphRange(for: NSRange(location: location, length: 0))
        return range.length > 0 ? range : nil
    }

    func record(bookID: UUID, sourceID: String?, chapterIndex: Int, fingerprint: Fingerprint, range: NSRange) {
        guard chapterIndex >= 0, range.location >= 0, range.location <= fingerprint.utf16Length,
              range.length > 0, range.length <= fingerprint.utf16Length - range.location else { return }
        load(bookID)
        let source = sourceKey(sourceID)
        var chapter = books[bookID]?.sources[source]?[chapterIndex] ?? Chapter(fingerprint: fingerprint)
        if chapter.fingerprint != fingerprint { chapter = Chapter(fingerprint: fingerprint) }
        guard chapter.record(range) else { return }
        books[bookID]?.sources[source, default: [:]][chapterIndex] = chapter
        dirty.insert(bookID)
        guard writes[bookID] == nil else { return }
        writes[bookID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            self?.flush(bookID: bookID)
        }
    }

    func ranges(bookID: UUID, sourceID: String?, chapterIndex: Int, fingerprint: Fingerprint) -> [NSRange] {
        load(bookID)
        guard let chapter = books[bookID]?.sources[sourceKey(sourceID)]?[chapterIndex],
              chapter.fingerprint == fingerprint else { return [] }
        return chapter.spans.map(\.range)
    }

    func chapterIndexes(bookID: UUID, sourceID: String?) -> [Int] {
        load(bookID)
        guard let chapters = books[bookID]?.sources[sourceKey(sourceID)] else { return [] }
        return chapters.keys.sorted()
    }

    func flush(bookID: UUID) {
        writes.removeValue(forKey: bookID)?.cancel()
        guard dirty.contains(bookID), let directory, let book = books[bookID] else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(book)
            try data.write(to: location(bookID, in: directory), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            dirty.remove(bookID)
        } catch {
            // Keep in-memory coverage and retry at the next reading or lifecycle save.
        }
    }

    func remove(bookID: UUID) {
        writes.removeValue(forKey: bookID)?.cancel()
        books.removeValue(forKey: bookID)
        dirty.remove(bookID)
        if let directory { try? FileManager.default.removeItem(at: location(bookID, in: directory)) }
    }

    private func load(_ id: UUID) {
        guard books[id] == nil else { return }
        if let directory, let data = try? Data(contentsOf: location(id, in: directory)),
           let stored = try? JSONDecoder().decode(Book.self, from: data) {
            books[id] = stored
        } else {
            books[id] = Book()
        }
    }

    private func sourceKey(_ sourceID: String?) -> String { sourceID.map { "online:\($0)" } ?? "local" }

    private func location(_ bookID: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(bookID.uuidString).json", directoryHint: .notDirectory)
    }
}
