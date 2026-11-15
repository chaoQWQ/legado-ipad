import SwiftUI

struct ReaderAIProviderList: View {
    @ObservedObject var presentation: ReaderAISettingsPresentation
    @State private var editor: ReaderAIProvider?
    @State private var pendingDeletion: ReaderAIProvider?

    var body: some View {
        Group {
            if presentation.settings.providers.isEmpty {
                ContentUnavailableView {
                    Label("没有聊天提供商", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("添加提供商") { editor = ReaderAIProvider() }
                }
            } else {
                List(presentation.settings.providers) { provider in
                    Button {
                        editor = provider
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(provider.title)
                                .foregroundStyle(.primary)
                            let count = presentation.settings.models.filter { $0.providerID == provider.id }.count
                            Text("\(count) 个模型")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("删除", role: .destructive) { pendingDeletion = provider }
                    }
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { editor = provider }
                        Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = provider }
                    }
                }
            }
        }
        .navigationTitle("聊天提供商")
        .toolbar {
            if !presentation.settings.providers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("添加提供商", systemImage: "plus") { editor = ReaderAIProvider() }
                }
            }
        }
        .sheet(item: $editor) { provider in
            ReaderAIProviderEditor(
                provider: provider,
                models: presentation.settings.models.filter { $0.providerID == provider.id },
                isNew: !presentation.settings.providers.contains { $0.id == provider.id },
                save: save
            )
        }
        .alert("删除聊天提供商？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { provider in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                presentation.perform { settings in
                    settings.providers.removeAll { $0.id == provider.id }
                    let modelIDs = Set(settings.models.filter { $0.providerID == provider.id }.map(\.id))
                    settings.models.removeAll { $0.providerID == provider.id }
                    Self.clearSelections(modelIDs, in: &settings)
                }
            }
        } message: { provider in
            Text("将同时移除「\(provider.title)」的模型。")
        }
        .readerAISettingsError($presentation.errorMessage)
    }

    private func save(provider: ReaderAIProvider, models: [ReaderAIModel]) throws {
        try presentation.update { settings in
            if let index = settings.providers.firstIndex(where: { $0.id == provider.id }) {
                settings.providers[index] = provider
            } else {
                settings.providers.append(provider)
            }
            let priorIDs = Set(settings.models.lazy.filter { $0.providerID == provider.id }.map(\.id))
            let replacements = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
            settings.models = settings.models.compactMap {
                $0.providerID == provider.id ? replacements[$0.id] : $0
            }
            settings.models.append(contentsOf: models.filter { !priorIDs.contains($0.id) })
            Self.clearSelections(priorIDs.subtracting(replacements.keys), in: &settings)
        }
    }

    private static func clearSelections(_ removedIDs: Set<String>, in settings: inout ReaderAISettings) {
        if let id = settings.defaultModelID, removedIDs.contains(id) { settings.defaultModelID = nil }
        if let id = settings.askModelID, removedIDs.contains(id) { settings.askModelID = nil }
    }
}

