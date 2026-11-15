import BookSources
import SwiftUI

@MainActor
struct ChapterDownloadView: View {
    let library: LibraryStore
    let book: LibraryBook
    let startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var first: String
    @State private var last: String
    @State private var job: Task<Void, Never>?
    @State private var numberDownloaded = 0
    @State private var numberFailed = 0
    @State private var total = 0
    @State private var currentTitle = ""
    @State private var lastError: String?
    @State private var wasCancelled = false

    init(library: LibraryStore, book: LibraryBook, startIndex: Int) {
        self.library = library
        self.book = book
        self.startIndex = min(max(0, startIndex), max(0, book.chapters.count - 1))
        let start = self.startIndex + 1
        _first = State(initialValue: String(start))
        _last = State(initialValue: String(min(book.chapters.count, start + 9)))
    }

    private var range: ClosedRange<Int>? {
        guard let start = chapterNumber(first), let end = chapterNumber(last),
              start >= 1, start <= end, end <= book.chapters.count else { return nil }
        return (start - 1)...(end - 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    chapterField("起始章", value: $first)
                    chapterField("结束章", value: $last)
                    HStack {
                        Button("当前章") { selectNext(1) }
                        Spacer()
                        Button("从当前章起 10 章") { selectNext(10) }
                        Spacer()
                        Button("从当前章起 50 章") { selectNext(50) }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("章节范围")
                } footer: {
                    if let range {
                        Text("第 \(range.lowerBound + 1)–\(range.upperBound + 1) 章，共 \(range.count) 章")
                    } else {
                        Text("请输入 1 至 \(book.chapters.count) 范围内的章节序号，结束章不能早于起始章。")
                    }
                }
                .disabled(job != nil)

                if total > 0 {
                    Section("下载进度") {
                        ProgressView(value: Double(numberDownloaded + numberFailed), total: Double(total)) {
                            Text("已缓存 \(numberDownloaded) / \(total) 章")
                        }
                        if job != nil, !currentTitle.isEmpty {
                            Text(currentTitle).foregroundStyle(.secondary)
                        } else if wasCancelled {
                            Text("下载已停止，已缓存章节可离线阅读。")
                        } else if numberDownloaded == total {
                            Text("已可离线阅读所选章节。")
                        }
                        if numberFailed > 0 {
                            Text("\(numberFailed) 章下载失败。\(lastError ?? "")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    if let job {
                        Button("停止下载", role: .cancel) { job.cancel() }
                    } else {
                        Button("下载所选章节") { startDownload() }
                            .disabled(range == nil)
                    }
                }
            }
            .navigationTitle("下载章节")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(job != nil)
                }
            }
        }
        .interactiveDismissDisabled(job != nil)
        .onDisappear { job?.cancel() }
    }

    private func chapterField(_ label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("章节序号", text: value)
                .accessibilityLabel(label)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
        }
    }

    private func chapterNumber(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping)
    }

    private func selectNext(_ count: Int) {
        first = String(startIndex + 1)
        last = String(min(book.chapters.count, startIndex + count))
    }

    private func startDownload() {
        guard job == nil, let range else { return }
        total = range.count
        numberDownloaded = 0
        numberFailed = 0
        lastError = nil
        wasCancelled = false
        job = Task { await download(range) }
    }

    private func download(_ range: ClosedRange<Int>) async {
        defer {
            wasCancelled = Task.isCancelled
            currentTitle = ""
            job = nil
        }
        for index in range {
            guard !Task.isCancelled else { break }
            currentTitle = library.displayTitle(book.chapters[index].title, sourceID: book.sourceID)
            do {
                try await library.downloadChapter(in: book, at: index)
                numberDownloaded += 1
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { break }
                numberFailed += 1
                lastError = error.localizedDescription
                if let libraryError = error as? LibraryError {
                    switch libraryError {
                    case .missingSource, .bookUnavailable:
                        return
                    default:
                        break
                    }
                }
            }
        }
    }
}

