import SwiftUI

struct ReaderAITavilySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presentation: ReaderAISettingsPresentation
    @State private var draft: ReaderAITavilyConfig

    init(presentation: ReaderAISettingsPresentation) {
        self.presentation = presentation
        var settings = presentation.settings.tavily
        if !ReaderAITavilyConfig.topics.contains(settings.topic) { settings.topic = "general" }
        if !ReaderAITavilyConfig.depths.contains(settings.depth) { settings.depth = "basic" }
        let range = ReaderAITavilyConfig.resultRange
        settings.maxResults = min(range.upperBound, max(range.lowerBound, settings.maxResults))
        _draft = State(initialValue: settings)
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用 Tavily 搜索", isOn: $draft.enabled)
                SecureField("Tavily API Key", text: $draft.key, prompt: Text("tvly-..."))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Tavily 接口地址", text: $draft.address, prompt: Text(ReaderAITavilyConfig.defaultAddress))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } footer: {
                Text(draft.key.aiTrimmed.isEmpty
                    ? "填写 API Key 后，AI 才能使用 Tavily 搜索。"
                    : "AI 调用联网搜索时会将搜索词发送到此接口。")
            }
            Section {
                Picker("默认主题", selection: $draft.topic) {
                    Text("通用").tag("general")
                    Text("新闻").tag("news")
                    Text("财经").tag("finance")
                }
                Picker("默认深度", selection: $draft.depth) {
                    Text("基础").tag("basic")
                    Text("高级").tag("advanced")
                    Text("极速").tag("ultra-fast")
                }
                Stepper(value: $draft.maxResults, in: ReaderAITavilyConfig.resultRange) {
                    LabeledContent("默认结果数", value: "\(draft.maxResults)")
                }
            }
        }
        .navigationTitle("Tavily 联网搜索")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
            }
        }
        .readerAISettingsError($presentation.errorMessage)
    }

    private func save() {
        do {
            draft.key = draft.key.aiTrimmed
            draft.address = try draft.validatedEndpoint().absoluteString
            try draft.validateKey()
            try presentation.update { $0.tavily = draft }
            dismiss()
        } catch {
            presentation.errorMessage = error.localizedDescription
        }
    }
}
