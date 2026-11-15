import SwiftUI

struct ReaderImageGenerationView: View {
    let context: ReaderImageContext

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gallery = ReaderImageGalleryStore.shared
    @State private var settings = ReaderAISettings()
    @State private var prompt: String
    @State private var activeOperation: Operation?
    @State private var operation: Task<Void, Never>?
    @State private var resultID: UUID?
    @State private var resultPreview: CGImage?
    @State private var showsGallery = false
    @State private var errorMessage: String?
    @State private var attemptedInitialGeneration = false

    init(context: ReaderImageContext) {
        self.context = context
        let selection = context.sourceText.aiTrimmed
        _prompt = State(initialValue: selection.isEmpty ? context.paragraphText?.aiTrimmed ?? "" : selection)
    }

    private var result: ReaderImageGalleryEntry? { gallery.entries.first { $0.id == resultID } }
    private var provider: ReaderAIImageProvider? { settings.enabled ? settings.defaultImageProvider : nil }
    private var cleanPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if result != nil {
                    Section("生成结果") {
                        if let resultPreview {
                            Image(resultPreview, scale: 1, label: Text("生成的图片"))
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        } else {
                            Label("无法预览图片", systemImage: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                configuration
                Section("图片提示词") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 108)
                        .accessibilityLabel("可编辑的图片提示词")
                        .disabled(activeOperation != nil)
                }
                actions
                if let result { resultActions(result) }
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
            .onAppear {
                refreshSettings()
                guard !attemptedInitialGeneration else { return }
                attemptedInitialGeneration = true
                generate()
            }
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
    }

    private var configuration: some View {
        Section("图像模型") {
            if let provider {
                let model = provider.resolvedModelName
                let title = provider.title == model ? model : "\(provider.title) · \(model)"
                LabeledContent("模型", value: title)
            }
            NavigationLink("配置 AI 服务") { ReaderAISettingsView() }
                .disabled(activeOperation != nil)
            if !settings.enabled {
                Text("AI 已关闭。").foregroundStyle(.secondary)
            } else if provider == nil {
                Text("请先配置生图供应商。").foregroundStyle(.secondary)
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
                Button(result == nil ? "生成图片" : "重新生成", systemImage: "sparkles") {
                    refreshSettings()
                    generate()
                }
                    .disabled(provider == nil || cleanPrompt.isEmpty)
                if settings.enabled, settings.defaultChatChoice != nil {
                    Button("优化提示词", systemImage: "wand.and.stars", action: optimize)
                        .disabled(cleanPrompt.isEmpty)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        } footer: {
            if let provider {
                Text("\(provider.title) 会收到提示词和供应商设置的画风。优化提示词会使用当前段落和书籍资料。")
            }
        }
    }

    private func resultActions(_ entry: ReaderImageGalleryEntry) -> some View {
        Section {
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
        } footer: {
            if !entry.isFavorite && !entry.isInserted {
                Text("图片会暂存三天，收藏后保留。")
            }
        }
    }

    private func refreshSettings() {
        do {
            settings = try ReaderAISettings.load()
        } catch {
            settings = ReaderAISettings()
            errorMessage = error.localizedDescription
        }
    }

    private func generate() {
        let text = cleanPrompt
        guard let provider, !text.isEmpty else { return }
        run(.generate) {
            resultID = nil
            resultPreview = nil
            let data = try await ReaderAIClient.generateImage(prompt: text, provider: provider)
            try Task.checkCancellation()
            let entry = try await gallery.store(
                data, prompt: text, provider: provider.title, model: provider.resolvedModelName, context: context
            )
            let url = gallery.fileURL(for: entry)
            let preview = await Task.detached(priority: .userInitiated) {
                ReaderGalleryPicture.thumbnail(at: url, maxDimension: 1_200)
            }.value
            try Task.checkCancellation()
            resultPreview = preview
            resultID = entry.id
        }
    }

    private func optimize() {
        refreshSettings()
        let text = cleanPrompt
        guard settings.enabled, let endpoint = settings.defaultChatChoice, !text.isEmpty else { return }
        run(.rewrite) {
            let characters: [ReaderBookCharacter]
            if let bookID = context.bookID {
                characters = try await ReaderBookCharacterStore.shared.characters(for: bookID)
            } else {
                characters = []
            }
            let response = try await ReaderAIClient.chat(messages: [
                ReaderAIChatMessage(role: .user, content: optimizerPrompt(for: text, characters: characters))
            ], using: endpoint)
            try Task.checkCancellation()
            let rewritten = Self.cleanedResponse(response)
            prompt = rewritten.isEmpty ? text : rewritten
        }
    }

    private func optimizerPrompt(for prompt: String, characters: [ReaderBookCharacter]) -> String {
        let paragraph = context.paragraphText?.aiTrimmed ?? ""
        let characterContext = characters.prefix(12).map { character in
            var lines = ["- \(character.name)"]
            let fields = [("身份", character.identity), ("形象", character.appearance), ("性格", character.personality)]
            for (label, value) in fields {
                if let value, !value.aiTrimmed.isEmpty { lines.append("  \(label)：\(value)") }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        let characterSection = characterContext.isEmpty ? "" : "\n\n可参考的角色卡片：\n" + characterContext
        return """
        你是小说插画提示词优化助手。
        请根据下面的书籍上下文、选中文字和角色卡片，把用户当前提示词改写成更适合图像生成模型的提示词。
        要求：
        1. 只输出最终提示词，不要解释。
        2. 不要把“章节名、章节序号、出处说明”当作画面内容写入提示词。
        3. 保留人物、场景、氛围、服饰、构图、画风等对成图有帮助的信息。
        4. 不确定的信息不要硬编。

        当前书籍：\(context.bookTitle)
        作者：\(context.author)
        当前章节：\(context.chapterTitle)
        当前选中文字：
        \((paragraph.isEmpty ? prompt : paragraph).prefix(1_200))\(characterSection)

        用户当前提示词：
        \(prompt)
        """
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
