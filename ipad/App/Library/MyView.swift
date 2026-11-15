import BookSources
import SwiftUI
import UniformTypeIdentifiers

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "亮色"
        case .dark: "暗色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct MyView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("app.appearanceMode") private var appearanceMode: AppAppearanceMode = .system
    @State private var query = ""
    @State private var readerSettings: MyReaderSettingsSheet.Kind?

    let showSources: () -> Void
    let showSubscriptions: () -> Void
    let importBooks: () -> Void
    let importSources: () -> Void
    let openBook: (LibraryBook) -> Void
    let openBookmark: (LibraryBook, ReaderPosition) -> Void

    var body: some View {
        let sections = visibleSections
        Group {
            if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in menuRow(item) }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
        .searchable(text: $query, prompt: "查找设置与工具")
        .sheet(item: $readerSettings) { kind in
            MyReaderSettingsSheet(kind: kind)
        }
    }

    @ViewBuilder
    private func menuRow(_ item: Item) -> some View {
        switch item.action {
        case .sources: Button(action: showSources) { label(item) }
        case .subscriptions: Button(action: showSubscriptions) { label(item) }
        case .importBooks: Button(action: importBooks) { label(item) }
        case .replacements:
            NavigationLink { MyReplacementBooksView() } label: { label(item) }
        case .appAppearance:
            Picker(selection: $appearanceMode) {
                ForEach(AppAppearanceMode.allCases) { mode in Text(mode.title).tag(mode) }
            } label: { label(item) }
            .pickerStyle(.menu)
        case .readerAppearance: Button { readerSettings = .appearance } label: { label(item) }
        case .readerBehavior: Button { readerSettings = .behavior } label: { label(item) }
        case .ai:
            NavigationLink { ReaderAISettingsView() } label: { label(item) }
        case .backup:
            NavigationLink {
                MySourceBackupView(sources: library.sources, importSources: importSources)
            } label: { label(item) }
        case .storage:
            NavigationLink { MyStorageView() } label: { label(item) }
        case .bookmarks:
            NavigationLink { MyBookmarksView(open: openBookmark) } label: { label(item) }
        case .history:
            NavigationLink { MyReadingRecordsView(open: openBook) } label: { label(item) }
        case .about:
            NavigationLink { MyAboutView() } label: { label(item) }
        }
    }

    private func label(_ item: Item) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ReaderPalette.accent)
                .frame(width: 34, height: 34)
                .background(ReaderPalette.accent.opacity(colorScheme == .dark ? 0.23 : 0.10), in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var visibleSections: [MenuSection] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return Self.sections }
        return Self.sections.compactMap { section in
            if section.title.localizedStandardContains(term) { return section }
            let results = section.items.filter {
                $0.title.localizedStandardContains(term) || $0.subtitle?.localizedStandardContains(term) == true
            }
            return results.isEmpty ? nil : MenuSection(title: section.title, items: results)
        }
    }

    private struct MenuSection: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    private struct Item: Identifiable {
        let action: Action
        let title: String
        let icon: String
        let subtitle: String?
        var id: Action { action }

        init(_ action: Action, _ title: String, _ icon: String, _ subtitle: String? = nil) {
            self.action = action
            self.title = title
            self.icon = icon
            self.subtitle = subtitle
        }
    }

    private enum Action {
        case sources, subscriptions, importBooks, replacements, appAppearance, readerAppearance, readerBehavior, ai
        case backup, storage, bookmarks, history, about
    }

    private static let sections = [
        MenuSection(title: "内容与规则", items: [
            Item(.sources, "书源管理", "text.badge.checkmark", "新建、导入或编辑书源"),
            Item(.subscriptions, "订阅源管理", "dot.radiowaves.left.and.right", "书源广场、规则订阅与 RSS"),
            Item(.replacements, "替换净化", "arrow.left.arrow.right", "按书籍管理正文替换规则"),
            Item(.importBooks, "导入本地书籍", "doc.badge.plus", "从文件打开 TXT 或 EPUB")
        ]),
        MenuSection(title: "外观与 AI", items: [
            Item(.appAppearance, "主题模式", "circle.lefthalf.filled"),
            Item(.readerAppearance, "阅读外观", "textformat.size", "字体、排版、翻页与阅读主题"),
            Item(.ai, "AI 设置", "sparkles")
        ]),
        MenuSection(title: "备份与存储", items: [
            Item(.backup, "书源备份", "square.and.arrow.up.on.square", "导出或恢复阅读书源 JSON"),
            Item(.storage, "存储用量", "internaldrive", "本地书籍和在线章节占用空间")
        ]),
        MenuSection(title: "工具与关于", items: [
            Item(.readerBehavior, "阅读设置", "slider.horizontal.3", "屏幕、手势和自动阅读"),
            Item(.bookmarks, "书签", "bookmark", "打开已收藏的阅读位置"),
            Item(.history, "阅读记录", "clock", "继续上次的阅读进度"),
            Item(.about, "关于阅读", "info.circle")
        ])
    ]
}

private struct MySourceBackupView: View {
    let sources: [BookSource]
    let importSources: () -> Void

    @State private var exportDocument: MySourceBackup?
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button("导出 \(sources.count) 个书源", systemImage: "square.and.arrow.up", action: beginExport)
                    .disabled(sources.isEmpty)
                Button("从文件导入书源", systemImage: "square.and.arrow.down", action: importSources)
            } footer: {
                Text("导出的 JSON 可以用阅读应用重新导入。它包含书源设置，书架、进度和订阅地址存放在本机。")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("书源备份")
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "阅读书源备份"
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                errorMessage = error.localizedDescription
            }
        }
        .alert("无法导出书源", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func beginExport() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            exportDocument = MySourceBackup(data: try encoder.encode(sources))
            isExporting = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MySourceBackup: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
