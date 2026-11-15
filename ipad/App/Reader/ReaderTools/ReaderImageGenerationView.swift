import SwiftUI

struct ReaderImageGenerationView: View {
    let context: ReaderImageContext

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gallery = ReaderImageGalleryStore.shared
    @State private var settings = ReaderAISettings()
    @State private var providerID: String?
    @State private var prompt: String
    @State private var activeOperation: Operation?
    @State private var operation: Task<Void, Never>?
    @State private var resultID: UUID?
    @State private var showsGallery = false
    @State private var errorMessage: String?

    init(context: ReaderImageContext) {
        self.context = context
        _prompt = State(initialValue: context.sourceText)
    }

    private var result: ReaderImageGalleryEntry? { gallery.entries.first { $0.id == resultID } }
    private var providers: [ReaderAIImageProvider] { settings.enabled ? settings.enabledImageProviders : [] }
    private var provider: ReaderAIImageProvider? { providers.first { $0.id == providerID } }
    private var cleanPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                configuration
                Section("图片提示词") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 108)
                        .accessibilityLabel("可编辑的图片提示词")
                        .disabled(activeOperation != nil)
                }
                actions
                if let result { generatedPicture(result) }
            }
            .navigationTitle("选中文本生图")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("AI 图库", systemImage: "photo.on.rectangle") { showsGallery = true }
                        .disabled(activeOperation != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear(perform: refreshSettings)
            .sheet(isPresented: $showsGallery) {
                NavigationStack {
                    ReaderImageGalleryView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showsGallery = false }
                            }
                        }
                }
            }
        }
        .onDisappear { operation?.cancel() }
        .alert("阅读生图", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var configuration: some View {
        Section("图像模型") {
            if !providers.isEmpty {
                Picker("模型", selection: $providerID) {
                    ForEach(providers) { provider in
                        let model = provider.resolvedModelName
                        let title = provider.title == model ? model : "\(provider.title) · \(model)"
                        Text(title).tag(Optional(provider.id))
                    }
                }
                .disabled(activeOperation != nil)
            }
            NavigationLink("配置 AI 服务") { ReaderAISettingsView() }
                .disabled(activeOperation != nil)
            if !settings.enabled {
                Text("AI 已关闭。").foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        Section {
            if let activeOperation {
                ProgressView(activeOperation.label)
                if activeOperation != .insert {
                    Button("取消请求", role: .cancel) { operation?.cancel() }
                }
            } else {
                Button(result == nil ? "生成图片" : "重新生成", systemImage: "sparkles", action: generate)
                    .disabled(provider == nil || cleanPrompt.isEmpty)
                if settings.enabled, settings.defaultQuestionChoice != nil {
                    Button("优化提示词", systemImage: "wand.and.stars", action: optimize)
                        .disabled(cleanPrompt.isEmpty)
                }
            }
        } footer: {
            if let provider {
                Text("生成图片会将提示词发送给 \(provider.title)。优化提示词会使用当前书名、章节和选中文字。")
            }
        }
    }

    private func generatedPicture(_ entry: ReaderImageGalleryEntry) -> some View {
        Section {
            ReaderGalleryPicture(url: gallery.fileURL(for: entry), maxDimension: 1800)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            if context.canInsert {
                Button(entry.isInserted ? "已插入正文" : "插入正文", systemImage: entry.isInserted ? "checkmark" : "text.badge.plus") {
                    run(.insert) {
                        try await gallery.setInserted(true, for: entry.id)
                        dismiss()
                    }
                }
                .disabled(activeOperation != nil || entry.isInserted)
            }
            Button(entry.isFavorite ? "取消收藏" : "收藏到图库", systemImage: entry.isFavorite ? "heart.slash" : "heart") {
                Task {
                    do { try await gallery.setFavorite(!entry.isFavorite, for: entry.id) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            .disabled(activeOperation != nil)
            ShareLink(item: gallery.fileURL(for: entry)) {
                Label("分享或保存", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("生成结果")
        } footer: {
            if !entry.isFavorite && !entry.isInserted {
                Text("图片会暂存三天，收藏后保留。")
            }
        }
    }

    private func refreshSettings() {
        do {
            settings = try ReaderAISettings.load()
            if provider == nil {
                providerID = settings.defaultImageProvider?.id ?? providers.first?.id
            }
        } catch {
            settings = ReaderAISettings()
            providerID = nil
            errorMessage = error.localizedDescription
        }
    }

    private func generate() {
        refreshSettings()
        let text = cleanPrompt
        guard let provider, !text.isEmpty else { return }
        run(.generate) {
            let data = try await ReaderAIClient.generateImage(prompt: text, provider: provider)
            try Task.checkCancellation()
            let entry = try await gallery.store(
                data, prompt: text, provider: provider.title, model: provider.resolvedModelName, context: context
            )
            resultID = entry.id
        }
    }

    private func optimize() {
        refreshSettings()
        let text = cleanPrompt
        guard settings.enabled, let endpoint = settings.defaultQuestionChoice, !text.isEmpty else { return }
        run(.rewrite) {
            let details = """
            书名：\(context.bookTitle)
            作者：\(context.author)
            章节：\(context.chapterTitle)
            当前段落：\(String((context.paragraphText ?? context.sourceText).prefix(1200)))
            读者提示词：\(text)
            """
            let response = try await ReaderAIClient.chat(messages: [
                ReaderAIChatMessage(role: .system, content: """
                你是小说插画提示词编辑。根据读者提示词和选中文字提炼人物、场景、氛围、服饰、构图和画风，不编造情节。书名和章节等出处仅供理解。只输出最终提示词。
                """),
                ReaderAIChatMessage(role: .user, content: details)
            ], using: endpoint)
            try Task.checkCancellation()
            let rewritten = Self.cleanedResponse(response)
            guard !rewritten.isEmpty else { throw ReaderAIError.emptyResponse }
            prompt = rewritten
        }
    }

    private func run(_ kind: Operation, action: @escaping @MainActor () async throws -> Void) {
        guard activeOperation == nil else { return }
        errorMessage = nil
        activeOperation = kind
        operation = Task {
            defer {
                operation = nil
                activeOperation = nil
            }
            do { try await action() }
            catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private static func cleanedResponse(_ result: String) -> String {
        var text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), let lineEnd = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: lineEnd)...].dropLast(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (text.hasPrefix("“") && text.hasSuffix("”")) ||
            (text.hasPrefix("\"") && text.hasSuffix("\"")) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private enum Operation {
        case generate, rewrite, insert
        var label: String {
            switch self {
            case .generate: "正在生成图片"
            case .rewrite: "正在优化提示词"
            case .insert: "正在插入正文"
            }
        }
    }
}
