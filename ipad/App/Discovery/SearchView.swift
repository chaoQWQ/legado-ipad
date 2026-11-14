import BookSources
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var request: SearchRequest?
    @State private var results: [SourceBook] = []
    @State private var failures: [SearchFailure] = []
    @State private var finishedSources = 0
    @State private var selection: SourceBook?
    @State private var bookToOpen: LibraryBook?
    @FocusState private var searchFocused: Bool

    let showSources: () -> Void
    let openBook: (LibraryBook) -> Void

    private var enabledSources: [BookSource] { library.sources.filter(\.isEnabled) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("搜书")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                if enabledSources.isEmpty {
                    ContentUnavailableView {
                        Label("需要启用书源", systemImage: "magnifyingglass")
                    } description: {
                        Text("导入或启用 Legado 书源后，即可按书名或作者搜索。")
                    } actions: {
                        Button("管理书源", action: showSources)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    searchField
                    searchResults
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: request?.id) {
            if let request { await runSearch(request) }
        }
        .sheet(item: $selection, onDismiss: openSelectedBook) { book in
            if let source = library.sources.first(where: { $0.id == book.sourceID }) {
                OnlineBookView(result: book, source: source) { bookToOpen = $0 }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("书名或作者", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit(startSearch)
            Button("搜索", action: startSearch)
                .buttonStyle(.borderedProminent)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(ReaderPalette.surface(scheme), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private var searchResults: some View {
        if let request {
            if finishedSources < request.sources.count {
                ProgressView("正在搜索 \(finishedSources) / \(request.sources.count) 个书源…")
            } else if results.isEmpty {
                ContentUnavailableView.search(text: request.keyword)
            }

            if !failures.isEmpty {
                DisclosureGroup("\(failures.count) 个书源搜索失败") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(failures) { failure in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(failure.source)
                                    .font(.subheadline.weight(.medium))
                                Text(failure.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .padding(14)
                .background(ReaderPalette.surface(scheme), in: .rect(cornerRadius: 12))
            }

            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(results) { book in
                    resultRow(book)
                }
            }
        }
    }

    private func resultRow(_ book: SourceBook) -> some View {
        Button {
            selection = book
        } label: {
            HStack(spacing: 14) {
                BookCover(title: book.title, author: book.author, url: book.coverURL)
                    .frame(width: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title).font(.headline)
                    if !book.author.isEmpty {
                        Text(book.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let source = library.sources.first(where: { $0.id == book.sourceID }) {
                        Text(source.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(ReaderPalette.surface(scheme), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func startSearch() {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = enabledSources
        guard !keyword.isEmpty, !sources.isEmpty else { return }

        searchFocused = false
        results = []
        failures = []
        finishedSources = 0
        request = SearchRequest(keyword: keyword, sources: sources)
    }

    private func openSelectedBook() {
        guard let bookToOpen else { return }
        self.bookToOpen = nil
        openBook(bookToOpen)
    }

    private func runSearch(_ request: SearchRequest) async {
        let client = library.client

        await withTaskGroup(of: SearchOutcome.self) { tasks in
            var remaining = request.sources.makeIterator()
            for _ in 0..<min(5, request.sources.count) {
                if let source = remaining.next() {
                    tasks.addTask { await Self.search(request.keyword, in: source, with: client) }
                }
            }

            for await outcome in tasks {
                guard !Task.isCancelled, self.request?.id == request.id else {
                    tasks.cancelAll()
                    return
                }
                switch outcome {
                case .success(let books):
                    var ids = Set(results.map(\.id))
                    results.append(contentsOf: books.filter { ids.insert($0.id).inserted })
                case .failure(let failure):
                    failures.append(failure)
                }
                finishedSources += 1
                if let source = remaining.next() {
                    tasks.addTask { await Self.search(request.keyword, in: source, with: client) }
                }
            }
        }
    }

    nonisolated private static func search(_ query: String, in source: BookSource, with client: BookSourceClient) async -> SearchOutcome {
        do {
            return .success(try await client.search(query, in: source))
        } catch {
            return .failure(SearchFailure(id: source.id, source: source.name, message: error.localizedDescription))
        }
    }

    private struct SearchRequest: Sendable {
        let id = UUID()
        let keyword: String
        let sources: [BookSource]
    }

    private struct SearchFailure: Identifiable, Sendable {
        let id: String
        let source: String
        let message: String
    }

    private enum SearchOutcome: Sendable {
        case success([SourceBook])
        case failure(SearchFailure)
    }
}

private struct OnlineBookView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var details: SourceBook?
    @State private var chapters: [SourceChapter] = []
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var attempt = 0

    let result: SourceBook
    let source: BookSource
    let openBook: (LibraryBook) -> Void

    private var book: SourceBook { details ?? result }
    private var existing: LibraryBook? { library.existingBook(book) ?? library.existingBook(result) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 20) {
                        BookCover(title: book.title, author: book.author, url: book.coverURL)
                            .frame(width: 100)
                        VStack(alignment: .leading, spacing: 9) {
                            Text(book.title)
                                .font(.system(.title2, design: .serif, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            if !book.author.isEmpty {
                                Text(book.author).foregroundStyle(.secondary)
                            }
                            Label(source.name, systemImage: "text.badge.checkmark")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !book.introduction.isEmpty {
                        Text(book.introduction)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    actions
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(ReaderPalette.canvas(scheme).ignoresSafeArea())
            .navigationTitle("书籍详情")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task(id: attempt) { await loadDetails() }
        .alert("无法加入书架", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("好", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder private var actions: some View {
        if let existing {
            Button("继续阅读") { show(existing) }
                .buttonStyle(.borderedProminent)
        } else if let loadError {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("重试") {
                self.loadError = nil
                attempt += 1
            }
            .buttonStyle(.bordered)
        } else if chapters.isEmpty {
            ProgressView("正在获取目录…")
        } else {
            Text("共 \(chapters.count) 章")
                .foregroundStyle(.secondary)
            HStack {
                Button("加入书架并阅读") { addToShelf(read: true) }
                    .buttonStyle(.borderedProminent)
                Button("加入书架") { addToShelf(read: false) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func loadDetails() async {
        guard existing == nil else { return }
        do {
            let loaded = try await library.client.details(for: result, in: source)
            try Task.checkCancellation()
            details = loaded
            let listing = try await library.client.chapters(for: loaded, in: source)
            try Task.checkCancellation()
            guard !listing.isEmpty else { throw LibraryError.noChapters }
            chapters = listing
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func addToShelf(read: Bool) {
        do {
            let added = try library.addOnlineBook(book, chapters: chapters)
            if read { show(added) }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func show(_ book: LibraryBook) {
        openBook(book)
        dismiss()
    }
}
