import SwiftUI

struct ReaderAIImageProviderList: View {
    @ObservedObject var presentation: ReaderAISettingsPresentation
    @State private var editor: ReaderAIImageProvider?
    @State private var pendingDeletion: ReaderAIImageProvider?

    var body: some View {
        Group {
            if presentation.settings.imageProviders.isEmpty {
                ContentUnavailableView {
                    Label("没有图像生成提供商", systemImage: "photo")
                } actions: {
                    Button("添加提供商") { editor = ReaderAIImageProvider() }
                }
            } else {
                List(presentation.settings.imageProviders) { provider in
                    Button {
                        editor = provider
                    } label: {
                        LabeledContent {
                            if provider.id == presentation.settings.imageProviderID {
                                Label("默认", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            } else if !provider.enabled {
                                Text("已停用")
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(provider.title)
                                    .foregroundStyle(.primary)
                                if provider.title != provider.resolvedModelName {
                                    Text(provider.resolvedModelName)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("删除", role: .destructive) { pendingDeletion = provider }
                    }
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { editor = provider }
                        if provider.enabled && provider.id != presentation.settings.imageProviderID {
                            Button("设为默认", systemImage: "checkmark.circle") {
                                presentation.perform { $0.imageProviderID = provider.id }
                            }
                        }
                        Button(
                            provider.enabled ? "停用" : "启用",
                            systemImage: provider.enabled ? "pause.circle" : "play.circle"
                        ) {
                            setEnabled(!provider.enabled, providerID: provider.id)
                        }
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = provider }
                    }
                }
            }
        }
        .navigationTitle("图像生成提供商")
        .toolbar {
            if !presentation.settings.imageProviders.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("添加提供商", systemImage: "plus") { editor = ReaderAIImageProvider() }
                }
            }
        }
        .sheet(item: $editor) { provider in
            ReaderAIImageProviderEditor(
                provider: provider,
                isNew: !presentation.settings.imageProviders.contains { $0.id == provider.id },
                save: save
            )
        }
        .alert("删除图像生成提供商？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { provider in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                presentation.perform { settings in
                    settings.imageProviders.removeAll { $0.id == provider.id }
                    if settings.imageProviderID == provider.id { settings.imageProviderID = nil }
                }
            }
        } message: { provider in
            Text(provider.title)
        }
        .readerAISettingsError($presentation.errorMessage)
    }

    private func save(_ provider: ReaderAIImageProvider) throws {
        try presentation.update { settings in
            if let index = settings.imageProviders.firstIndex(where: { $0.id == provider.id }) {
                settings.imageProviders[index] = provider
            } else {
                settings.imageProviders.append(provider)
            }
            if !provider.enabled && settings.imageProviderID == provider.id { settings.imageProviderID = nil }
        }
    }

    private func setEnabled(_ enabled: Bool, providerID: String) {
        presentation.perform { settings in
            guard let index = settings.imageProviders.firstIndex(where: { $0.id == providerID }) else { return }
            settings.imageProviders[index].enabled = enabled
            if !enabled && settings.imageProviderID == providerID { settings.imageProviderID = nil }
        }
    }
}

