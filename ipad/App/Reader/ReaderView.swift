import SwiftUI

struct ReaderChapter {
    let title: String
}

struct ReaderPosition: Codable, Equatable {
    var chapterIndex: Int = 0
    var offset: Int = 0
}

struct ReaderView: View {
    let title: String
    let author: String
    let chapters: [ReaderChapter]
    let loadChapter: (Int) async throws -> String
    let onProgress: (ReaderPosition) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.theme") private var theme: ReaderTheme = .system
    @AppStorage("reader.font") private var font: ReaderFont = .serif
    @AppStorage("reader.fontSize") private var fontSize = 23.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage private var bookmarkData: Data
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0

    @State private var chapterIndex: Int
    @State private var offset: Int
    @State private var content: ChapterContent?
    @State private var textGeneration = 0
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var activeSheet: Sheet?
    @State private var saveTask: Task<Void, Never>?
    @State private var savedPosition: ReaderPosition?

    init(
        bookID: UUID,
        title: String,
        author: String,
        chapters: [ReaderChapter],
        initialPosition: ReaderPosition = .init(),
        loadChapter: @escaping (Int) async throws -> String,
        onProgress: @escaping (ReaderPosition) -> Void
    ) {
        self.title = title
        self.author = author
        self.chapters = chapters
        self.loadChapter = loadChapter
        self.onProgress = onProgress
        self._bookmarkData = AppStorage(wrappedValue: Data(), ReaderBookmarks.key(for: bookID))
        let validIndex = min(max(0, initialPosition.chapterIndex), max(0, chapters.count - 1))
        self._chapterIndex = State(initialValue: validIndex)
        self._offset = State(initialValue: validIndex == initialPosition.chapterIndex ? max(0, initialPosition.offset) : 0)
    }

    private var palette: ReadingPalette { theme.palette(for: colorScheme) }
    private var bookmarks: [ReaderBookmark] { ReaderBookmarks.decode(bookmarkData) }
    private var position: ReaderPosition { ReaderPosition(chapterIndex: chapterIndex, offset: offset) }
    private var hasBookmark: Bool { bookmarks.contains { $0.position == position } }

    private var navigationTitle: String {
        chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : title
    }

    var body: some View {
        let request = ChapterRequest(index: chapterIndex, attempt: attempt)
        readerPage
            .foregroundStyle(palette.foreground)
            .tint(palette.accent)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        activeSheet = .chapters
                    } label: {
                        Label("目录", systemImage: "list.bullet")
                    }
                    .disabled(chapters.isEmpty)

                    Button(action: toggleBookmark) {
                        Label(
                            hasBookmark ? "移除当前书签" : "添加书签",
                            systemImage: hasBookmark ? "bookmark.fill" : "bookmark"
                        )
                    }
                    .disabled(content?.text.isEmpty != false)

