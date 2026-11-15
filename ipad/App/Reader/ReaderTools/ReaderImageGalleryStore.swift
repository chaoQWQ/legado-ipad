import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ReaderImageContext: Codable, Equatable, Sendable {
    let bookID: UUID?
    let bookTitle: String
    let author: String
    let chapterIndex: Int
    let chapterTitle: String
    let sourceText: String
    let originalOffset: Int?
    var sourceID: String? = nil
    var paragraphText: String? = nil

    var canInsert: Bool {
        bookID != nil && chapterIndex >= 0 && (originalOffset ?? -1) >= 0
    }
}

struct ReaderImageGalleryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let prompt: String
    let provider: String
    let model: String
    let context: ReaderImageContext
    let createdAt: Date
    fileprivate let format: ReaderImageFileFormat
    var isFavorite = false
    var isInserted = false

    var title: String {
        let compact = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return compact.isEmpty ? "阅读插图" : String(compact.prefix(54))
    }

    fileprivate var filename: String { "\(id.uuidString).\(format.rawValue)" }
}

@MainActor
final class ReaderImageGalleryStore: ObservableObject {
    static let shared = ReaderImageGalleryStore()

    @Published private(set) var entries: [ReaderImageGalleryEntry] = []
    @Published private(set) var loadError: String?

    private let root: URL
    private let disk: ReaderImageGalleryDisk
    private var revision: UInt64 = 0

    init(root: URL = .applicationSupportDirectory.appending(path: "LegadoPad/GeneratedImages", directoryHint: .isDirectory)) {
        self.root = root
        disk = ReaderImageGalleryDisk(root: root)
    }

    func load() async {
        do {
            update(try await disk.snapshot())
            loadError = nil
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    @discardableResult
    func store(
        _ data: Data, prompt: String, provider: String, model: String, context: ReaderImageContext
    ) async throws -> ReaderImageGalleryEntry {
        let (entry, snapshot) = try await disk.store(
            data, prompt: prompt, provider: provider, model: model, context: context
        )
        update(snapshot)
        return entry
    }

    func setFavorite(_ favorite: Bool, for id: UUID) async throws {
        update(try await disk.change(id) { $0.isFavorite = favorite })
    }

    func setInserted(_ inserted: Bool, for id: UUID) async throws {
        update(try await disk.change(id) { entry in
            guard !inserted || entry.context.canInsert else { throw ReaderImageGalleryError.missingPlacement }
            entry.isInserted = inserted
            if inserted { entry.isFavorite = true }
        })
    }

    func delete(_ id: UUID) async throws {
        update(try await disk.delete(id))
    }

    func fileURL(for entry: ReaderImageGalleryEntry) -> URL {
        root.appending(path: entry.filename, directoryHint: .notDirectory)
    }

    func insertedImages(bookID: UUID, chapterIndex: Int) -> [ReaderImageGalleryEntry] {
        entries.reversed().filter {
            $0.isInserted && $0.context.bookID == bookID && $0.context.chapterIndex == chapterIndex
        }.sorted { first, second in
            (first.context.originalOffset ?? 0) < (second.context.originalOffset ?? 0)
        }
    }

    private func update(_ snapshot: ReaderImageGalleryDisk.Snapshot) {
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        if entries != snapshot.entries { entries = snapshot.entries }
    }
}

enum ReaderImageGalleryError: LocalizedError {
    case invalidImage, imageTooLarge, missingPlacement, missingImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: "服务没有返回有效的图片文件。"
        case .imageTooLarge: "生成的图片超过支持的尺寸。"
        case .missingPlacement: "当前章节没有可用的图片插入位置。"
        case .missingImage: "图片已从图库移除。"
        }
    }
}

private enum ReaderImageFileFormat: String, Codable, Sendable {
    case png, jpg, heic, gif, webp

