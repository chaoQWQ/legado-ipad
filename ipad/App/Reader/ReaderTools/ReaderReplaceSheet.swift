import SwiftUI

struct ReaderReplaceSheet: View {
    @Binding var rules: [ReaderReplacementRule]

    @Environment(\.dismiss) private var dismiss
    @State private var editing: ReaderReplacementRule?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if rules.isEmpty {
                        ContentUnavailableView(
                            "暂无替换规则",
                            systemImage: "text.badge.plus",
                            description: Text("添加规则以替换正文中的文字。")
                        )
                    }
                    ForEach($rules) { $rule in
                        HStack(spacing: 16) {
                            Button {
                                editing = rule
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.find)
                                    Text(rule.replacement.isEmpty ? "删除匹配的文字" : rule.replacement)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Toggle("启用规则 \(rule.find)", isOn: $rule.isEnabled)
                                .labelsHidden()
                        }
                    }
                    .onDelete { rules.remove(atOffsets: $0) }
                    .onMove { rules.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    if !rules.isEmpty {
                        Text("从上往下应用规则，只影响这本书的阅读显示。")
                    }
                }
            }
            .navigationTitle("正文替换")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = ReaderReplacementRule()
                    } label: {
                        Label("新建规则", systemImage: "plus")
                    }
                }
                #if os(iOS)
                if !rules.isEmpty {
                    ToolbarItem(placement: .secondaryAction) {
                        EditButton()
                    }
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { rule in
                ReaderReplaceRuleEditor(rule: rule) { updated in
                    if let index = rules.firstIndex(where: { $0.id == updated.id }) {
                        rules[index] = updated
                    } else {
                        rules.append(updated)
                    }
                }
            }
        }
    }
}

private struct ReaderReplaceRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: ReaderReplacementRule
    let save: (ReaderReplacementRule) -> Void

    init(rule: ReaderReplacementRule, save: @escaping (ReaderReplacementRule) -> Void) {
        self._rule = State(initialValue: rule)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("查找") {
                    TextField("要匹配的文字", text: $rule.find, axis: .vertical)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Section {
                    TextField("替换后的文字", text: $rule.replacement, axis: .vertical)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("替换为")
                } footer: {
                    Text("留空可删除匹配的文字。")
                }
            }
            .navigationTitle("替换规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save(rule)
                        dismiss()
                    }
                    .disabled(rule.find.isEmpty || rule.find == rule.replacement)
                }
            }
        }
    }
}