                    Button {
                        activeSheet = .settings
                    } label: {
                        Label("阅读设置", systemImage: "textformat.size")
                    }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            #endif
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .chapters:
                    ReaderContentsView(
                        title: title,
                        author: author,
                        chapters: chapters,
                        selected: chapterIndex,
                        bookmarks: bookmarks.filter { chapters.indices.contains($0.position.chapterIndex) },
                        selectChapter: selectChapter,
                        openBookmark: { openPosition($0.position) },
                        deleteBookmarks: deleteBookmarks
                    )
                    .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
                case .settings:
                    ReaderSettingsView(theme: $theme, font: $font, fontSize: $fontSize, lineSpacing: $lineSpacing)
                        .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
                        #if os(iOS)
                        .presentationDetents([.medium, .large])
                        #endif
                }
            }
            .task(id: request) {
                await openChapter(for: request, startingAt: offset)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { saveProgress() }
            }
            .onDisappear(perform: saveProgress)
    }

    private var readerPage: some View {
        Group {
            if chapters.isEmpty {
                ContentUnavailableView("暂无章节", systemImage: "book.closed")
            } else if let content, content.index == chapterIndex {
                if content.text.isEmpty {
                    ContentUnavailableView("本章暂无正文", systemImage: "doc.text")
                } else {
                    ReaderTextPane(
                        text: content.text,
                        typography: ReaderTypography(
                            fontSize: fontSize * textScale,
                            lineSpacing: lineSpacing * textScale,
                            font: font,
                            palette: palette
                        ),
                        initialOffset: content.firstOffset
                    ) { visibleOffset in
                        updateOffset(visibleOffset, forChapterAt: content.index)
                    }
                    .frame(maxWidth: 800)
                    .id(textGeneration)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("章节加载失败", systemImage: "exclamationmark.circle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") {
                        self.errorMessage = nil
                        attempt += 1
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ProgressView("正在加载章节")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !chapters.isEmpty {
                chapterControls
            }
        }
    }

    private var chapterControls: some View {
        VStack(spacing: 0) {
            ProgressView(value: Double(chapterIndex + 1), total: Double(chapters.count))
                .progressViewStyle(.linear)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                Button {
                    selectChapter(chapterIndex - 1)
                } label: {
                    Label("上一章", systemImage: "chevron.left")
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(chapterIndex == 0)
                .keyboardShortcut(.leftArrow)

                Spacer(minLength: 0)
                Text("\(chapterIndex + 1) / \(chapters.count)")
                    .font(.footnote.monospacedDigit())
                    .accessibilityLabel("第 \(chapterIndex + 1) 章，共 \(chapters.count) 章")
                Spacer(minLength: 0)

                Button {
                    selectChapter(chapterIndex + 1)
                } label: {
                    HStack(spacing: 6) {
                        Text("下一章")
                        Image(systemName: "chevron.right")
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("下一章")
                }
                .disabled(chapterIndex + 1 >= chapters.count)
                .keyboardShortcut(.rightArrow)
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
        .background(palette.background)
    }

    private func selectChapter(_ index: Int) {
        guard index != chapterIndex else { return }
        openPosition(ReaderPosition(chapterIndex: index))
    }

    private func openPosition(_ position: ReaderPosition) {
        let index = position.chapterIndex
        guard chapters.indices.contains(index) else { return }
        saveProgress()
        errorMessage = nil
        if let content, content.index == index {
            offset = clampedOffset(position.offset, in: content.text)
            self.content = ChapterContent(index: index, text: content.text, firstOffset: offset)
            textGeneration += 1
            saveProgress()
            return
        }
        offset = position.offset
        content = nil
        if index == chapterIndex { attempt += 1 }
        chapterIndex = index
    }

    @MainActor
    private func openChapter(for request: ChapterRequest, startingAt requestedOffset: Int) async {
        let index = request.index
        guard chapters.indices.contains(index), content?.index != index else { return }
        errorMessage = nil
        do {
            let text = try await loadChapter(index)
            try Task.checkCancellation()
            guard request == ChapterRequest(index: chapterIndex, attempt: attempt) else { return }

            let firstOffset = clampedOffset(requestedOffset, in: text)
            offset = firstOffset
            content = ChapterContent(index: index, text: text, firstOffset: firstOffset)
            textGeneration += 1
            saveProgress()
        } catch {
            guard !Task.isCancelled, request == ChapterRequest(index: chapterIndex, attempt: attempt) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func clampedOffset(_ offset: Int, in text: String) -> Int {
        min(max(0, offset), max(0, text.utf16.count - 1))
    }

    private func updateOffset(_ visibleOffset: Int, forChapterAt index: Int) {
        guard index == chapterIndex, visibleOffset != offset else { return }
        offset = visibleOffset
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            saveProgress()
        }
    }

    private func saveProgress() {
        saveTask?.cancel()
        saveTask = nil
        guard content?.index == chapterIndex else { return }
        guard savedPosition != position else { return }
        savedPosition = position
        onProgress(position)
    }

    private func toggleBookmark() {
        guard let content, !content.text.isEmpty else { return }
        var updated = bookmarks
        if let index = updated.firstIndex(where: { $0.position == position }) {
            updated.remove(at: index)
        } else {
            updated.insert(ReaderBookmark(position: position, text: content.text), at: 0)
        }
        bookmarkData = ReaderBookmarks.encode(updated)
    }

    private func deleteBookmarks(_ ids: Set<UUID>) {
        bookmarkData = ReaderBookmarks.encode(bookmarks.filter { !ids.contains($0.id) })
    }

    private struct ChapterContent {
        let index: Int
        let text: String
        let firstOffset: Int
    }

    private struct ChapterRequest: Equatable {
        let index: Int
        let attempt: Int
    }

    private enum Sheet: String, Identifiable {
        case chapters
        case settings

        var id: Self { self }
    }
}

private struct ReaderContentsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var tab: Tab = .chapters
    let title: String
    let author: String
    let chapters: [ReaderChapter]
    let selected: Int
    let bookmarks: [ReaderBookmark]
    let selectChapter: (Int) -> Void
    let openBookmark: (ReaderBookmark) -> Void
    let deleteBookmarks: (Set<UUID>) -> Void

    private var visibleChapters: [Int] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return Array(chapters.indices) }
        return chapters.indices.filter { chapters[$0].title.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .chapters: chapterList
                case .bookmarks: bookmarkList
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("阅读导航", selection: $tab) {
                    Text("目录").tag(Tab.chapters)
                    Text("书签").tag(Tab.bookmarks)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle(tab == .chapters ? "目录" : "书签")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(visibleChapters, id: \.self) { index in
                        Button {
                            selectChapter(index)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(chapters[index].title)
                                Spacer()
                                if index == selected {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(index == selected ? .isSelected : [])
                        .id(index)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                        if !author.isEmpty {
                            Text(author)
                        }
                    }
                }
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .overlay {
                if visibleChapters.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: "查找章节")
    }

    private var bookmarkList: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView {
                    Label("暂无书签", systemImage: "bookmark")
                } description: {
                    Text("在阅读工具栏添加书签。")
                }
            } else {
                List {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            openBookmark(bookmark)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chapters[bookmark.position.chapterIndex].title)
                                Text("本章 \(bookmark.fraction, format: .percent.precision(.fractionLength(0)))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if !bookmark.excerpt.isEmpty {
                                    Text(bookmark.excerpt)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("删除书签", systemImage: "trash", role: .destructive) {
                                deleteBookmarks([bookmark.id])
                            }
                        }
                    }
                    .onDelete { offsets in
                        deleteBookmarks(Set(offsets.map { bookmarks[$0].id }))
                    }
                }
            }
        }
    }

    private enum Tab { case chapters, bookmarks }
}
