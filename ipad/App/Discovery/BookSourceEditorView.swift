import BookSources
import SwiftUI

struct BookSourceEditorView: View {
    let source: BookSource?
    let save: (BookSource) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: BookSourceDraft
    @State private var tab: BookSourceEditorTab = .basics
    @State private var rawJSON = ""
    @State private var startingJSON = ""
    @State private var errorMessage: String?
    @State private var showDiscard = false

    private let startingDraft: BookSourceDraft

    init(source: BookSource?, save: @escaping (BookSource) throws -> Void) {
        self.source = source
        self.save = save
        let initial = BookSourceDraft(source: source)
        startingDraft = initial
        _draft = State(initialValue: initial)
    }

    private var isDirty: Bool { draft != startingDraft || (tab == .json && rawJSON != startingJSON) }

    private var savesAsNewSource: Bool {
        guard let source else { return false }
        let address: String?
        if tab == .json {
            address = (try? JSONDecoder().decode(SourceAddress.self, from: Data(rawJSON.utf8)))?.bookSourceUrl
        } else {
            address = draft["bookSourceUrl"]
        }
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else { return false }
        return address != source.id
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider()
            if tab == .json {
                TextEditor(text: $rawJSON)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel("书源 JSON")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                form
                    .id(tab)
            }
            if savesAsNewSource {
                Text("地址变更会另存为新书源，已入架的书籍仍关联原书源。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.bar)
            }
        }
        .navigationTitle(source == nil ? "新建书源" : "编辑书源")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    if isDirty { showDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(savesAsNewSource ? "另存为新书源" : "保存", action: saveDraft)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("放弃未保存的更改？", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .alert("书源编辑", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(BookSourceEditorTab.allCases) { candidate in
                    Button { select(candidate) } label: {
                        Text(candidate.title)
                            .font(.subheadline.weight(tab == candidate ? .semibold : .regular))
                            .foregroundStyle(tab == candidate ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(tab == candidate ? Color.accentColor.opacity(0.14) : .clear, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == candidate ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private var form: some View {
        Form {
            if tab == .basics {
                Section("书源信息") {
                    ForEach(BookSourceEditorTab.identityFields, content: input)
                    Toggle("启用书源", isOn: flag("enabled", defaultValue: true))
                    Picker("书源类型", selection: $draft.sourceType) {
                        Text("文本").tag(0)
                        Text("音频").tag(1)
                        Text("图片").tag(2)
                        Text("文件").tag(3)
                        Text("视频").tag(4)
                        if !(0...4).contains(draft.sourceType) { Text("类型 \(draft.sourceType)").tag(draft.sourceType) }
                    }
                }
                Section("请求设置") {
                    ForEach(BookSourceEditorTab.requestFields, content: input)
                    Toggle("保存网站 Cookie", isOn: flag("enabledCookieJar", defaultValue: true))
                }
                Section("Android 兼容字段") {
                    ForEach(BookSourceEditorTab.androidFields, content: input)
                    Toggle("启用事件监听", isOn: flag("eventListener", defaultValue: false))
                    Toggle("显示自定义按钮", isOn: flag("customButton", defaultValue: false))
                }
            } else {
                Section {
                    if tab == .explore { Toggle("启用发现", isOn: flag("enabledExplore", defaultValue: true)) }
                    ForEach(tab.fields, content: input)
                } footer: {
                    if tab == .content {
                        Text("正文替换可填写正则规则或内置繁转简表达式 `@js:java.t2s(result)`。")
                    } else if tab == .explore || tab == .reviews {
                        Text("这些规则保存在书源中，可供 Android 阅读使用。")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func input(_ field: BookSourceEditorField) -> some View {
        let value = Binding(
            get: { draft[field.key, rule: field.rule] },
            set: { draft[field.key, rule: field.rule] = $0 }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text(field.title).font(.subheadline.weight(.medium))
            if field.isCode {
                TextField(field.key, text: value, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1...8)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .accessibilityLabel(field.title)
            } else if field.key == "bookSourceUrl" {
                TextField("https://example.com", text: value)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .accessibilityLabel(field.title)
            } else {
                TextField("请输入\(field.title)", text: value, axis: .vertical)
                    .lineLimit(1...8)
                    .accessibilityLabel(field.title)
            }
        }
        .padding(.vertical, 4)
    }

    private func flag(_ key: String, defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { draft[flag: key, default: defaultValue] },
            set: { draft[flag: key, default: defaultValue] = $0 }
        )
    }

    private func select(_ candidate: BookSourceEditorTab) {
        guard candidate != tab else { return }
        do {
            if tab == .json, rawJSON != startingJSON { draft = try BookSourceDraft(json: rawJSON) }
            if candidate == .json {
                rawJSON = try draft.jsonString()
                startingJSON = rawJSON
            }
            tab = candidate
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveDraft() {
        do {
            let current = tab == .json && rawJSON != startingJSON ? try BookSourceDraft(json: rawJSON) : draft
            try save(current.makeSource())
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private struct SourceAddress: Decodable {
        let bookSourceUrl: String?
    }
}
