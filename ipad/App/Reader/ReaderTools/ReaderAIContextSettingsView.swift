import SwiftUI
import UniformTypeIdentifiers

struct ReaderAIWorldBookSettingsView: View {
    var bindingsOnly = false
    @State private var books: [ReaderAIWorldBook] = []
    @State private var editing: ReaderAIWorldBook?
    @State private var deletion: ReaderAIWorldBook?
    @State private var imports = false
    @State private var exports = false
    @State private var export: WorldBookDocument?
    @State private var exportName = "世界书"
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        List {
            if let message { Text(message).foregroundStyle(.secondary) }
            if books.isEmpty {
                ContentUnavailableView("暂无世界书", systemImage: "books.vertical")
            }
            ForEach(books) { book in
                Section {
                    if bindingsOnly {
                        Toggle(isOn: binding(book, target: .readAI)) {
                            bookLabel(book)
                        }
                        .disabled(!book.enabled)
                    } else {
                        Button {
                            editing = book
                        } label: {
                            bookLabel(book)
                        }
                        .buttonStyle(.plain)
                        Toggle("全局使用", isOn: binding(book, target: .global))
                            .disabled(!book.enabled)
                        Toggle("正文问 AI", isOn: binding(book, target: .readAI))
                            .disabled(!book.enabled)
                    }
                }
                .contextMenu {
                    if !bindingsOnly {
                        Button("导出 JSON", systemImage: "square.and.arrow.up") { exportBook(book) }
                        Button("删除", systemImage: "trash", role: .destructive) { deletion = book }
                    }
                }
            }
            if bindingsOnly {
                NavigationLink("管理世界书") { ReaderAIWorldBookSettingsView() }
            }
        }
        .navigationTitle(bindingsOnly ? "当前窗口世界书" : "世界书管理")
        .toolbar {
            if !bindingsOnly {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("新建世界书", systemImage: "plus") { editing = .init() }
                        Button("导入 JSON 或 config.xml", systemImage: "square.and.arrow.down") { imports = true }
                    } label: { Label("添加世界书", systemImage: "plus") }
                }
            }
        }
        .task { await reload() }
        .sheet(item: $editing) { book in
            NavigationStack {
                ReaderAIWorldBookEditor(book: book) { saved in
                    perform { try await ReaderAIWorldBookStore.shared.save(saved) }
                }
            }
        }
        .fileImporter(isPresented: $imports, allowedContentTypes: [.json, .xml]) { result in
            perform {
                let count = try await ReaderAIWorldBookStore.shared.importBooks(from: result.get())
                message = "已导入 \(count) 本世界书。"
            }
        }
        .fileExporter(isPresented: $exports, document: export, contentType: .json, defaultFilename: exportName) { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .confirmationDialog("删除世界书？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { book in
            Button("删除「\(book.name)」", role: .destructive) { perform { try await ReaderAIWorldBookStore.shared.remove(book.id) } }
        }
        .readerAISettingsError($error)
    }

    private func bookLabel(_ book: ReaderAIWorldBook) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.name)
            let details = [book.enabled ? "\(book.entries.count) 条" : "已停用", book.description]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            Text(details).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func binding(_ book: ReaderAIWorldBook, target: ReaderAIWorldBook.Binding) -> Binding<Bool> {
        Binding(get: { books.first(where: { $0.id == book.id })?.isBound(to: target) == true }, set: { enabled in
            perform { try await ReaderAIWorldBookStore.shared.bind(target, to: book.id, enabled: enabled) }
        })
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                await reload()
            } catch let failure { error = failure.localizedDescription }
        }
    }

    private func reload() async {
        do { books = try await ReaderAIWorldBookStore.shared.books() }
        catch let failure { error = failure.localizedDescription }
    }

    private func exportBook(_ book: ReaderAIWorldBook) {
        do {
            export = try WorldBookDocument(book)
            exportName = book.name
            exports = true
        } catch let failure { error = failure.localizedDescription }
    }
}

private struct ReaderAIWorldBookEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var book: ReaderAIWorldBook
    let onSave: (ReaderAIWorldBook) -> Void

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $book.name)
                TextField("说明", text: $book.description, axis: .vertical)
                Toggle("启用", isOn: $book.enabled)
                Stepper(value: $book.maxEntries, in: 1...40) {
                    LabeledContent("每次最多注入", value: "\(book.maxEntries) 条")
                }
            }
            Section("条目") {
                ForEach($book.entries) { entry in
                    NavigationLink {
                        ReaderAIWorldBookEntryEditor(entry: entry)
                    } label: {
                        LabeledContent(entry.wrappedValue.name.isEmpty ? "新条目" : entry.wrappedValue.name,
                                       value: entry.wrappedValue.enabled ? "\(entry.wrappedValue.priority)" : "已停用")
                    }
                }
                .onDelete { book.entries.remove(atOffsets: $0) }
                Button("添加条目", systemImage: "plus") { book.entries.append(.init(order: book.entries.count)) }
            }
        }
        .navigationTitle("编辑世界书")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    book.name = book.name.aiTrimmed
                    book.description = book.description.aiTrimmed
                    book.entries = book.entries.enumerated().map { index, original in
                        var entry = original
                        entry.name = entry.name.aiTrimmed
                        entry.content = String(entry.content.aiTrimmed.prefix(8_000))
                        entry.order = index
                        return entry
                    }
                    onSave(book)
                    dismiss()
                }
                .disabled(book.name.aiTrimmed.isEmpty || book.entries.contains { $0.name.aiTrimmed.isEmpty || $0.content.aiTrimmed.isEmpty })
            }
        }
    }
}