    static func inspect(_ data: Data) throws -> Self {
        guard !data.isEmpty else { throw ReaderImageGalleryError.invalidImage }
        guard data.count <= 32 * 1024 * 1024 else { throw ReaderImageGalleryError.imageTooLarge }
        let cache = [kCGImageSourceShouldCache as String: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, cache),
              let kind = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, cache) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else {
            throw ReaderImageGalleryError.invalidImage
        }
        guard width <= 12_000, height <= 12_000, width * height <= 32_000_000 else {
            throw ReaderImageGalleryError.imageTooLarge
        }
        let thumbnailOptions: [String: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways as String: true,
            kCGImageSourceThumbnailMaxPixelSize as String: 320,
            kCGImageSourceShouldCacheImmediately as String: true
        ]
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) != nil else {
            throw ReaderImageGalleryError.invalidImage
        }
        switch kind as String {
        case UTType.png.identifier: return .png
        case UTType.jpeg.identifier: return .jpg
        case UTType.heic.identifier, UTType.heif.identifier: return .heic
        case UTType.gif.identifier: return .gif
        case UTType.webP.identifier: return .webp
        default: throw ReaderImageGalleryError.invalidImage
        }
    }
}

private actor ReaderImageGalleryDisk {
    struct Snapshot: Sendable {
        let revision: UInt64
        let entries: [ReaderImageGalleryEntry]
    }

    private let root: URL
    private var stored: [ReaderImageGalleryEntry]?
    private var revision: UInt64 = 0

    init(root: URL) { self.root = root }

    func snapshot() throws -> Snapshot {
        let current = try records()
        let deadline = Date().addingTimeInterval(-3 * 24 * 60 * 60)
        let retained = current.filter { $0.isFavorite || $0.isInserted || $0.createdAt >= deadline }
        if retained.count != current.count {
            try commit(retained)
            let ids = Set(retained.map(\.id))
            for removed in current where !ids.contains(removed.id) {
                try? FileManager.default.removeItem(at: fileURL(removed))
            }
        }
        return result()
    }

    func store(_ data: Data, prompt: String, provider: String, model: String, context: ReaderImageContext)
        throws -> (ReaderImageGalleryEntry, Snapshot) {
        try Task.checkCancellation()
        _ = try snapshot()
        let format = try ReaderImageFileFormat.inspect(data)
        let entry = ReaderImageGalleryEntry(
            id: UUID(), prompt: prompt, provider: provider, model: model, context: context,
            createdAt: Date(), format: format
        )
        var next = try records()
        next.insert(entry, at: 0)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = fileURL(entry)
        try data.write(to: url, options: .atomic)
        do {
            try commit(next)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return (entry, result())
    }

    func change(
        _ id: UUID, operation: @Sendable (inout ReaderImageGalleryEntry) throws -> Void
    ) throws -> Snapshot {
        var next = try records()
        guard let index = next.firstIndex(where: { $0.id == id }),
              FileManager.default.fileExists(atPath: fileURL(next[index]).path) else {
            throw ReaderImageGalleryError.missingImage
        }
        try operation(&next[index])
        try commit(next)
        return result()
    }

    func delete(_ id: UUID) throws -> Snapshot {
        var next = try records()
        guard let index = next.firstIndex(where: { $0.id == id }) else { return result() }
        let entry = next.remove(at: index)
        try commit(next)
        try? FileManager.default.removeItem(at: fileURL(entry))
        return result()
    }

    private var indexURL: URL { root.appending(path: "gallery.json", directoryHint: .notDirectory) }

    private func records() throws -> [ReaderImageGalleryEntry] {
        if let stored { return stored }
        let entries: [ReaderImageGalleryEntry]
        do {
            let index = try Data(contentsOf: indexURL)
            entries = try JSONDecoder().decode([ReaderImageGalleryEntry].self, from: index)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            entries = []
        }
        let existing = entries.filter { FileManager.default.fileExists(atPath: fileURL($0).path) }
        stored = existing
        return existing
    }

    private func commit(_ entries: [ReaderImageGalleryEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try data.write(to: indexURL, options: .atomic)
        stored = entries
        revision += 1
    }

    private func result() -> Snapshot {
        Snapshot(revision: revision, entries: stored ?? [])
    }

    private func fileURL(_ entry: ReaderImageGalleryEntry) -> URL {
        root.appending(path: entry.filename, directoryHint: .notDirectory)
    }
}
