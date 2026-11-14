import BookSources
import SwiftUI
import UniformTypeIdentifiers

private enum LibraryDestination: String, CaseIterable, Identifiable {
    case shelf
    case search
    case sources

    var id: Self { self }
    var title: String {
        switch self {
        case .shelf: "书架"
        case .search: "搜书"
        case .sources: "书源"
        }
    }
    var icon: String {
        switch self {
        case .shelf: "books.vertical"
        case .search: "magnifyingglass"
        case .sources: "text.badge.checkmark"
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var scheme
    @State private var destination: LibraryDestination? = .shelf
    @State private var column: NavigationSplitViewColumn = .detail
    @State private var reader: LibraryBook?
    @State private var bookToRemove: LibraryBook?
    @State private var importer: ImportFormat?
    @State private var isImporterPresented = false
    @State private var notice: Notice?
    @State private var isImporting = false

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            List(selection: $destination) {
                ForEach(LibraryDestination.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("阅读")
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 275)
            .scrollContentBackground(.hidden)
            .background(ReaderPalette.canvas(scheme))
        } detail: {
            selectedContent
                .background(ReaderPalette.canvas(scheme).ignoresSafeArea())
                .navigationTitle((destination ?? .shelf).title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if destination != .search {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                presentImporter(destination == .sources ? .sources : .books)
                            } label: {
                                Label("导入", systemImage: "plus")
                            }
                            .disabled(isImporting)
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        #if os(iOS)
        .fullScreenCover(item: $reader) { book in readingSession(for: book) }
        #else
        .sheet(item: $reader) { book in readingSession(for: book) }
        #endif
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: importer?.types ?? [.plainText],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message))
        }
        .confirmationDialog("从书架移除", isPresented: Binding(
            get: { bookToRemove != nil },
            set: { if !$0 { bookToRemove = nil } }
        ), presenting: bookToRemove) { book in
            Button("移除《\(book.title)》", role: .destructive) {
                Task {
                    do {
                        try await library.removeBook(book.id)
                    } catch {
                        showError(error)
                    }
                }
            }
        }
    }

    @ViewBuilder private var selectedContent: some View {
        switch destination ?? .shelf {
        case .shelf:
            BookshelfView(
                open: { reader = $0 },
                remove: { bookToRemove = $0 },
                importBooks: { presentImporter(.books) },
                goToSearch: { select(.search) },
                isImporting: isImporting
            )
        case .search:
            SearchView(
                showSources: { select(.sources) },
                openBook: { reader = $0 }
            )
        case .sources:
            SourcesView(importSources: { presentImporter(.sources) }, showError: showError)
        }
    }

    private func readingSession(for book: LibraryBook) -> some View {
        NavigationStack {
            ReaderView(
                bookID: book.id,
                title: book.title,
                author: book.author,
                chapters: book.chapters.map { ReaderChapter(title: $0.title) },
                initialPosition: library.position(for: book.id),
                loadChapter: { index in try await library.chapter(in: book, at: index) },
                onProgress: { library.savePosition($0, for: book.id) }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        reader = nil
                    } label: {
                        Label("返回书架", systemImage: "chevron.backward")
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
    }

    private func select(_ destination: LibraryDestination) {
        self.destination = destination
        column = .detail
    }

    private func presentImporter(_ format: ImportFormat) {
        importer = format
        isImporterPresented = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        let format = importer
        importer = nil
        switch result {
        case .failure(let error):
            showError(error)
        case .success(let urls):
            guard let format, !urls.isEmpty else { return }
            isImporting = true
            Task {
                defer { isImporting = false }
                var count = 0
                var failures: [String] = []
                for url in urls {
                    do {
                        switch format {
                        case .books:
                            _ = try await library.importLocalBook(from: url)
                            count += 1
                        case .sources:
                            count += try await library.importSources(from: url)
                        }
                    } catch {
                        failures.append("\(url.lastPathComponent) · \(error.localizedDescription)")
                    }
                }
                if !failures.isEmpty {
                    let detail = failures.prefix(4).joined(separator: "\n")
                    notice = Notice(title: "已导入 \(count) 项", message: detail)
                } else if format == .sources {
                    notice = Notice(title: "书源已导入", message: "已更新 \(count) 个书源。")
                }
            }
        }
    }

    private func showError(_ error: Error) {
        notice = Notice(title: "操作未完成", message: error.localizedDescription)
    }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum ImportFormat {
        case books, sources

        var types: [UTType] {
            switch self {
            case .books: [.plainText, .epub]
            case .sources: [.json]
            }
        }
    }
}

private struct BookshelfView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var scheme
    @State private var filter = ""
    let open: (LibraryBook) -> Void
    let remove: (LibraryBook) -> Void
    let importBooks: () -> Void
    let goToSearch: () -> Void
    let isImporting: Bool

    private var books: [LibraryBook] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? library.books : library.books.filter {
            $0.title.localizedStandardContains(query) || $0.author.localizedStandardContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("我的书架")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                if let error = library.startupError {
                    ContentUnavailableView("无法读取书架", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if isImporting {
                    ProgressView("正在导入…")
                        .padding(.vertical, 12)
                }

                if library.startupError == nil {
                    shelfContent
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .searchable(text: $filter, prompt: "查找书名或作者")
    }

    @ViewBuilder private var shelfContent: some View {
        if library.books.isEmpty {
            ContentUnavailableView {
                Label("书架里还没有书", systemImage: "books.vertical")
            } description: {
                Text("从「文件」导入 TXT 或 EPUB，或通过已添加的书源搜书。")
            } actions: {
                Button("导入本地书籍", action: importBooks)
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
                Button("搜书", action: goToSearch)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 350)
            .background(ReaderPalette.surface(scheme), in: .rect(cornerRadius: 16))
        } else if books.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 133, maximum: 195), spacing: 24, alignment: .top)], alignment: .leading, spacing: 27) {
                ForEach(books) { book in
                    shelfCard(book)
                }
            }
        }
    }

    private func shelfCard(_ book: LibraryBook) -> some View {
        Button {
            open(book)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                BookCover(title: book.title, author: book.author, url: book.coverURL)
                    .shadow(color: .black.opacity(0.14), radius: 6, x: 1, y: 4)
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                Text(readingStatus(book))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                remove(book)
            } label: {
                Label("从书架移除", systemImage: "trash")
            }
        }
    }

    private func readingStatus(_ book: LibraryBook) -> String {
        guard library.hasPosition(for: book.id) else { return "共 \(book.chapters.count) 章" }
        let index = min(library.position(for: book.id).chapterIndex + 1, book.chapters.count)
        return "读到第 \(index) / \(book.chapters.count) 章"
    }
}
