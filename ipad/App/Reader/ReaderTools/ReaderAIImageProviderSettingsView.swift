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
    let isNew: Bool
    let save: (ReaderAIImageProvider) throws -> Void

    private enum ImageAPI {
        case images, responses
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
                    LabeledContent("类型", value: "OpenAI 兼容")
                    Toggle("启用提供商", isOn: $draft.enabled)
                }
                ReaderAISettingsConnectionFields(name: $draft.name, address: $draft.address, key: $draft.key)
                Section {
                    Picker("接口格式", selection: imageAPI) {
                        Text("Images API").tag(ImageAPI.images)
                        Text("Responses").tag(ImageAPI.responses)
                    }
                    if let parameters = try? draft.parameters() {
                        ReaderAIEndpointPreview(
                            address: draft.address,
                            route: draft.usesResponses(parameters: parameters) ? "responses" : "images/generations"
                        )
                    }
                    TextField("模型 ID", text: $draft.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper(value: timeout, in: 60...600, step: 15) {
                        LabeledContent("请求超时", value: "\(timeout.wrappedValue) 秒")
                    }
                } header: {
                    Text("调用接口")
                } footer: {
                    Text("模型 ID 留空时使用该接口的默认模型。")
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
                    Text("例如 { \"size\": \"1024x1024\" }。参数按所选接口发送。")
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
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .readerAISettingsError($errorMessage)
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
            try save(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}