@MainActor
struct SwitchBookSourceView: View {
    let library: LibraryStore
    let book: LibraryBook
    let chapterIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var matches: [Match] = []
    @State private var failures: [Failure] = []
    @State private var sourceCount = 0
    @State private var finished = 0
    @State private var isSearching = true
    @State private var searchAttempt = 0
    @State private var selection: Match?
    @State private var switchTask: Task<Void, Never>?
    @State private var switchError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("当前书源") {
                    LabeledContent(library.displayTitle(book.title, sourceID: book.sourceID), value: library.sourceName(for: book))
                }
                if isSearching {
                    Section {
                        ProgressView("正在搜索 \(finished) / \(sourceCount) 个书源…")
                    }
                } else if matches.isEmpty {
                    Section {
                        Text(sourceCount == 0 ? "暂无其他启用的文本书源。" : "其他书源未返回可选版本。")
                            .foregroundStyle(.secondary)
                        if sourceCount > 0 {
                            Button("重新搜索") { searchAttempt += 1 }
                        }
                    }
                }
                if !matches.isEmpty {
                    Section {
                        ForEach(matches) { match in
                            Button { selection = match } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(library.displayTitle(match.book.title, sourceID: match.book.sourceID)).font(.headline)
                                    Text([match.book.author, match.sourceName].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(switchTask != nil)
                        }
                    } header: {
                        Text("选择新书源")
                    } footer: {
                        Text("换源会按章名定位。缺少同名章节时，会打开新书源中最接近的章序。每个书源分别保留书签和下载。")
                    }
                }
                if !failures.isEmpty {
                    Section {
                        DisclosureGroup("\(failures.count) 个书源搜索失败") {
                            ForEach(failures) { failure in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(failure.name)
                                    Text(failure.message).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if switchTask != nil {
                    Section {
                        ProgressView("正在验证目录和当前章节…")
                    }
                }
            }
            .navigationTitle("更换书源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(switchTask == nil ? "关闭" : "取消换源") {
                        if let switchTask {
                            switchTask.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .task(id: searchAttempt) { await search() }
            .confirmationDialog("切换到这个书源？", isPresented: Binding(
                get: { selection != nil },
                set: { if !$0 { selection = nil } }
            ), titleVisibility: .visible, presenting: selection) { match in
                Button("使用「\(match.sourceName)」") { switchTo(match) }
            } message: { match in
                let title = library.displayTitle(match.book.title, sourceID: match.book.sourceID)
                Text([title, match.book.author].filter { !$0.isEmpty }.joined(separator: " · "))
            }
            .alert("无法更换书源", isPresented: Binding(
                get: { switchError != nil },
                set: { if !$0 { switchError = nil } }
            )) {
                Button("好", role: .cancel) { switchError = nil }
            } message: {
                Text(switchError ?? "")
            }
        }
        .interactiveDismissDisabled(switchTask != nil)
        .onDisappear { switchTask?.cancel() }
    }

    private func search() async {
        let alternatives = library.sources.filter { $0.isEnabled && $0.canSearch && $0.id != book.sourceID }
        let title = book.title
        let author = book.author
        let client = library.client
        sourceCount = alternatives.count
        finished = 0
        matches = []
        failures = []
        isSearching = !alternatives.isEmpty
        await withTaskGroup(of: Outcome.self) { tasks in
            var remaining = alternatives.makeIterator()
            for _ in 0..<min(5, alternatives.count) {
                if let source = remaining.next() {
                    tasks.addTask { await Self.search(source, title: title, author: author, client: client) }
                }
            }
            for await outcome in tasks {
                guard !Task.isCancelled else {
                    tasks.cancelAll()
                    return
                }
                switch outcome {
                case .success(let values):
                    matches.append(contentsOf: values)
                    matches.sort {
                        if $0.score != $1.score { return $0.score > $1.score }
                        if $0.sourceName != $1.sourceName { return $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending }
                        return $0.book.title.localizedStandardCompare($1.book.title) == .orderedAscending
                    }
                case .failed(let failure):
                    failures.append(failure)
                }
                finished += 1
                if let source = remaining.next() {
                    tasks.addTask { await Self.search(source, title: title, author: author, client: client) }
                }
            }
        }
        if !Task.isCancelled { isSearching = false }
    }

    nonisolated private static func search(_ source: BookSource, title: String, author: String, client: BookSourceClient) async -> Outcome {
        do {
            let expectedTitle = normalizedChapterTitle(title)
            let expectedAuthor = normalizedChapterTitle(author)
            var results = try await client.search(title, in: source)
            if !expectedAuthor.isEmpty, expectedTitle != expectedAuthor,
               !results.contains(where: { normalizedChapterTitle($0.title) == expectedTitle }),
               let authorResults = try? await client.search(author, in: source) {
                var ids = Set(results.map(\.id))
                results += authorResults.filter { ids.insert($0.id).inserted }
            }
            let matches = results.map { book in
                let title = normalizedChapterTitle(book.title)
                let author = normalizedChapterTitle(book.author)
                let titleScore = title == expectedTitle ? 4 : !expectedTitle.isEmpty && title.contains(expectedTitle) ? 2 : 0
                let authorScore = expectedAuthor.isEmpty ? 0 : author == expectedAuthor ? 2 : author.contains(expectedAuthor) ? 1 : 0
                return Match(book: book, sourceName: source.name, score: titleScore + authorScore)
            }
            return .success(matches.sorted { $0.score > $1.score })
        } catch {
            return .failed(Failure(id: source.id, name: source.name, message: error.localizedDescription))
        }
    }

    private func switchTo(_ selected: Match) {
        guard switchTask == nil else { return }
        selection = nil
        switchTask = Task {
            defer { switchTask = nil }
            do {
                _ = try await library.switchSource(for: book, to: selected.book, at: chapterIndex)
                dismiss()
            } catch {
                if !Task.isCancelled { switchError = error.localizedDescription }
            }
        }
    }

    private struct Match: Identifiable, Sendable {
        let book: SourceBook
        let sourceName: String
        let score: Int
        var id: String { book.id }
    }

    private struct Failure: Identifiable, Sendable {
        let id: String
        let name: String
        let message: String
    }

    private enum Outcome: Sendable {
        case success([Match])
        case failed(Failure)
    }
}
