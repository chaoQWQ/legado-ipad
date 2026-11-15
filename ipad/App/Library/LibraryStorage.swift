import Foundation

struct LibraryStorageChapter: Identifiable, Sendable {
    let index: Int
    let title: String
    let bytes: Int64

    var id: Int { index }
}

struct LibraryStorageBook: Identifiable, Sendable {
    let id: UUID
    let revision: UUID?
    let title: String
    let author: String
    let coverURL: URL?
    let sourceName: String?
    let isOnline: Bool
    let totalChapters: Int
    let usage: LibraryBookStorage
    let chapters: [LibraryStorageChapter]

    var latestModification: Date? { usage.latestModification }
}

struct LibraryStorageSnapshot: Sendable {
    let books: [LibraryStorageBook]
    let galleryBytes: Int64
    let workspaceBytes: Int64
    let configurationBytes: Int64

    var localBytes: Int64 { books.lazy.filter { !$0.isOnline }.reduce(0) { $0 + $1.usage.totalBytes } }
    var onlineBytes: Int64 { books.lazy.filter(\.isOnline).reduce(0) { $0 + $1.usage.totalBytes } }
    var totalBytes: Int64 { localBytes + onlineBytes + galleryBytes + workspaceBytes + configurationBytes }
}