private struct ReaderAIImageProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReaderAIImageProvider
    @State private var errorMessage: String?
    @State private var modelPicker: ModelField?
    let isNew: Bool
    let save: (ReaderAIImageProvider) throws -> Void

    private enum ImageAPI {
        case images, responses
    }

    private enum ModelField: String, Identifiable {
        case main, imageTool

        var id: Self { self }
    }

    init(provider: ReaderAIImageProvider, isNew: Bool, save: @escaping (ReaderAIImageProvider) throws -> Void) {
        _draft = State(initialValue: provider)
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("提供商") {
                    Picker("类型", selection: $draft.kind) {
                        ForEach(ReaderAIImageProvider.Kind.allCases) { kind in Text(kind.title).tag(kind) }
                    }
                    Toggle("启用提供商", isOn: $draft.enabled)
                }
                ReaderAISettingsConnectionFields(name: $draft.name, address: $draft.address, key: $draft.key)
                if draft.kind == .openAI {
                    Section("调用接口") {
                        Picker("接口格式", selection: imageAPI) {
                            Text("Images API").tag(ImageAPI.images)
                            Text("Responses").tag(ImageAPI.responses)
                        }
                    }
                    modelSection
                } else {
                    scriptSection
                }
                Section("请求配置") {
                    if draft.kind == .openAI, let parameters = try? draft.parameters() {
                        ReaderAIEndpointPreview(
                            address: draft.address,
                            route: draft.usesResponses(parameters: parameters) ? "responses" : "images/generations"
                        )
                    }
                    Stepper(value: timeout, in: 60...600, step: 15) {
                        LabeledContent("请求超时", value: "\(timeout.wrappedValue) 秒")
                    }
                }
                ReaderAISettingsHeadersField(headers: $draft.headers)
                Section {
                    TextField("JSON 对象", text: $draft.parametersJSON, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(4...12)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("默认参数")
                } footer: {
                    Text(draft.kind == .script ? "脚本可通过 provider.parameters 读取这些参数。" : "例如 { \"size\": \"1024x1024\" }。参数按所选接口发送。")
                }
                Section("风格提示词") {
                    TextField("附加到每次生图提示词", text: $draft.stylePrompt, axis: .vertical)
                        .lineLimit(3...12)
                }
            }
            .navigationTitle(isNew ? "添加图像生成提供商" : "编辑图像生成提供商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: saveDraft)
                        .disabled(draft.name.aiTrimmed.isEmpty || (draft.kind == .script
                            ? (draft.script ?? "").aiTrimmed.isEmpty : draft.address.aiTrimmed.isEmpty))
                }
            }
            .readerAISettingsError($errorMessage)
            .sheet(item: $modelPicker) { field in
                let provider = ReaderAIProvider(address: draft.address, key: draft.key, headers: draft.headers)
                let current = field == .main ? requestModel : (toolModel ?? "")
                ReaderAIModelCatalogView(provider: provider, selection: .choosing(current: current)) { models in
                    guard let model = models.first else { return }
                    switch field {
                    case .main: draft.model = model
                    case .imageTool: draft.imageToolModel = model
                    }
                }
            }
        }
    }

    private var usesResponses: Bool { imageAPI.wrappedValue == .responses }
    private var requestModel: String { draft.resolvedModel(parameters: (try? draft.parameters()) ?? [:]) }
    private var toolModel: String? { draft.resolvedImageToolModel(parameters: (try? draft.parameters()) ?? [:]) }

    private var scriptSection: some View {
        Section {
            TextField("模型名称（选填）", text: $draft.model)
            TextField("async function generate(prompt, provider) { … }", text: scriptBinding(\.script), axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(5...15)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("共用 JS（选填）", text: scriptBinding(\.scriptLibrary), axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("生图脚本")
        } footer: {
            Text("返回图片 URL、Base64 或 JSON。接口请求可用 await java.ajax 或 await java.post。")
        }
    }

    private func scriptBinding(_ field: WritableKeyPath<ReaderAIImageProvider, String?>) -> Binding<String> {
        Binding { draft[keyPath: field] ?? "" } set: { draft[keyPath: field] = $0 }
    }

    private var modelSection: some View {
        Section {
            modelField(usesResponses ? "主模型 ID" : "生图模型 ID", text: $draft.model, suggested: requestModel)
            Button(usesResponses ? "从接口列表选择主模型" : "从接口列表选择生图模型", systemImage: "list.bullet") {
                modelPicker = .main
            }
            .disabled(draft.address.aiTrimmed.isEmpty)
            if usesResponses {
                modelField("生图模型 ID", text: Binding {
                    draft.imageToolModel ?? ""
                } set: { value in
                    draft.imageToolModel = value
                }, suggested: toolModel ?? "由服务决定")
                Button("从接口列表选择生图模型", systemImage: "list.bullet") { modelPicker = .imageTool }
                    .disabled(draft.address.aiTrimmed.isEmpty)
            }
        } header: {
            Text("模型")
        } footer: {
            if usesResponses {
                Text("主模型需要支持调用生图工具。生图模型留空时，沿用默认参数里的 tool.model 或由服务决定。")
            } else {
                Text("选择供应商支持的生图模型。也可以手填模型 ID，例如供应商没有提供模型列表时。")
            }
        }
    }

    private func modelField(_ label: String, text: Binding<String>, suggested: String) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: Text(verbatim: suggested))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var timeout: Binding<Int> {
        Binding {
            draft.timeoutMilliseconds / 1000
        } set: {
            draft.timeoutMilliseconds = $0 * 1000
        }
    }

    private var imageAPI: Binding<ImageAPI> {
        Binding {
            draft.usesResponses(parameters: (try? draft.parameters()) ?? [:]) ? .responses : .images
        } set: { api in
            do {
                var parameters = try draft.parameters()
                parameters["endpoint"] = api == .responses ? "responses" : "images"
                let data = try JSONSerialization.data(withJSONObject: parameters, options: [.prettyPrinted, .sortedKeys])
                draft.parametersJSON = String(decoding: data, as: UTF8.self)
            } catch {
                errorMessage = "请先将默认参数修正为有效的 JSON 对象。"
            }
        }
    }

    private func saveDraft() {
        do {
            _ = try draft.parameters()
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let imageModel = draft.imageToolModel?.aiTrimmed ?? ""
            draft.imageToolModel = imageModel.isEmpty ? nil : imageModel
            try save(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
