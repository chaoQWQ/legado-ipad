import SwiftUI

struct ReaderAISkillSettingsView: View {
    @ObservedObject var presentation: ReaderAISettingsPresentation
    @State private var editor: EditorRequest?
    @State private var pendingDeletion: ReaderAISkill?

    var body: some View {
        List {
            Section {
                Button("手动导入 SKILL.md", systemImage: "plus") { editor = .add }
            }
            Section("已安装") {
                if presentation.settings.skills.isEmpty {
                    Text("未安装 Skill").foregroundStyle(.secondary)
                }
                ForEach(presentation.settings.skills, id: \.id) { skill in
                    row(skill)
                }
            }
        }
        .navigationTitle("管理 Skill")
        .sheet(item: $editor) { request in
            ReaderAISkillEditor(skill: request.skill, save: saveSkill)
        }
        .alert("删除这个 Skill？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { skill in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                changeLibrary { $0.skills.removeAll { $0.id == skill.id } }
            }
        } message: { skill in
            Text(skill.name)
        }
        .readerAISettingsError($presentation.errorMessage)
    }

    private func row(_ skill: ReaderAISkill) -> some View {
        Button {
            editor = .edit(skill)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(skill.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Text(skill.enabled ? "已启用" : "已停用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(skill.enabled ? "停用" : "启用") { toggle(skill) }
                .tint(skill.enabled ? .orange : .accentColor)
        }
        .swipeActions(allowsFullSwipe: false) {
            Button("删除", role: .destructive) { pendingDeletion = skill }
        }
        .contextMenu {
            Button("编辑", systemImage: "pencil") { editor = .edit(skill) }
            Button(skill.enabled ? "停用" : "启用", systemImage: skill.enabled ? "pause.circle" : "play.circle") {
                toggle(skill)
            }
            Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = skill }
        }
    }

    private func saveSkill(_ skill: ReaderAISkill) throws {
        try presentation.updateSkills { settings in
            if let index = settings.skills.firstIndex(where: { $0.id == skill.id }) {
                settings.skills[index] = skill
            } else {
                settings.skills.append(skill)
            }
        }
    }

    private func toggle(_ skill: ReaderAISkill) {
        changeLibrary { settings in
            guard let index = settings.skills.firstIndex(where: { $0.id == skill.id }) else { return }
            settings.skills[index].enabled.toggle()
        }
    }

    private func changeLibrary(_ change: (inout ReaderAISettings) -> Void) {
        do {
            try presentation.updateSkills(change)
        } catch {
            presentation.errorMessage = error.localizedDescription
        }
    }

    private enum EditorRequest: Identifiable {
        case add
        case edit(ReaderAISkill)

        var id: String { skill?.id ?? "new-skill" }

        var skill: ReaderAISkill? {
            if case let .edit(skill) = self { return skill }
            return nil
        }
    }
}

private struct ReaderAISkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var enabled: Bool
    @State private var errorMessage: String?
    let skill: ReaderAISkill?
    let save: (ReaderAISkill) throws -> Void

    init(skill: ReaderAISkill?, save: @escaping (ReaderAISkill) throws -> Void) {
        self.skill = skill
        self.save = save
        _content = State(initialValue: skill?.content ?? "")
        _enabled = State(initialValue: skill?.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用 Skill", isOn: $enabled)
                }
                Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 320)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("SKILL.md 内容")
                } header: {
                    Text("SKILL.md")
                } footer: {
                    if skill == nil { Text("将 SKILL.md 内容粘贴到这里。") }
                }
            }
            .navigationTitle(skill?.name ?? "手动导入 SKILL.md")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(skill == nil ? "导入" : "保存", action: saveDraft)
                        .disabled(content.isEmpty)
                }
            }
            .readerAISettingsError($errorMessage)
        }
    }

    private func saveDraft() {
        do {
            var updated = try ReaderAISkill.parse(content, replacing: skill)
            updated.enabled = enabled
            try save(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