private struct ReaderAIWorldBookEntryEditor: View {
    @Binding var entry: ReaderAIWorldBook.Entry

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $entry.name)
                TextField("内容", text: $entry.content, axis: .vertical).lineLimit(3...10)
                Toggle("启用", isOn: $entry.enabled)
                Toggle("常驻注入", isOn: $entry.constantActive)
            }
            Section {
                TextField("主要关键词", text: keys($entry.keywords), axis: .vertical)
                TextField("次要关键词", text: keys($entry.secondaryKeys), axis: .vertical)
                TextField("排除关键词", text: keys($entry.excludeKeys), axis: .vertical)
                Toggle("正则匹配", isOn: $entry.useRegex)
                Toggle("区分大小写", isOn: $entry.caseSensitive)
            } footer: {
                Text("每行一个关键词。")
            }
            Section("注入规则") {
                Picker("位置", selection: $entry.position) {
                    ForEach(ReaderAIWorldBook.Entry.Position.allCases) { Text($0.title).tag($0) }
                }
                if entry.position == .injectDepth {
                    Stepper(value: $entry.injectDepth, in: 0...64) { LabeledContent("注入深度", value: "\(entry.injectDepth)") }
                }
                Picker("消息角色", selection: $entry.role) {
                    Text("系统").tag(ReaderAIChatMessage.Role.system)
                    Text("用户").tag(ReaderAIChatMessage.Role.user)
                    Text("助手").tag(ReaderAIChatMessage.Role.assistant)
                }
                Stepper(value: $entry.priority, in: 0...100) { LabeledContent("优先级", value: "\(entry.priority)") }
                Stepper(value: $entry.scanDepth, in: 1...64) { LabeledContent("扫描消息数", value: "\(entry.scanDepth)") }
                Stepper(value: $entry.maxMatches, in: 1...20) { LabeledContent("最多匹配词数", value: "\(entry.maxMatches)") }
            }
        }
        .navigationTitle("世界书条目")
    }

    private func keys(_ values: Binding<[String]>) -> Binding<String> {
        Binding(get: { values.wrappedValue.joined(separator: "\n") }, set: { draft in
            values.wrappedValue = Array(draft.components(separatedBy: .newlines).prefix(40))
        })
    }
}

private struct WorldBookDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(_ book: ReaderAIWorldBook) throws {
        struct Export: Encodable {
            let version: Int
            let type = "lorebook"
            let data: ReaderAIWorldBook
        }
        var book = book
        book.bindings = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        data = try encoder.encode(Export(version: book.version, data: book))
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ReaderAIMemorySettingsView: View {
    @State private var entries: [ReaderAIMemoryStore.Entry] = []
    @State private var imports = false
    @State private var deletion: ReaderAIMemoryStore.Entry?
    @State private var error: String?
    @State private var importSummary: String?

    var body: some View {
        List {
            if let importSummary { Text(importSummary).foregroundStyle(.secondary) }
            if entries.isEmpty {
                ContentUnavailableView("暂无长期记忆", systemImage: "brain")
            }
            ForEach(entries) { entry in
                NavigationLink {
                    ScrollView {
                        Text(entry.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    .navigationTitle(entry.title.isEmpty ? "长期记忆" : entry.title)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title.isEmpty ? "长期记忆" : entry.title)
                        Text(entry.content).font(.footnote).lineLimit(2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("删除", systemImage: "trash", role: .destructive) { deletion = entry }
                }
            }
            Section {
                Button("导入记忆记录 JSON", systemImage: "square.and.arrow.down") { imports = true }
            } footer: {
                Text("支持从安卓记忆数据表单独导出的 JSON。安卓常规备份不含长期记忆。")
            }
        }
        .navigationTitle("AI 长期记忆")
        .task { await reload() }
        .fileImporter(isPresented: $imports, allowedContentTypes: [.json]) { result in
            perform {
                let count = try await ReaderAIMemoryStore.shared.importRecords(from: result.get())
                importSummary = "已导入 \(count) 条记忆。"
            }
        }
        .confirmationDialog("删除这条记忆？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { entry in
            Button("删除记忆", role: .destructive) { perform { try await ReaderAIMemoryStore.shared.remove(id: entry.id) } }
        }
        .readerAISettingsError($error)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
                await reload()
            } catch let failure { error = failure.localizedDescription }
        }
    }

    private func reload() async {
        do { entries = try await ReaderAIMemoryStore.shared.entries().sorted { $0.updatedAt > $1.updatedAt } }
        catch let failure { error = failure.localizedDescription }
    }
}
