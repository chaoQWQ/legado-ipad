import BookSources
import SwiftUI

struct LibraryStorageView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var inventory = LibraryStorageInventory()
    @State private var category = Category.online
    @State private var sort = Sort.recent
    @State private var query = ""
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var alert: LibraryStorageAlert?
    @State private var chapterRoute: LibraryStorageBookRoute?
    @State private var pendingChapter: (book: LibraryBook, index: Int)?

    let openCachedChapter: (LibraryBook, Int) -> Void

    var body: some View {
        let visible = visibleBooks
        Group {
            if let snapshot = inventory.snapshot {
                List {
                    summary(snapshot)
                    Section {
                        Picker("书籍类型", selection: $category) {
                            ForEach(Category.allCases) { item in Text(item.rawValue).tag(item) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if let error = inventory.scanError {
                        Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                    }
                    bookList(visible)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .searchable(text: $query, prompt: "搜索书名、作者或书源")
                .refreshable { await inventory.refresh(library) }
            } else if let error = inventory.scanError {
                ContentUnavailableView {
                    Label("无法统计存储", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试", action: reload)
                }
            } else {
                ProgressView("正在统计存储…")
            }
        }
        .navigationTitle("缓存管理")
        .sheet(item: $chapterRoute, onDismiss: openPendingChapter) { item in
            NavigationStack {
                LibraryStorageChaptersView(item: item, inventory: inventory) { book, index in
                    guard chapterRoute?.id == item.id else { return }
                    pendingChapter = (book, index)
                    chapterRoute = nil
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { chapterRoute = nil }
                    }
                }
            }
        }
        .toolbar { actions }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                LibraryStorageSelectionBar(
                    count: selectedBooks.count, unit: "本", hasVisibleItems: !visible.isEmpty,
                    allVisibleSelected: !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) },
                    selectVisible: toggleVisible, remove: confirmSelected
                )
                .disabled(inventory.isBusy)
            }
        }
        .task { await inventory.refresh(library) }
        .onChange(of: category) { _, _ in endSelection() }
        .alert(item: $alert) { $0.alert(delete: performDeletion) }
    }

    private func summary(_ snapshot: LibraryStorageSnapshot) -> some View {
        Section {
            LabeledContent("总占用", value: storageSize(snapshot.totalBytes))
            LabeledContent("在线章节缓存", value: storageSize(snapshot.onlineBytes))
            LabeledContent("导入的本地书籍", value: storageSize(snapshot.localBytes))
            if snapshot.galleryBytes > 0 { LabeledContent("AI 图库与章首插画", value: storageSize(snapshot.galleryBytes)) }
            if snapshot.workspaceBytes > 0 { LabeledContent("AI 工作区", value: storageSize(snapshot.workspaceBytes)) }
            if snapshot.configurationBytes > 0 { LabeledContent("配置、阅读记录与 AI 对话", value: storageSize(snapshot.configurationBytes)) }
        } header: {
            Text("存储用量")
        } footer: {
            Text("按文件大小统计。iPadOS 还会计入应用本体和系统缓存。")
        }
    }

    private func bookList(_ visible: [LibraryStorageBook]) -> some View {
        Section {
            if visible.isEmpty {
                if !term.isEmpty {
                    ContentUnavailableView.search(text: term)
                } else {
                    ContentUnavailableView(
                        category == .online ? "暂无在线章节缓存" : "暂无本地导入书籍",
                        systemImage: category == .online ? "arrow.down.circle" : "books.vertical"
                    )
                }
            } else {
                ForEach(visible) { item in
                    if isSelecting {
                        Button {
                            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                        } label: {
                            HStack(spacing: 12) {
                                selectionMark(selection.contains(item.id))
                                bookRow(item)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
                    } else {
                        Button {
                            chapterRoute = LibraryStorageBookRoute(book: item)
                        } label: {
                            HStack(spacing: 10) {
                                bookRow(item)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(allowsFullSwipe: false) {
                            if item.isOnline {
                                Button("删除缓存", role: .destructive) { alert = .confirm(.book(item)) }
                            }
                        }
                        .contextMenu {
                            if item.isOnline {
                                Button("删除本书缓存", systemImage: "trash", role: .destructive) {
                                    alert = .confirm(.book(item))
                                }
                            }
                        }
                    }
                }
                .disabled(inventory.isBusy)
            }
        } header: {
            if category == .online {
                Text("共 \(cachedBooks.count) 本，已缓存 \(cachedChapters) 章")
            } else {
                Text("本地导入 · \(categoryBooks.count) 本")
            }
        }
    }

    private func bookRow(_ item: LibraryStorageBook) -> some View {
        HStack(spacing: 12) {
            BookCover(title: item.title, author: item.author, url: nil)
                .frame(width: 36, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if !item.author.isEmpty { Text(item.author).font(.subheadline).foregroundStyle(.secondary) }
                if let source = item.sourceName, !source.isEmpty {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(storageSize(item.usage.totalBytes))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
                if item.isOnline {
                    Text("\(item.chapters.count) / \(item.totalChapters) 章")
                } else {
                    Text("\(item.totalChapters) 章")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ToolbarContentBuilder
    private var actions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if category == .online, isSelecting || !cachedBooks.isEmpty {
                Button(isSelecting ? "完成" : "选择") {
                    if isSelecting { endSelection() } else { isSelecting = true }
                }
                .disabled(inventory.isBusy)
            }
            Menu {
                Picker("缓存排序", selection: $sort) {
                    ForEach(Sort.allCases) { item in Text(item.rawValue).tag(item) }
                }
                Button("重新统计", systemImage: "arrow.clockwise", action: reload)
                    .disabled(inventory.isBusy)
                if category == .online, !cachedBooks.isEmpty {
                    Button("删除全部在线缓存", systemImage: "trash", role: .destructive) {
                        alert = .confirm(.books(cachedBooks, all: true))
                    }
                    .disabled(inventory.isBusy)
                }
            } label: {
                Label("缓存排序与操作", systemImage: "ellipsis.circle")
            }
        }
    }

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cachedBooks: [LibraryStorageBook] {
        inventory.snapshot?.books.filter { $0.isOnline && $0.usage.totalFileCount > 0 } ?? []
    }
    private var cachedChapters: Int { cachedBooks.reduce(0) { $0 + $1.chapters.count } }
    private var categoryBooks: [LibraryStorageBook] {
        category == .online ? cachedBooks : inventory.snapshot?.books.filter { !$0.isOnline } ?? []
    }
    private var selectedBooks: [LibraryStorageBook] { cachedBooks.filter { selection.contains($0.id) } }
    private var visibleBooks: [LibraryStorageBook] {
        let filtered = categoryBooks.filter {
            term.isEmpty || [$0.title, $0.author, $0.sourceName ?? ""].contains { $0.localizedStandardContains(term) }
        }
        return filtered.sorted { first, second in
            switch sort {
            case .recent:
                let lhs = first.latestModification ?? .distantPast
                let rhs = second.latestModification ?? .distantPast
                if lhs != rhs { return lhs > rhs }
            case .size:
                if first.usage.totalBytes != second.usage.totalBytes { return first.usage.totalBytes > second.usage.totalBytes }
            case .name: break
            }
            let comparison = first.title.localizedStandardCompare(second.title)
            return comparison == .orderedSame ? first.id.uuidString < second.id.uuidString : comparison == .orderedAscending
        }
    }

    private func reload() { Task { await inventory.refresh(library) } }

    private func toggleVisible() {
        let visible = Set(visibleBooks.map(\.id))
        if visible.isSubset(of: selection) { selection.subtract(visible) }
        else { selection.formUnion(visible) }
    }

    private func endSelection() {
        selection.removeAll()
        isSelecting = false
    }

    private func confirmSelected() {
        if !selectedBooks.isEmpty { alert = .confirm(.books(selectedBooks, all: false)) }
    }

    private func performDeletion(_ deletion: LibraryStorageDeletion) {
        Task {
            do {
                guard let removal = try await inventory.remove(deletion, in: library) else { return }
                endSelection()
                alert = .removed(removal)
            } catch {
                alert = .error("无法删除缓存", error.localizedDescription)
            }
        }
    }

    private func openPendingChapter() {
        guard let pendingChapter else { return }
        self.pendingChapter = nil
        guard let book = library.currentBook(pendingChapter.book.id),
              book.readingRevision == pendingChapter.book.readingRevision else { return }
        openCachedChapter(book, pendingChapter.index)
    }

    private enum Category: String, CaseIterable, Identifiable {
        case online = "在线缓存", local = "本地导入"
        var id: Self { self }
    }

    private enum Sort: String, CaseIterable, Identifiable {
        case recent = "最近更新", name = "书名", size = "占用空间"
        var id: Self { self }
    }
}

private struct LibraryStorageBookRoute: Identifiable {
    let id = UUID()
    let bookID: UUID
    let revision: UUID?
    let title: String

    init(book: LibraryStorageBook) {
        bookID = book.id
        revision = book.revision
        title = book.title
    }
}

private struct LibraryStorageChaptersView: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject var inventory: LibraryStorageInventory
    @State private var query = ""
    @State private var filter = Filter.cached
    @State private var isSelecting = false
    @State private var selection = Set<Int>()
    @State private var alert: LibraryStorageAlert?
    @State private var openingIndex: Int?
    @State private var downloadingIndex: Int?
    @State private var downloadJob: Task<Void, Never>?

    let item: LibraryStorageBookRoute
    let openCachedChapter: (LibraryBook, Int) -> Void

    init(item: LibraryStorageBookRoute, inventory: LibraryStorageInventory, openCachedChapter: @escaping (LibraryBook, Int) -> Void) {
        self.item = item
        self.inventory = inventory
        self.openCachedChapter = openCachedChapter
    }

    var body: some View {
        let visible = filteredChapters
        let visibleCached = visible.filter { $0.bytes != nil }
        List {
            if let current {
                Section {
                    LabeledContent(current.isOnline ? "已缓存章节" : "本地章节", value: "\(current.chapters.count) / \(current.totalChapters)")
                    LabeledContent("占用空间", value: storageSize(current.usage.totalBytes))
                    if current.isOnline, current.usage.archivedFileCount > 0 {
                        LabeledContent("旧版本缓存", value: storageSize(current.usage.archivedBytes))
                    }
                }
                if current.isOnline {
                    Section {
                        Picker("缓存状态", selection: $filter) {
                            ForEach(Filter.allCases) { item in Text(item.rawValue).tag(item) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section(current.isOnline ? "缓存目录" : "章节") {
                    if visible.isEmpty {
                        if term.isEmpty {
                            Text(emptyText(current.isOnline)).foregroundStyle(.secondary)
                        } else {
                            ContentUnavailableView.search(text: term)
                        }
                    } else {
                        ForEach(visible) { chapter in
                            chapterRow(chapter, in: current)
                        }
                    }
                }
            } else {
                ContentUnavailableView("书籍已移除或已换源", systemImage: "book.closed")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle(current?.title ?? item.title)
        .searchable(text: $query, prompt: "搜索章节")
        .refreshable {
            if downloadJob == nil { await inventory.refresh(library) }
        }
        .onDisappear { downloadJob?.cancel() }
        .onChange(of: filter) { _, value in
            if value == .uncached, isSelecting { endSelection() }
        }
        .toolbar {
            if let current, current.isOnline {
                ToolbarItemGroup(placement: .primaryAction) {
                    if isSelecting || (!current.chapters.isEmpty && filter != .uncached) {
                        Button(isSelecting ? "完成" : "选择") {
                            isSelecting.toggle()
                            selection.removeAll()
                        }
                        .disabled(operationInProgress)
                    }
                    if current.usage.totalFileCount > 0 {
                        Menu {
                            Button("删除本书缓存", systemImage: "trash", role: .destructive) {
                                alert = .confirm(.book(current))
                            }
                            .disabled(operationInProgress)
                        } label: {
                            Label("缓存操作", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting, current != nil {
                LibraryStorageSelectionBar(
                    count: selectedIndices.count, unit: "章", hasVisibleItems: !visibleCached.isEmpty,
                    allVisibleSelected: !visibleCached.isEmpty && visibleCached.allSatisfy { selection.contains($0.index) },
                    selectVisible: toggleVisible, remove: confirmSelected
                )
                .disabled(operationInProgress)
            }
        }
        .alert(item: $alert) { $0.alert(delete: performDeletion) }
    }

    private var current: LibraryStorageBook? {
        guard currentBook != nil else { return nil }
        return inventory.snapshot?.books.first { $0.id == item.bookID && $0.revision == item.revision }
    }
    private var currentBook: LibraryBook? {
        guard let book = library.currentBook(item.bookID), book.readingRevision == item.revision else { return nil }
        return book
    }
    private var operationInProgress: Bool {
        inventory.isBusy || openingIndex != nil || downloadJob != nil
    }
    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var filteredChapters: [ChapterEntry] {
        guard let current else { return [] }
        let chapters: [ChapterEntry]
        if !current.isOnline || filter == .cached {
            chapters = current.chapters.map { ChapterEntry(index: $0.index, title: $0.title, bytes: $0.bytes) }
        } else if let book = currentBook {
            let source = library.sources.first { $0.id == book.sourceID }
            chapters = book.chapters.enumerated().compactMap { index, chapter in
                let bytes = current.usage.chapterBytes[index]
                if filter == .uncached, bytes != nil { return nil }
                let title = source?.displayTitle(chapter.title) ?? chapter.title
                return ChapterEntry(index: index, title: title, bytes: bytes)
            }
        } else {
            chapters = []
        }
        let query = term
        guard !query.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedStandardContains(query) || query == String($0.index + 1) }
    }
    private var visibleIndices: Set<Int> { Set(filteredChapters.filter { $0.bytes != nil }.map(\.index)) }
    private var selectedIndices: Set<Int> { selection.intersection((current?.chapters ?? []).map(\.index)) }

    @ViewBuilder
    private func chapterRow(_ chapter: ChapterEntry, in book: LibraryStorageBook) -> some View {
        if let bytes = chapter.bytes {
            Button {
                if isSelecting { toggle(chapter.index) }
                else { open(chapter.index) }
            } label: {
                cachedChapterRow(chapter, bytes: bytes)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(chapter.index) ? .isSelected : [])
            .swipeActions(allowsFullSwipe: false) {
                if book.isOnline, !isSelecting {
                    Button("删除缓存", role: .destructive) {
                        alert = .confirm(.chapters(book, indices: [chapter.index], title: chapter.title))
                    }
                    .disabled(operationInProgress)
                }
            }
            .disabled(operationInProgress)
        } else {
            HStack(spacing: 12) {
                chapterLabel(chapter)
                Spacer(minLength: 8)
                if downloadingIndex == chapter.index {
                    ProgressView()
                    Button("取消") { downloadJob?.cancel() }.buttonStyle(.borderless)
                } else if isSelecting {
                    Text("未缓存").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("下载", systemImage: "arrow.down.circle") { download(chapter.index) }
                        .buttonStyle(.borderless)
                        .disabled(operationInProgress)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cachedChapterRow(_ chapter: ChapterEntry, bytes: Int64) -> some View {
        HStack(spacing: 12) {
            if isSelecting { selectionMark(selection.contains(chapter.index)) }
            chapterLabel(chapter)
            Spacer(minLength: 8)
            if openingIndex == chapter.index {
                ProgressView()
            } else {
                Text(storageSize(bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if !isSelecting {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func chapterLabel(_ chapter: ChapterEntry) -> some View {
        HStack(spacing: 12) {
            Text((chapter.index + 1).formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 30, alignment: .leading)
                .accessibilityLabel("第 \(chapter.index + 1) 章")
            Text(chapter.title).foregroundStyle(.primary)
        }
    }

    private func emptyText(_ isOnline: Bool) -> String {
        guard isOnline else { return "暂无本地章节" }
        switch filter {
        case .all: return "暂无章节"
        case .cached: return "暂无已缓存章节"
        case .uncached: return "所有章节均已缓存"
        }
    }

    private func endSelection() {
        isSelecting = false
        selection.removeAll()
    }

    private func toggle(_ index: Int) {
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
    }

    private func toggleVisible() {
        if visibleIndices.isSubset(of: selection) { selection.subtract(visibleIndices) }
        else { selection.formUnion(visibleIndices) }
    }

    private func confirmSelected() {
        guard let current, !selectedIndices.isEmpty else { return }
        alert = .confirm(.chapters(current, indices: selectedIndices, title: nil))
    }

    private func open(_ index: Int) {
        guard !operationInProgress else { return }
        guard let book = currentBook, book.chapters.indices.contains(index) else {
            alert = .error("无法打开章节", "书籍已移除或已换源。")
            return
        }
        openingIndex = index
        Task {
            defer { openingIndex = nil }
            do {
                guard try await library.cachedChapter(in: book, at: index) != nil else {
                    await inventory.refresh(library)
                    alert = .error("无法打开章节", "找不到这章的正文文件。")
                    return
                }
                guard currentBook?.readerIdentity == book.readerIdentity else {
                    alert = .error("无法打开章节", "书籍已移除或已换源。")
                    return
                }
                openCachedChapter(book, index)
            } catch {
                alert = .error("无法打开章节", error.localizedDescription)
            }
        }
    }

    private func download(_ index: Int) {
        guard !operationInProgress else { return }
        guard let book = currentBook, book.chapters.indices.contains(index) else {
            alert = .error("无法下载章节", "书籍已移除或已换源。")
            return
        }
        downloadingIndex = index
        downloadJob = Task {
            defer {
                downloadingIndex = nil
                downloadJob = nil
            }
            do {
                try await library.downloadChapter(in: book, at: index)
                await inventory.refresh(library)
            } catch {
                guard !Task.isCancelled else { return }
                alert = .error("无法下载章节", error.localizedDescription)
            }
        }
    }

    private func performDeletion(_ deletion: LibraryStorageDeletion) {
        guard !operationInProgress else { return }
        Task {
            do {
                guard let removal = try await inventory.remove(deletion, in: library) else { return }
                endSelection()
                alert = .removed(removal)
            } catch {
                alert = .error("无法删除缓存", error.localizedDescription)
            }
        }
    }

    private struct ChapterEntry: Identifiable {
        let index: Int
        let title: String
        let bytes: Int64?
        var id: Int { index }
    }

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", cached = "已缓存", uncached = "未缓存"
        var id: Self { self }
    }
}

@MainActor
private final class LibraryStorageInventory: ObservableObject {
    @Published private(set) var snapshot: LibraryStorageSnapshot?
    @Published private(set) var isBusy = false
    @Published private(set) var scanError: String?

    func refresh(_ library: LibraryStore) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await measure(library)
    }

    func remove(_ deletion: LibraryStorageDeletion, in library: LibraryStore) async throws -> LibraryCacheRemoval? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let removal: LibraryCacheRemoval
            switch deletion.scope {
            case .books(let items):
                removal = try await library.removeChapterCaches(in: items)
            case .chapters(let item, let indices):
                removal = try await library.removeChapterCache(bookID: item.id, revision: item.revision, indices: indices)
            }
            await measure(library)
            return removal
        } catch {
            await measure(library)
            throw error
        }
    }

    private func measure(_ library: LibraryStore) async {
        do {
            let report = try await library.storageSnapshot()
            guard !Task.isCancelled else { return }
            snapshot = report
            scanError = nil
        } catch {
            guard !Task.isCancelled else { return }
            scanError = error.localizedDescription
        }
    }
}

private struct LibraryStorageDeletion {
    enum Scope {
        case books([LibraryStorageBook])
        case chapters(LibraryStorageBook, Set<Int>)
    }

    let title: String
    let message: String
    let scope: Scope

    static func book(_ item: LibraryStorageBook) -> Self {
        Self(title: "删除《\(item.title)》的缓存？",
             message: "将删除本书已下载的在线章节，包括旧版本缓存。", scope: .books([item]))
    }

    static func books(_ items: [LibraryStorageBook], all: Bool) -> Self {
        Self(title: all ? "删除全部在线缓存？" : "删除所选 \(items.count) 本书的缓存？",
             message: "将删除这些书已下载的在线章节，包括旧版本缓存。", scope: .books(items))
    }

    static func chapters(_ item: LibraryStorageBook, indices: Set<Int>, title: String?) -> Self {
        Self(title: title.map { "删除「\($0)」的缓存？" } ?? "删除所选 \(indices.count) 章的缓存？",
             message: "将删除所选章节已下载的在线正文。", scope: .chapters(item, indices))
    }
}

private enum LibraryStorageAlert: Identifiable {
    case confirm(LibraryStorageDeletion)
    case removed(LibraryCacheRemoval)
    case error(String, String)

    var id: Int {
        switch self {
        case .confirm: 2
        case .removed: 0
        case .error: 1
        }
    }

    func alert(delete: @escaping (LibraryStorageDeletion) -> Void) -> Alert {
        switch self {
        case .confirm(let prompt):
            Alert(title: Text(prompt.title), message: Text(prompt.message),
                  primaryButton: .destructive(Text("删除")) { delete(prompt) },
                  secondaryButton: .cancel(Text("取消")))
        case .removed(let removal):
            if removal.fileCount == 0 {
                Alert(title: Text("没有需要删除的缓存"), dismissButton: .default(Text("好")))
            } else {
                Alert(title: Text("缓存已删除"),
                      message: Text("已删除 \(removal.fileCount) 个缓存文件，文件大小合计 \(storageSize(removal.bytes))。"),
                      dismissButton: .default(Text("好")))
            }
        case .error(let title, let message):
            Alert(title: Text(title), message: Text(message), dismissButton: .default(Text("好")))
        }
    }
}

private struct LibraryStorageSelectionBar: View {
    let count: Int
    let unit: String
    let hasVisibleItems: Bool
    let allVisibleSelected: Bool
    let selectVisible: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(allVisibleSelected ? "取消选择当前结果" : "全选当前结果", action: selectVisible)
                .disabled(!hasVisibleItems)
            Spacer()
            Text("已选 \(count) \(unit)").foregroundStyle(.secondary)
            Button("删除所选", role: .destructive, action: remove)
                .disabled(count == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(.bar)
    }
}

private func selectionMark(_ selected: Bool) -> some View {
    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(selected ? ReaderPalette.accent : .secondary)
        .accessibilityHidden(true)
}

private func storageSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
