import SwiftUI

struct ReaderImageGenerationView: View {
    let context: ReaderImageContext

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var prompt: String
    @State private var activeStage: Stage?
    @State private var operation: Task<Void, Never>?
    @State private var manualRewrite: Task<Void, Never>?
    @State private var resultID: UUID?
    @State private var resultPreview: CGImage?
    @State private var failure: Failure?
    @State private var rewriteFailure: Failure?
    @State private var attemptedInitialGeneration = false
    @State private var optimizerConversationID = UUID()
    private let gallery = ReaderImageGalleryStore.shared

    init(context: ReaderImageContext) {
        self.context = context
        let selection = context.sourceText.aiTrimmed
        _prompt = State(initialValue: selection.isEmpty ? context.paragraphText?.aiTrimmed ?? "" : selection)
    }

    private var cleanPrompt: String { prompt.aiTrimmed }
    private var visibleStage: Stage? { activeStage ?? (manualRewrite == nil ? nil : .rewrite) }
    private var visibleFailure: Failure? { failure ?? rewriteFailure }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    previewPane
                    if resultPreview != nil {
                        if let visibleStage {
                            ProgressView(visibleStage.label).font(.footnote)
                        } else if let visibleFailure {
                            failureNotice(visibleFailure)
                        }
                    }
                    Text("图片提示词").font(.subheadline).foregroundStyle(.secondary)
                    ReaderImagePromptEditor(text: $prompt, isEditable: activeStage != .rewrite)
                        .frame(height: 108)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    actions
                }
                .frame(maxWidth: 720)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("生图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
            .onAppear {
                guard !attemptedInitialGeneration else { return }
                attemptedInitialGeneration = true
                run(.initial)
            }
        }
        .onDisappear {
            operation?.cancel()
            manualRewrite?.cancel()
        }
    }

    private var previewPane: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let resultPreview {
                ReaderZoomableImage(image: resultPreview)
                    .id(resultID)
            } else if visibleStage != nil || !attemptedInitialGeneration {
                ProgressView((visibleStage ?? .rewrite).label)
            } else if let visibleFailure {
                failureNotice(visibleFailure).padding(20)
            }
        }
        .frame(height: 330)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 12))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("优化提示词") { run(.rewrite) }
                .disabled(cleanPrompt.isEmpty || manualRewrite != nil)
            Button("重新生成") { run(.generate) }
                .disabled(cleanPrompt.isEmpty)
            Button("插入正文") { run(.insert) }
                .buttonStyle(.borderedProminent)
                .disabled(resultID == nil || !context.canInsert)
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .disabled(activeStage != nil)
    }

    private func failureNotice(_ failure: Failure) -> some View {
        VStack(spacing: 8) {
            Text(failure.message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("重试") { run(failure.action) }
                .buttonStyle(.bordered)
                .disabled(activeStage != nil || (failure.action != .insert && cleanPrompt.isEmpty))
        }
        .frame(maxWidth: .infinity)
    }

    private func run(_ action: Action) {
        guard activeStage == nil else { return }
        let text = cleanPrompt
        guard action == .insert || !text.isEmpty else {
            failure = Failure(action: action, message: "请输入生图提示词。")
            return
        }
        if action == .rewrite {
            startManualRewrite(text)
            return
        }
        let previousResult = resultID
        failure = nil
        rewriteFailure = nil
        activeStage = action.stage
        operation = Task {
            var retry = action
            defer {
                operation = nil
                activeStage = nil
            }
            do {
                if action == .insert {
                    guard let previousResult else { return }
                    try await gallery.setInserted(true, for: previousResult)
                    dismiss()
                    return
                }
                let settings = try ReaderAISettings.load()
                let provider = try imageProvider(in: settings)
                var promptToSend = text
                if action == .initial {
                    promptToSend = try await rewrite(text, using: settings)
                    try Task.checkCancellation()
                    prompt = promptToSend
                    retry = .generate
                    activeStage = .generate
                }
                try await generate(promptToSend, using: provider)
            } catch {
                if !Task.isCancelled {
                    failure = makeFailure(for: retry, from: error)
                }
            }
        }
    }

    private func startManualRewrite(_ text: String) {
        guard manualRewrite == nil else { return }
        if failure?.action == .initial { failure = nil }
        rewriteFailure = nil
        manualRewrite = Task {
            defer { manualRewrite = nil }
            do {
                let rewritten = try await rewrite(text, using: ReaderAISettings.load())
                try Task.checkCancellation()
                prompt = rewritten
            } catch {
                if !Task.isCancelled { rewriteFailure = makeFailure(for: .rewrite, from: error) }
            }
        }
    }

    private func makeFailure(for action: Action, from error: Error) -> Failure {
        let description = error.localizedDescription
        switch error {
        case ImageDialogError.missingImageProvider, ImageDialogError.missingChatModel:
            return Failure(action: action, message: description)
        default:
            return Failure(action: action, message: "\(action.stage.failureLabel)。\(description)")
        }
    }

    private func imageProvider(in settings: ReaderAISettings) throws -> ReaderAIImageProvider {
        guard let provider = settings.defaultImageProvider else { throw ImageDialogError.missingImageProvider }
        return provider
    }

    private func generate(_ text: String, using provider: ReaderAIImageProvider) async throws {
        resultID = nil
        resultPreview = nil
        let data = try await ReaderAIClient.generateImage(prompt: text, provider: provider)
        try Task.checkCancellation()
        let entry = try await gallery.store(
            data, prompt: text, provider: provider.title, model: provider.resolvedModelName, context: context
        )
        let url = gallery.fileURL(for: entry)
        let preview = await Task.detached(priority: .userInitiated) {
            ReaderGalleryPicture.thumbnail(at: url, maxDimension: 1_800)
        }.value
        try Task.checkCancellation()
        guard let preview else { throw ImageDialogError.previewFailed }
        resultPreview = preview
        resultID = entry.id
    }

    private func rewrite(_ text: String, using settings: ReaderAISettings) async throws -> String {
        guard let choice = settings.defaultChatChoice else { throw ImageDialogError.missingChatModel }
        let characters: [ReaderBookCharacter]
        if let bookID = context.bookID {
            characters = try await ReaderBookCharacterStore.shared.characters(for: bookID)
        } else {
            characters = []
        }
        let tools = ReaderAINativeTools.selected(
            for: optimizerConversationID, library: library, scope: .enabled,
            disabled: settings.disabledNativeToolNames ?? [], tavily: settings.tavily
        )
        let messages = try await ReaderAIRequestPreparation.prepare(
            messages: [ReaderAIChatMessage(role: .user, content: optimizerPrompt(for: text, characters: characters))],
            settings: settings, tools: tools
        )
        let response = try await ReaderAIClient.chat(
            messages: messages, using: choice, tools: tools, toolRoundLimit: settings.toolRoundLimit,
            includesToolRoundText: false
        )
        let rewritten = Self.cleanedResponse(response)
        guard !rewritten.isEmpty else { throw ImageDialogError.emptyRewrite }
        return rewritten
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

    private static func cleanedResponse(_ result: String) -> String {
        var text = result.aiTrimmed
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            let fenced = text.dropFirst(3).dropLast(3)
            if let lineEnd = fenced.firstIndex(of: "\n"),
               ["text", "plaintext", "markdown"].contains(String(fenced[..<lineEnd]).lowercased()) {
                text = String(fenced[fenced.index(after: lineEnd)...]).aiTrimmed
            } else {
                text = String(fenced).aiTrimmed
            }
        }
        if text.count >= 2, (text.hasPrefix("“") && text.hasSuffix("”")) ||
            (text.hasPrefix("\"") && text.hasSuffix("\"")) {
            text = String(text.dropFirst().dropLast()).aiTrimmed
        }
        return text
    }

    private enum Action {
        case initial, rewrite, generate, insert

        var stage: Stage {
            switch self {
            case .initial, .rewrite: .rewrite
            case .generate: .generate
            case .insert: .insert
            }
        }
    }

    private enum Stage {
        case rewrite, generate, insert

        var label: String {
            switch self {
            case .rewrite: "正在优化提示词"
            case .generate: "正在生成图片"
            case .insert: "正在插入正文"
            }
        }

        var failureLabel: String {
            switch self {
            case .rewrite: "提示词优化失败"
            case .generate: "图片生成失败"
            case .insert: "插入正文失败"
            }
        }
    }

    private struct Failure {
        let action: Action
        let message: String
    }

    private enum ImageDialogError: LocalizedError {
        case missingImageProvider, missingChatModel, emptyRewrite, previewFailed

        var errorDescription: String? {
            switch self {
            case .missingImageProvider: "请先在 AI 设置中启用生图供应商。"
            case .missingChatModel: "请先在 AI 设置中配置通用聊天模型。"
            case .emptyRewrite: "聊天模型没有返回可用的提示词。"
            case .previewFailed: "无法预览供应商返回的图片。"
            }
        }
    }
}
