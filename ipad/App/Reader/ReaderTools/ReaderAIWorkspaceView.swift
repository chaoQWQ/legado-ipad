import BookSources
import SwiftUI
import UniformTypeIdentifiers

struct ReaderAIWorkspaceView: View {
    @State private var conversations: [ReaderAIWorkspace.Conversation]?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView {
                    Label("无法访问 AI 工作区", systemImage: "folder.badge.questionmark")
                } actions: {
                    Button("重试") { Task { await reload() } }
                }
            } else if let conversations {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "暂无会话文件", systemImage: "folder",
                        description: Text("AI 在对话中创建的工作区文件会显示在这里。")
                    )
                } else {
                    List(conversations) { conversation in
                        NavigationLink {
                            ReaderAIWorkspaceFolder(conversationID: conversation.id, path: "")
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("会话 \(conversation.id.uuidString.prefix(8))", systemImage: "folder")
                                Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .refreshable { await reload() }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("AI 工作区")
        .task { await reload() }
    }

    private func reload() async {
        do {
            conversations = try await ReaderAIWorkspace.shared.conversations()
            failed = false
        } catch {
            failed = true
        }
    }
}

private struct ReaderAIWorkspaceFolder: View {
    let conversationID: UUID
    let path: String

    @State private var files: [ReaderAIWorkspace.Entry] = []
    @State private var nextOffset: Int?
    @State private var loaded = false
    @State private var importsFile = false
    @State private var importing = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if loaded && files.isEmpty {
                ContentUnavailableView("文件夹为空", systemImage: "folder")
                    .listRowBackground(Color.clear)
            }
            ForEach(files) { entry in
                NavigationLink { destination(for: entry) } label: { row(for: entry) }
            }
            if let nextOffset {
                Button("加载更多") { Task { await load(offset: nextOffset) } }
            }
        }
        .overlay {
            if !loaded || importing { ProgressView() }
        }
        .navigationTitle(path.isEmpty ? "会话文件" : (path as NSString).lastPathComponent)
        .toolbar {
            if path.isEmpty {
                ToolbarItemGroup(placement: .primaryAction) {
                    NavigationLink {
                        ReaderAIWorkspaceBackups(conversationID: conversationID)
                    } label: {
                        Label("备份", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        importsFile = true
                    } label: {
                        Label("添加文件", systemImage: "plus")
                    }
                    .disabled(importing)
                }
            }
        }
        .task { await load(offset: 0) }
        .refreshable { await load(offset: 0) }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.plainText, .html, .json], onCompletion: importFile)
        .readerAISettingsError($errorMessage)
    }

    @ViewBuilder
    private func destination(for entry: ReaderAIWorkspace.Entry) -> some View {
        if entry.isDirectory {
            AnyView(ReaderAIWorkspaceFolder(conversationID: conversationID, path: entry.path))
        } else {
            ReaderAIWorkspaceFile(conversationID: conversationID, entry: entry)
        }
    }

    private func row(for entry: ReaderAIWorkspace.Entry) -> some View {
        HStack {
            Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc.text")
            if !entry.isDirectory {
                Spacer()
                Text(Int64(entry.size), format: .byteCount(style: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func importFile(_ result: Result<URL, any Error>) {
        guard case let .success(url) = result else {
            errorMessage = "无法打开所选文件。"
            return
        }
        importing = true
        Task {
            defer { importing = false }
            do {
                try await ReaderAIWorkspace.shared.importInput(from: url, for: conversationID)
                await load(offset: 0)
            } catch {
                errorMessage = "无法导入此文件。请选择最大 1 MB 的 UTF-8 文本、HTML 或 JSON 文件。"
            }
        }
    }

    private func load(offset: Int) async {
        do {
            let page = try await ReaderAIWorkspace.shared.files(for: conversationID, path: path, offset: offset)
            if offset == 0 {
                files = page.files
            } else if self.nextOffset == offset {
                files += page.files
            }
            nextOffset = page.nextOffset
        } catch {
            errorMessage = "无法读取此工作区文件夹。"
        }
        loaded = true
    }
}

private struct ReaderAIWorkspaceFile: View {
    let conversationID: UUID
    let entry: ReaderAIWorkspace.Entry

    @EnvironmentObject private var library: LibraryStore
    @State private var content: String?
    @State private var sources: [BookSource] = []
    @State private var showsExport = false
    @State private var confirmsImport = false
    @State private var importing = false
    @State private var importedCount: Int?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let content {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: String(content.prefix(24_000)))
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        if content.utf16.count > 24_000 {
                            Text("预览可能只显示文件开头，可导出完整文件。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if errorMessage == nil {
                ProgressView()
            } else {
                ContentUnavailableView("无法读取文件", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle(entry.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !sources.isEmpty {
                    Button("导入书源") { confirmsImport = true }
                        .disabled(importing)
                }
                Button {
                    showsExport = true
                } label: {
                    Label("导出文件", systemImage: "square.and.arrow.up")
                }
                .disabled(content == nil)
            }
        }
        .task {
            do {
                let text = try await ReaderAIWorkspace.shared.document(for: conversationID, path: entry.path)
                content = text
                if (entry.name as NSString).pathExtension.lowercased() == "json" {
                    sources = (try? BookSourceImport.decode(Data(text.utf8))) ?? []
                }
            } catch {
                errorMessage = "无法读取此工作区文件。"
            }
        }
        .fileExporter(
            isPresented: $showsExport, document: content.map { WorkspaceExportDocument(data: Data($0.utf8)) },
            contentType: UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .plainText,
            defaultFilename: entry.name
        ) { result in
            if case .failure = result { errorMessage = "无法导出此文件。" }
        }
        .alert("导入 \(sources.count) 个书源？", isPresented: $confirmsImport) {
            Button("取消", role: .cancel) {}
            Button("导入", action: startImport)
        } message: {
            let names = sources.prefix(4).map(\.name).joined(separator: "、")
            let existing = Set(library.sources.map(\.id))
            let replacements = sources.filter { existing.contains($0.id) }.count
            if replacements > 0 {
                Text("\(names)\n将更新 \(replacements) 个地址相同的书源。")
            } else {
                Text(verbatim: names)
            }
        }
        .alert("已导入 \(importedCount ?? 0) 个书源", isPresented: Binding(
            get: { importedCount != nil }, set: { if !$0 { importedCount = nil } }
        )) {
            Button("好", role: .cancel) {}
        }
        .readerAISettingsError($errorMessage)
    }

    private func startImport() {
        guard let content, !sources.isEmpty, !importing else { return }
        importing = true
        Task {
            defer { importing = false }
            let manager = FileManager.default
            let folder = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { try? manager.removeItem(at: folder) }
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: false)
                let input = folder.appending(path: "book-sources.json", directoryHint: .notDirectory)
                try Data(content.utf8).write(to: input, options: .atomic)
                importedCount = try await library.importSources(from: input)
            } catch {
                errorMessage = "无法导入此文件中的书源。"
            }
        }
    }
}

private struct ReaderAIWorkspaceBackups: View {
    let conversationID: UUID

    @State private var backups: [ReaderAIWorkspace.Backup]?
    @State private var pending: ReaderAIWorkspace.Backup?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let backups {
                if backups.isEmpty {
                    ContentUnavailableView("没有备份", systemImage: "clock.arrow.circlepath")
                } else {
                    List(backups) { backup in
                        Button {
                            pending = backup
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: backup.path)
                                Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .refreshable { await reload() }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("工作区备份")
        .task { await reload() }
        .alert("还原工作区文件？", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), presenting: pending) { backup in
            Button("取消", role: .cancel) {}
            Button("还原") {
                Task {
                    do {
                        try await ReaderAIWorkspace.shared.restore(backup, for: conversationID)
                        await reload()
                    } catch {
                        errorMessage = "无法还原工作区备份。"
                    }
                }
            }
        } message: { backup in
            Text("还原「\(backup.path)」。若当前文件存在，将先保存另一个备份。")
        }
        .readerAISettingsError($errorMessage)
    }

    private func reload() async {
        do {
            backups = try await ReaderAIWorkspace.shared.backups(for: conversationID)
        } catch {
            backups = []
            errorMessage = "无法读取工作区备份。"
        }
    }
}

private struct WorkspaceExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