private struct ReaderAIProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReaderAIProvider
    @State private var models: [ReaderAIModel]
    @State private var tab: Tab = .connection
    @State private var showsModelDraft = false
    @State private var editingModelID: String?
    @State private var modelName = ""
    @State private var showsCatalog = false
    @State private var errorMessage: String?

    let isNew: Bool
    let save: (ReaderAIProvider, [ReaderAIModel]) throws -> Void

    private enum Tab {
        case connection, models
    }

    init(
        provider: ReaderAIProvider, models: [ReaderAIModel], isNew: Bool,
        save: @escaping (ReaderAIProvider, [ReaderAIModel]) throws -> Void
    ) {
        _draft = State(initialValue: provider)
        _models = State(initialValue: models)
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("提供商设置", selection: $tab) {
                    Text("配置").tag(Tab.connection)
                    Text("模型").tag(Tab.models)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                if tab == .connection {
                    connection
                } else {
                    modelList
                }
            }
            .navigationTitle(isNew ? "添加聊天提供商" : "编辑聊天提供商")
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
            .sheet(isPresented: $showsCatalog) {
                ReaderAIModelCatalogView(provider: draft, selection: .adding(excluding: Set(models.map(\.model)))) { modelIDs in
                    models.append(contentsOf: modelIDs.map { ReaderAIModel(providerID: draft.id, model: $0) })
                }
            }
            .alert(editingModelID == nil ? "添加模型" : "编辑模型", isPresented: $showsModelDraft) {
                TextField("模型 ID", text: $modelName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("取消", role: .cancel) {}
                Button("确定", action: saveModel)
                    .disabled(modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .readerAISettingsError($errorMessage)
        }
    }

    private var connection: some View {
        Group {
            ReaderAISettingsConnectionFields(name: $draft.name, address: $draft.address, key: $draft.key)
            Section("调用接口") {
                Picker("接口格式", selection: $draft.apiMode) {
                    ForEach(ReaderAIAPIMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                ReaderAIEndpointPreview(address: draft.address, route: draft.apiMode.route)
                Toggle("提示词缓存", isOn: $draft.promptCache)
            }
            ReaderAISettingsHeadersField(headers: $draft.headers)
        }
    }

    private var modelList: some View {
        Group {
            Section {
                Button("手动填写模型 ID", systemImage: "plus") { showModelEditor() }
                Button("从接口列表选择", systemImage: "arrow.down.circle") { showsCatalog = true }
                    .disabled(draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("已添加模型") {
                if models.isEmpty {
                    Text("尚未添加模型").foregroundStyle(.secondary)
                }
                ForEach(models) { model in
                    Button { showModelEditor(model) } label: {
                        LabeledContent {
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        } label: {
                            Text(model.model).foregroundStyle(.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("编辑模型", systemImage: "pencil") { showModelEditor(model) }
                        Button("移除模型", systemImage: "trash", role: .destructive) {
                            models.removeAll { $0.id == model.id }
                        }
                    }
                }
                .onDelete { models.remove(atOffsets: $0) }
            }
        }
    }

    private func showModelEditor(_ model: ReaderAIModel? = nil) {
        editingModelID = model?.id
        modelName = model?.model ?? ""
        showsModelDraft = true
    }

    private func saveModel() {
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !models.contains(where: { $0.model == name && $0.id != editingModelID }) else {
            errorMessage = "已添加这个模型 ID。"
            return
        }
        if let index = models.firstIndex(where: { $0.id == editingModelID }) {
            models[index].model = name
        } else {
            models.append(ReaderAIModel(providerID: draft.id, model: name))
        }
    }

    private func saveDraft() {
        do {
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.address = draft.address.trimmingCharacters(in: .whitespacesAndNewlines)
            try save(draft, models)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ReaderAIEndpointPreview: View {
    let address: String
    let route: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("请求地址预览")
            if let preview {
                Text(verbatim: "POST \(preview.address)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                if preview.hidesQuery {
                    Text("查询参数已隐藏")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("请填写有效的接口地址。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var preview: (address: String, hidesQuery: Bool)? {
        guard let url = try? ReaderAIEndpoint.make(address, route: route),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let hidesQuery = components.percentEncodedQuery != nil
        components.percentEncodedQuery = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let address = components.string else { return nil }
        return (address, hidesQuery)
    }
}

struct ReaderAIModelCatalogView: View {
    enum Selection {
        case adding(excluding: Set<String>)
        case choosing(current: String)

        var excludedModels: Set<String> {
            if case .adding(let excluded) = self { return excluded }
            return []
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var modelIDs: [String] = []
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var reloadID = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    let provider: ReaderAIProvider
    let selection: Selection
    let apply: ([String]) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在获取模型…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("无法获取模型", systemImage: "exclamationmark.circle")
                    } description: {
                        Text("\(errorMessage)\n也可以返回手动填写模型 ID。")
                    } actions: {
                        Button("重试") { reloadID += 1 }
                    }
                } else if modelIDs.isEmpty {
                    ContentUnavailableView("没有可选的模型", systemImage: "text.badge.plus")
                } else {
                    List {
                        ForEach(filteredModels, id: \.self) { model in
                            modelRow(model)
                        }
                    }
                    .searchable(text: $query, prompt: "搜索模型 ID")
                    .overlay {
                        if filteredModels.isEmpty { ContentUnavailableView.search(text: query) }
                    }
                }
            }
            .navigationTitle("接口模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if case .adding = selection {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.isEmpty ? "添加" : "添加（\(selected.count)）") {
                            apply(modelIDs.filter { selected.contains($0) })
                            dismiss()
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
            .task(id: reloadID, load)
        }
    }

    @ViewBuilder private func modelRow(_ model: String) -> some View {
        switch selection {
        case .adding:
            Toggle(model, isOn: Binding {
                selected.contains(model)
            } set: { enabled in
                if enabled { selected.insert(model) } else { selected.remove(model) }
            })
        case .choosing(let current):
            Button {
                apply([model])
                dismiss()
            } label: {
                LabeledContent {
                    if model == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                } label: {
                    Text(verbatim: model).foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(model == current ? .isSelected : [])
        }
    }

    private var filteredModels: [String] {
        guard !query.isEmpty else { return modelIDs }
        return modelIDs.filter { $0.localizedStandardContains(query) }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let ids = try await ReaderAIClient.models(provider: provider)
            try Task.checkCancellation()
            modelIDs = Set(ids).subtracting(selection.excludedModels).sorted()
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
