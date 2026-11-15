import SwiftUI

struct ReaderAISettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var presentation = ReaderAISettingsPresentation()
    @State private var showsPrompt = false
    @State private var installsDefaultSkill = false
    @State private var installedSkillName: String?
    private let catalogID = UUID()

    var body: some View {
        Group {
            if presentation.isLoaded {
                settingsForm
            } else if presentation.loadFailed {
                ContentUnavailableView {
                    Label("无法读取 AI 设置", systemImage: "lock")
                } actions: {
                    Button("重试", action: presentation.reload)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("AI 设置")
        .onAppear(perform: presentation.reload)
        .sheet(isPresented: $showsPrompt) {
            ReaderAIPromptEditor(presentation: presentation)
        }
        .readerAISettingsError($presentation.errorMessage)
    }

    private var settingsForm: some View {
        let settings = presentation.settings
        return Form {
            Section {
                Toggle("启用 AI", isOn: presentation.binding(\.enabled))
                Button(action: installDefaultSkill) {
                    if installsDefaultSkill {
                        HStack {
                            Text("正在安装 Skill…")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        LabeledContent("安装默认 阅读Archive Skill", value: "SKILL.md")
                    }
                }
                .disabled(installsDefaultSkill)
                NavigationLink {
                    ReaderAISkillSettingsView(presentation: presentation)
                } label: {
                    LabeledContent("管理 Skill", value: skillSummary)
                }
                NavigationLink {
                    ReaderAINativeToolSettingsView(presentation: presentation)
                } label: {
                    let tools = ReaderAINativeTools.catalog(for: catalogID, library: library, tavily: settings.tavily)
                    let count = tools.filter { settings.disabledNativeToolNames?.contains($0.name) != true }.count
                    LabeledContent("管理原生工具", value: "\(count) 个已启用")
                }
                NavigationLink("AI 工作区") { ReaderAIWorkspaceView() }
                Stepper(value: presentation.binding(\.toolRoundLimit), in: 4...64) {
                    LabeledContent("AI 工具轮次上限", value: "\(settings.toolRoundLimit) 轮")
                }
                Picker("正文问 AI 工具范围", selection: presentation.binding(\.readToolScope)) {
                    ForEach(ReaderAIToolScope.allCases) { scope in Text(scope.title).tag(scope) }
                }
                Toggle("回车发送", isOn: presentation.binding(\.returnToSend))
                Toggle("显示思考工具栏", isOn: presentation.binding(\.showsThinkingToolbar))
            } footer: {
                if let installedSkillName {
                    Text("已安装「\(installedSkillName)」。")
                }
            }
            Section("默认模型") {
                Picker("默认聊天模型", selection: presentation.binding(\.defaultModelID)) {
                    Text("自动选择").tag(nil as String?)
                    ForEach(settings.questionChoices) { choice in
                        Text(choice.title).tag(Optional(choice.id))
                    }
                }
                Picker("正文问 AI 模型", selection: presentation.binding(\.askModelID)) {
                    Text("使用默认聊天模型").tag(nil as String?)
                    ForEach(settings.questionChoices) { choice in
                        Text(choice.title).tag(Optional(choice.id))
                    }
                }
                Picker("图像生成提供商", selection: presentation.binding(\.imageProviderID)) {
                    Text("自动选择").tag(nil as String?)
                    ForEach(settings.enabledImageProviders) { provider in
                        Text(provider.title).tag(Optional(provider.id))
                    }
                }
            }
            Section("提供商") {
                NavigationLink {
                    ReaderAIProviderList(presentation: presentation)
                } label: {
                    LabeledContent("管理提供商", value: "\(settings.providers.count)")
                }
                NavigationLink {
                    ReaderAIImageProviderList(presentation: presentation)
                } label: {
                    LabeledContent("图像生成提供商管理", value: "\(settings.imageProviders.count)")
                }
            }
            Section("MCP 服务器") {
                NavigationLink("添加 MCP 服务器") { ReaderAIMCPAddServerView(presentation: presentation) }
                NavigationLink {
                    ReaderAIMCPSettingsView(presentation: presentation)
                } label: {
                    let count = settings.mcpServers.filter(\.enabled).count
                    LabeledContent("管理 MCP 服务器", value: settings.mcpServers.isEmpty ? "暂无" : "\(count) 个已启用")
                }
            }
            ReaderAITavilySettingsView(presentation: presentation)
            Section {
                Button {
                    showsPrompt = true
                } label: {
                    LabeledContent(
                        "正文问 AI 提示词",
                        value: settings.askPrompt.isEmpty || settings.askPrompt == ReaderAISettings.defaultAskPrompt ? "默认" : "自定义"
                    )
                        .foregroundStyle(.primary)
                }
                NavigationLink("图像图库") { ReaderImageGalleryView() }
            }
        }
    }

    private var skillSummary: String {
        let skills = presentation.settings.skills
        guard !skills.isEmpty else { return "未安装 Skill" }
        return "已启用 \(skills.filter(\.enabled).count) 个，共 \(skills.count) 个"
    }

    private func installDefaultSkill() {
        guard !installsDefaultSkill else { return }
        installsDefaultSkill = true
        installedSkillName = nil
        Task {
            defer { installsDefaultSkill = false }
            do {
                let skill = try await ReaderAISkill.fetchDefault()
                try presentation.updateSkills { $0.installDefaultSkill(skill) }
                installedSkillName = skill.name
            } catch {
                presentation.errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
final class ReaderAISettingsPresentation: ObservableObject {
    @Published private(set) var settings = ReaderAISettings()
    @Published private(set) var isLoaded = false
    @Published private(set) var loadFailed = false
    @Published var errorMessage: String?

    func reload() {
        do {
            settings = try ReaderAISettings.load()
            isLoaded = true
            loadFailed = false
        } catch {
            isLoaded = false
            loadFailed = true
            errorMessage = error.localizedDescription
        }
    }

    func update(_ change: (inout ReaderAISettings) -> Void) throws {
        var updated = try ReaderAISettings.load()
        change(&updated)
        try updated.save()
        settings = updated
    }

    func updateSkills(_ change: (inout ReaderAISettings) -> Void) throws {
        var updated = try ReaderAISettings.load()
        updated.skills = try ReaderAISkill.loadLibrary()
        change(&updated)
        try updated.saveSkills()
        settings = updated
    }

    func perform(_ change: (inout ReaderAISettings) -> Void) {
        do {
            try update(change)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<ReaderAISettings, Value>) -> Binding<Value> {
        Binding {
            self.settings[keyPath: keyPath]
        } set: { value in
            self.perform { $0[keyPath: keyPath] = value }
        }
    }
}

struct ReaderAISettingsConnectionFields: View {
    @Binding var name: String
    @Binding var address: String
    @Binding var key: String

    var body: some View {
        Section("连接") {
            TextField("提供商名称", text: $name)
            TextField("接口地址", text: $address, prompt: Text("https://api.openai.com/v1"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("API 密钥", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

struct ReaderAISettingsHeadersField: View {
    @Binding var headers: String

    var body: some View {
        Section {
            TextField("自定义请求头", text: $headers, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("自定义请求头")
        } footer: {
            Text("支持 JSON 对象，或每行填写一个「名称: 值」。")
        }
    }
}

private struct ReaderAIPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: String
    @State private var errorMessage: String?
    let presentation: ReaderAISettingsPresentation

    init(presentation: ReaderAISettingsPresentation) {
        self.presentation = presentation
        _prompt = State(initialValue: presentation.settings.askPrompt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "提示词", text: $prompt,
                        prompt: Text(ReaderAISettings.defaultAskPrompt),
                        axis: .vertical
                    )
                        .lineLimit(6...20)
                } footer: {
                    Text("留空使用内置提示词。")
                }
            }
            .navigationTitle("正文问 AI 提示词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try presentation.update { $0.askPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .readerAISettingsError($errorMessage)
        }
    }
}

extension View {
    func readerAISettingsError(_ message: Binding<String?>) -> some View {
        alert("AI 设置", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
