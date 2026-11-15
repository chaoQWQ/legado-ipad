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
    let cachedChapter: (Int) async throws -> String?
    let online: ReaderOnlineActions?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.theme") private var theme: ReaderTheme = .system
    @AppStorage("reader.lastLightTheme") private var lastLightTheme: ReaderTheme = .system
    @AppStorage("reader.font") private var font: ReaderFont = .serif
    @AppStorage("reader.fontSize") private var fontSize = 23.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 8.0
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = 8.0
    @AppStorage("reader.indentParagraphs") private var indentParagraphs = false
    @AppStorage("reader.columnWidth") private var columnWidth: ReaderColumnWidth = .standard
    @AppStorage("reader.automaticSpeed") private var automaticSpeed = 36.0
    @AppStorage private var bookmarkData: Data
    @AppStorage private var replacementData: Data
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0

    @StateObject private var speech = ReaderSpeechController()
    @State private var chapterIndex: Int
    @State private var offset: Int
    @State private var content: ChapterContent?
    @State private var scrollRequest: ReaderScrollRequest?
    @State private var highlight: SearchHighlight?
    @State private var automaticScroll = false
    @State private var showsTray = true
    @State private var errorMessage: String?
    @State private var attempt = 0
    @State private var refreshRequest: RefreshRequest?
    @State private var refreshError: String?
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
        onProgress: @escaping (ReaderPosition) -> Void,
        cachedChapter: @escaping (Int) async throws -> String? = { _ in nil },
        online: ReaderOnlineActions? = nil,
        bookmarkKey: String? = nil
    ) {
        self.title = title
        self.author = author
        self.chapters = chapters
        self.loadChapter = loadChapter
        self.onProgress = onProgress
        self.cachedChapter = cachedChapter
        self.online = online
        self._bookmarkData = AppStorage(wrappedValue: Data(), bookmarkKey ?? ReaderBookmarks.key(for: bookID))
        self._replacementData = AppStorage(wrappedValue: Data(), ReaderReplacementRule.storageKey(bookID: bookID))
        let validIndex = min(max(0, initialPosition.chapterIndex), max(0, chapters.count - 1))
        self._chapterIndex = State(initialValue: validIndex)
        self._offset = State(initialValue: validIndex == initialPosition.chapterIndex ? max(0, initialPosition.offset) : 0)
    }

    private var palette: ReadingPalette { theme.palette(for: colorScheme) }
    private var bookmarks: [ReaderBookmark] { ReaderBookmarks.decode(bookmarkData) }
    private var position: ReaderPosition { ReaderPosition(chapterIndex: chapterIndex, offset: offset) }
    private var hasBookmark: Bool { bookmarks.contains { $0.position == position } }
    private var hasBody: Bool { content?.transform.text.isEmpty == false }
    private var scrollFraction: Double {
        guard let content, content.index == chapterIndex, content.textLength > 0 else { return 0 }
        // Progress and resume use the same UTF-16 offset in the original chapter.
        return Double(offset) / Double(content.textLength)
    }
    private var isNight: Bool { palette == .night }
    private var chapterTitle: String {
        chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : ""
    }

    var body: some View {
        let request = ChapterRequest(index: chapterIndex, attempt: attempt)
        let refresh = refreshRequest
        readerPage
            .foregroundStyle(palette.foreground)
            .tint(palette.accent)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(title)
            .toolbar { readerToolbar }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.panel, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
            #endif
            .sheet(item: $activeSheet) { sheet in
                sheetContent(sheet)
                    .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
            }
            .task(id: request) {
                await openChapter(for: request, startingAt: offset)
            }
            .task(id: refresh) {
                if let refresh { await refreshChapter(for: refresh) }
            }
            .onChange(of: replacementData) { _, _ in applyReplacements() }
            .onChange(of: theme) { _, newTheme in
                if newTheme != .night { lastLightTheme = newTheme }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    automaticScroll = false
                    saveProgress()
                }
            }
            .onDisappear {
                automaticScroll = false
                speech.stop()
                saveProgress()
            }
            .alert("无法刷新章节", isPresented: Binding(
                get: { refreshError != nil },
                set: { if !$0 { refreshError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(refreshError ?? "")
            }
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if online != nil {
                Button {
                    present(.changeSource)
                } label: {
                    Label("换源", systemImage: "shuffle")
                }
                .disabled(chapters.isEmpty)

                Button(action: beginRefresh) {
                    Label("刷新本章", systemImage: "arrow.clockwise")
                }
                .disabled(chapters.isEmpty || refreshRequest != nil)

                Button {
                    present(.download)
                } label: {
                    Label("下载章节", systemImage: "arrow.down.to.line")
                }
                .disabled(chapters.isEmpty)
            }

            Menu {
                Button(action: toggleBookmark) {
                    Label(
                        hasBookmark ? "移除当前书签" : "添加书签",
                        systemImage: hasBookmark ? "bookmark.fill" : "bookmark"
                    )
                }
                .disabled(content?.text.isEmpty != false)

                Button {
                    showsTray.toggle()
                } label: {
                    Label(showsTray ? "隐藏阅读工具" : "显示阅读工具", systemImage: "slider.horizontal.3")
                }
            } label: {
                Label("更多阅读操作", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
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
        case .search:
            ReaderSearchSheet(chapters: chapters, loadChapter: { index in
                if let content, content.index == index { return content.text }
                return try await cachedChapter(index)
            }, jumpTo: { match in
                activeSheet = nil
                openPosition(
                    ReaderPosition(chapterIndex: match.chapterIndex, offset: match.utf16Offset),
                    highlight: SearchHighlight(
                        chapterIndex: match.chapterIndex,
                        range: NSRange(location: match.utf16Offset, length: match.utf16Length)
                    )
                )
            })
        case .replace:
            ReaderReplaceSheet(rules: Binding(
                get: { ReaderReplacementRule.decode(replacementData) },
                set: { if let data = ReaderReplacementRule.encode($0) { replacementData = data } }
            ))
        case .appearance, .settings:
            ReaderSettingsView(
                kind: sheet == .appearance ? .appearance : .layout,
                theme: $theme,
                font: $font,
                fontSize: $fontSize,
                lineSpacing: $lineSpacing,
                paragraphSpacing: $paragraphSpacing,
                indentParagraphs: $indentParagraphs,
                columnWidth: $columnWidth,
                automaticSpeed: $automaticSpeed
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
        case .download:
            online?.download(chapterIndex)
        case .changeSource:
            online?.changeSource(chapterIndex)
        }
    }

    private var readerPage: some View {
        Group {
            if chapters.isEmpty {
                ContentUnavailableView("暂无章节", systemImage: "book.closed")
            } else if let content, content.index == chapterIndex {
                if content.transform.text.isEmpty {
                    ContentUnavailableView("本章暂无正文", systemImage: "doc.text")
                } else {
                    let request = scrollRequest
                    ReaderTextPane(
                        text: content.transform.text,
                        typography: ReaderTypography(
                            fontSize: fontSize * textScale,
                            lineSpacing: lineSpacing * textScale,
                            font: font,
                            palette: palette,
                            paragraphSpacing: paragraphSpacing * textScale,
                            indentParagraphs: indentParagraphs
                        ),
                        initialOffset: content.transform.displayOffset(forOriginal: offset),
                        request: request,
                        highlight: displayHighlight(in: content),
                        automaticSpeed: automaticScroll ? automaticSpeed : nil,
                        onScroll: { displayOffset in
                            if scrollRequest == request { updateScroll(displayOffset, in: content) }
                        },
                        onAutomaticEnd: {
                            if self.content?.id == content.id { finishAutomaticScroll() }
                        }
                    )
                    .frame(maxWidth: columnWidth.maxWidth)
                    .id(content.id)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if !chapters.isEmpty { chapterHeader }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !chapters.isEmpty, showsTray || automaticScroll || speech.state != .idle {
                controlsPanel
            }
        }
    }

    private var chapterHeader: some View {
        HStack(spacing: 12) {
            Text(chapterTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if refreshRequest != nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在刷新章节")
            }
            if let online {
                Text(online.sourceName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.accent.opacity(0.12), in: Capsule())
                    .accessibilityLabel("书源：\(online.sourceName)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background(palette.panel)
    }

    private var controlsPanel: some View {
        VStack(spacing: 0) {
            if showsTray {
                chapterControls
                Divider()
                toolTray
            }
            if automaticScroll {
                HStack(spacing: 12) {
                    Button("暂停自动滚动", systemImage: "pause.fill", action: finishAutomaticScroll)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                    Slider(value: $automaticSpeed, in: 12...110, step: 1) {
                        Text("自动滚动速度")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise")
                    } maximumValueLabel: {
                        Image(systemName: "hare")
                    }
                }
                .frame(maxWidth: 580)
                .padding(.horizontal, 16)
            }
            if speech.state != .idle {
                HStack(spacing: 16) {
                    Label(speech.state == .paused ? "朗读已暂停" : "正在朗读", systemImage: "headphones")
                        .font(.footnote)
                    Button(action: toggleSpeech) {
                        Label(
                            speech.state == .paused ? "继续朗读" : "暂停朗读",
                            systemImage: speech.state == .paused ? "play.fill" : "pause.fill"
                        )
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    Button("停止朗读", systemImage: "stop.fill") { speech.stop() }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .background(palette.panel, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
    }

    private var chapterControls: some View {
        HStack(spacing: 10) {
            Button {
                selectChapter(chapterIndex - 1)
            } label: {
                Label("上一章", systemImage: "backward.end")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(chapterIndex == 0)
            .keyboardShortcut(.leftArrow)

            chapterStepButton(-0.1, title: "后退百分之十", icon: "minus")

            Slider(value: Binding(
                get: { scrollFraction },
                set: { seek(to: $0) }
            ), in: 0...1) {
                Text("章内进度")
            }
            .disabled(!hasBody)
            .accessibilityValue(scrollFraction.formatted(.percent.precision(.fractionLength(0))))

            chapterStepButton(0.1, title: "前进百分之十", icon: "plus")

            Text(scrollFraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 42)
                .accessibilityHidden(true)

            Button {
                selectChapter(chapterIndex + 1)
            } label: {
                Label("下一章", systemImage: "forward.end")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(chapterIndex + 1 >= chapters.count)
            .keyboardShortcut(.rightArrow)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
    }

    private func chapterStepButton(_ step: Double, title: String, icon: String) -> some View {
        Button {
            let displayedFraction = (scrollFraction * 100).rounded() / 100
            seek(to: displayedFraction + step)
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!hasBody || (step < 0 ? scrollFraction == 0 : scrollFraction == 1))
    }

    private var toolTray: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                primaryTools
                secondaryTools
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) { primaryTools }
                HStack(spacing: 0) { secondaryTools }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var primaryTools: some View {
        toolButton("搜索", icon: "magnifyingglass") { present(.search) }
            .disabled(chapters.isEmpty)
        toolButton(automaticScroll ? "暂停" : "自动", icon: automaticScroll ? "pause.circle" : "play.rectangle") {
            if automaticScroll {
                finishAutomaticScroll()
            } else {
                speech.stop()
                automaticScroll = true
            }
        }
        .accessibilityLabel(automaticScroll ? "暂停自动滚动" : "开始自动滚动")
        .disabled(!hasBody)
        toolButton("替换", icon: "arrow.left.arrow.right") { present(.replace) }
        toolButton(isNight ? "日间" : "夜间", icon: isNight ? "sun.max" : "moon", action: toggleNight)
    }

    @ViewBuilder
    private var secondaryTools: some View {
        toolButton("目录", icon: "list.bullet") { present(.chapters) }
            .disabled(chapters.isEmpty)
        toolButton("朗读", icon: "headphones", action: toggleSpeech)
            .disabled(!hasBody)
        toolButton("界面", icon: "textformat.size") { present(.appearance) }
        toolButton("设置", icon: "gearshape") { present(.settings) }
    }

    private func toolButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.body)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(minWidth: 56, maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }

    private func present(_ sheet: Sheet) {
        finishAutomaticScroll()
        activeSheet = sheet
    }

    private func toggleNight() {
        if isNight {
            let fallback = lastLightTheme == .night ? .day : lastLightTheme
            theme = fallback == .system && colorScheme == .dark ? .day : fallback
        } else {
            lastLightTheme = theme
            theme = .night
        }
    }

    private func toggleSpeech() {
        switch speech.state {
        case .playing: speech.pause()
        case .paused: speech.resume()
        case .idle:
            guard let content else { return }
            finishAutomaticScroll()
            let current = offset == content.textLength ? 0 : content.transform.displayOffset(forOriginal: offset)
            speech.start(text: content.transform.text, utf16Offset: current) { spokenOffset in
                guard self.content?.id == content.id else { return }
                scrollRequest = ReaderScrollRequest(target: .reveal(spokenOffset))
            }
        }
    }

    private func finishAutomaticScroll() {
        automaticScroll = false
        saveProgress()
    }

    private func seek(to fraction: Double) {
        guard let content, hasBody else { return }
        speech.stop()
        if automaticScroll { finishAutomaticScroll() }
        highlight = nil
        let targetOffset = Int((min(1, max(0, fraction)) * Double(content.textLength)).rounded())
        scrollRequest = ReaderScrollRequest(target: .offset(content.transform.displayOffset(forOriginal: targetOffset)))
        updateReadingOffset(targetOffset)
    }

    private func selectChapter(_ index: Int) {
        guard index != chapterIndex else { return }
        openPosition(ReaderPosition(chapterIndex: index))
    }

    private func openPosition(_ position: ReaderPosition, highlight: SearchHighlight? = nil) {
        let index = position.chapterIndex
        guard chapters.indices.contains(index) else { return }
        speech.stop()
        finishAutomaticScroll()
        self.highlight = highlight
        errorMessage = nil
        if let content, content.index == index {
            offset = min(max(0, position.offset), content.textLength)
            scrollRequest = ReaderScrollRequest(target: .offset(content.transform.displayOffset(forOriginal: offset)))
            saveProgress()
            return
        }

        offset = position.offset
        content = nil
        refreshRequest = nil
        scrollRequest = nil
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
            guard request == ChapterRequest(index: chapterIndex, attempt: attempt), content?.index != index else { return }
            setContent(text, at: index, offset: requestedOffset)
        } catch {
            guard !Task.isCancelled, request == ChapterRequest(index: chapterIndex, attempt: attempt),
                  content?.index != index else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func beginRefresh() {
        guard online != nil, chapters.indices.contains(chapterIndex), refreshRequest == nil else { return }
        finishAutomaticScroll()
        refreshRequest = RefreshRequest(index: chapterIndex)
    }

    @MainActor
    private func refreshChapter(for request: RefreshRequest) async {
        guard let online else { return }
        defer { if refreshRequest == request { refreshRequest = nil } }
        do {
            let text = try await online.refreshChapter(request.index)
            try Task.checkCancellation()
            guard refreshRequest == request, request.index == chapterIndex else { return }
            speech.stop()
            highlight = nil
            errorMessage = nil
            setContent(text, at: request.index, offset: offset)
        } catch {
            guard !Task.isCancelled, refreshRequest == request else { return }
            refreshError = error.localizedDescription
        }
    }

    private func setContent(_ text: String, at index: Int, offset requestedOffset: Int) {
        let textLength = text.utf16.count
        offset = min(max(0, requestedOffset), textLength)
        scrollRequest = nil
        content = ChapterContent(
            index: index,
            text: text,
            textLength: textLength,
            transform: ReaderTextTransform(original: text, rules: ReaderReplacementRule.decode(replacementData))
        )
        saveProgress()
    }

    private func applyReplacements() {
        guard let content else { return }
        speech.stop()
        finishAutomaticScroll()
        setContent(content.text, at: content.index, offset: offset)
    }

    private func displayHighlight(in content: ChapterContent) -> NSRange? {
        guard let highlight, highlight.chapterIndex == content.index,
              highlight.range.location >= 0, NSMaxRange(highlight.range) <= content.textLength else {
            return nil
        }
        let start = content.transform.displayOffset(forOriginal: highlight.range.location)
        let end = content.transform.displayOffset(forOriginal: NSMaxRange(highlight.range))
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    private func updateScroll(_ displayOffset: Int, in content: ChapterContent) {
        guard self.content?.id == content.id else { return }
        let originalOffset = content.transform.originalOffset(forDisplay: displayOffset)
        updateReadingOffset(originalOffset)
    }

    private func updateReadingOffset(_ newOffset: Int) {
        guard newOffset != offset else { return }
        offset = newOffset
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
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
        let id = UUID()
        let index: Int
        let text: String
        let textLength: Int
        let transform: ReaderTextTransform
    }

    private struct ChapterRequest: Equatable {
        let index: Int
        let attempt: Int
    }

    private struct RefreshRequest: Equatable {
        let id = UUID()
        let index: Int
    }

    private struct SearchHighlight {
        let chapterIndex: Int
        let range: NSRange
    }

    private enum Sheet: String, Identifiable {
        case chapters
        case settings
        case appearance
        case search
        case replace
        case download
        case changeSource

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
