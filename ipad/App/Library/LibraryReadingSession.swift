import SwiftUI

struct ReaderOnlineActions {
    let sourceName: String
    let simplifiesText: Bool
    let simplifiesTitles: Bool
    let refreshChapter: (Int) async throws -> String
    let download: (Int) -> AnyView
    let changeSource: (Int) -> AnyView
}

struct LibraryReadingSession: View {
    @EnvironmentObject private var library: LibraryStore
    let bookID: UUID
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let book = library.books.first(where: { $0.id == bookID }) {
                    reader(book)
                        .id(book.readerIdentity)
                } else {
                    ContentUnavailableView("无法打开这本书", systemImage: "book.closed")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: close) {
                        Label("返回书架", systemImage: "chevron.backward")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
    }

    private func reader(_ book: LibraryBook) -> some View {
        ReaderView(
            bookID: book.id,
            title: book.title,
            author: book.author,
            chapters: book.chapters.map {
                ReaderChapter(title: $0.title, identity: "\(book.readerIdentity)|\($0.online?.id ?? "")")
            },
            initialPosition: library.position(for: book.id),
            loadChapter: { index in try await library.chapter(in: book, at: index) },
            onProgress: { library.savePosition($0, for: book) },
            cachedChapter: { index in try await library.cachedChapter(in: book, at: index) },
            online: onlineActions(for: book),
            sourceID: book.sourceID,
            readingIdentity: book.readerIdentity,
            bookURLForAI: ReaderAILibraryTools.bookURL(for: book),
            bookmarkKey: book.readerBookmarkKey
        )
    }

    private func onlineActions(for book: LibraryBook) -> ReaderOnlineActions? {
        guard book.sourceID != nil else { return nil }
        return ReaderOnlineActions(
            sourceName: library.sourceName(for: book),
            simplifiesText: library.sourceSimplifiesText(for: book),
            simplifiesTitles: library.sourceSimplifiesTitles(for: book),
            refreshChapter: { try await library.refreshChapter(in: book, at: $0) },
            download: { index in
                AnyView(ChapterDownloadView(library: library, book: book, startIndex: index))
            },
            changeSource: { index in
                AnyView(SwitchBookSourceView(library: library, book: book, chapterIndex: index))
            }
        )
    }
}
