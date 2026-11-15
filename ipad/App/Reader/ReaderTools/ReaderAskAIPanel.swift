import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ReaderAskAIPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var windowSkillIDs: Set<String>
    @StateObject private var session: ReaderAskAISession
    @State private var showsHistory = false
    @State private var activeSheet: PanelSheet?
    @State private var confirmsClear = false
    @State private var showsExcerpt = false
    @State private var expandsPanel = false
    @State private var followsLatest = true
    @FocusState private var composerFocused: Bool

    init(
        bookID: UUID, bookTitle: String, author: String, sourceName: String?, chapterTitle: String, excerpt: String,
        selectedSkillIDs: Binding<Set<String>>
    ) {
        let context = ReaderAskAIContext(
            bookTitle: bookTitle, author: author, sourceName: sourceName,
            chapterTitle: chapterTitle, excerpt: excerpt
        )
        _windowSkillIDs = selectedSkillIDs
        _session = StateObject(wrappedValue: ReaderAskAISession(
            bookID: bookID, context: context, initialSkillIDs: selectedSkillIDs.wrappedValue
        ))
    }

    var body: some View {
        presentation {
            NavigationStack {
                VStack(spacing: 0) {
                    if showsHistory {
                        historyList
                        if session.isRequesting {
                            Divider()
                            composer
                        }
                    } else {
                        contextBar
                        Divider()
                        transcript
                        Divider()
                        composer
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let error = session.historyError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(.regularMaterial)
                    }
                }
                .navigationTitle(showsHistory ? "本书对话历史" : "问 AI")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
            }
        }
        .task { session.load() }
        .onChange(of: session.selectedSkillIDs) { _, ids in windowSkillIDs = ids }
        .onDisappear { session.stop() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                NavigationStack { ReaderAISettingsView() }
                    .onDisappear { session.reloadSettings() }
            case .skills:
                ReaderAskAISkillPicker(
                    skills: session.availableSkills,
                    selection: session.selectedSkillIDs,
                    apply: session.chooseSkills
                )
            }
        }
        .alert("清空本书的所有问 AI 对话？", isPresented: $confirmsClear) {
            Button("清空本书历史", role: .destructive) { session.clearHistory() }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func presentation<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            if expandsPanel {
                content().presentationSizing(.page)
            } else {
                content().presentationSizing(.form)
            }
        } else {
            content()
        }
        #else
        content().frame(minWidth: 480, minHeight: 480)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭", systemImage: "xmark") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("新对话", systemImage: "square.and.pencil") {
                    session.newConversation()
                    showsHistory = false
                    followsLatest = true
                }
                Button(showsHistory ? "返回对话" : "本书对话历史", systemImage: "clock.arrow.circlepath") {
                    composerFocused = false
                    showsHistory.toggle()
                }
                Button("当前窗口 Skill（\(session.selectedSkillIDs.count)）", systemImage: "list.bullet.rectangle") {
                    composerFocused = false
                    session.reloadSettings()
                    activeSheet = .skills
                }
                .disabled(session.isRequesting)
                #if os(iOS)
                if #available(iOS 18.0, *) {
                    Button(
                        expandsPanel ? "缩小面板" : "展开面板",
                        systemImage: expandsPanel ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                    ) { expandsPanel.toggle() }
                }
                #endif
                Button("AI 设置", systemImage: "gearshape") { activeSheet = .settings }
                    .disabled(session.isRequesting)
            } label: {
                Label("对话选项", systemImage: "ellipsis.circle")
            }
        }
    }

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(session.context.bookTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let choice = session.choice {
                    Menu {
                        ForEach(session.choices, id: \.id) { model in
                            Button {
                                session.choose(model)
                            } label: {
                                if model.id == choice.id {
                                    Label(model.title, systemImage: "checkmark")
                                } else {
                                    Text(model.title)
                                }
                            }
                        }
                    } label: {
                        Label(choice.title, systemImage: "chevron.down")
                            .font(.subheadline)
                            .lineLimit(1)
                            .accessibilityLabel("当前模型，\(choice.title)")
                    }
                    .disabled(session.isRequesting)
                }
            }
            if !session.context.excerpt.isEmpty {
                Button {
                    showsExcerpt.toggle()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "quote.opening")
                        Text(session.context.excerpt).lineLimit(1)
                        Image(systemName: showsExcerpt ? "chevron.up" : "chevron.down")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("选中文本，\(showsExcerpt ? "收起" : "展开")")
                }
                .buttonStyle(.plain)
                if showsExcerpt {
                    ScrollView {
                        Text(session.context.excerpt)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(idealHeight: 96, maxHeight: 140)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var transcript: some View {
        if let conversation = session.conversation, !conversation.turns.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(conversation.turns) { turn in
                            turnView(turn, latest: turn.id == conversation.turns.last?.id)
                        }
                        Color.clear.frame(height: 1)
                            .id(ScrollTarget.latest)
                            .onAppear { followsLatest = true }
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in followsLatest = false })
                .onChange(of: session.conversationID) {
                    followsLatest = true
                    proxy.scrollTo(ScrollTarget.latest, anchor: .bottom)
                }
                .onChange(of: session.pendingTurnID) {
                    if session.isRequesting { followsLatest = true }
                    if followsLatest { proxy.scrollTo(ScrollTarget.latest, anchor: .bottom) }
                }
                .onChange(of: session.partialAnswer) {
                    if followsLatest { proxy.scrollTo(ScrollTarget.latest, anchor: .bottom) }
                }
            }
        } else {
            ContentUnavailableView("问问这段文字", systemImage: "text.bubble")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func turnView(_ turn: ReaderAskAITurn, latest: Bool) -> some View {
        let pending = turn.id == session.pendingTurnID
        let answer = pending ? session.partialAnswer : turn.answer
        return VStack(spacing: 10) {
            bubble(isQuestion: true) {
                Text(turn.question)
                    .textSelection(.enabled)
                    .contextMenu { copyButton(turn.question) }
                if !turn.context.excerpt.isEmpty, turn.context.excerpt != session.context.excerpt {
                    DisclosureGroup(turn.context.chapterTitle.isEmpty ? "当时的选文" : turn.context.chapterTitle) {
                        Text(turn.context.excerpt)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.footnote)
                }
            }
            bubble(isQuestion: false) {
                if !answer.isEmpty {
                    (pending ? Text(answer) : answerText(answer))
                        .textSelection(.enabled)
                }
                if pending && answer.isEmpty {
                    ProgressView("正在生成…")
                        .controlSize(.small)
                } else if !pending {
                    if turn.status == .stopped || turn.status == .waiting {
                        Text("生成已停止").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = turn.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    HStack(spacing: 12) {
                        if !answer.isEmpty { copyButton(answer) }
                        if latest {
                            Button(
                                turn.status == .answered ? "重新生成" : "重试",
                                systemImage: "arrow.clockwise"
                            ) { session.retry(turn.id) }
                                .disabled(session.isRequesting || session.destination == nil)
                        }
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func bubble<Content: View>(isQuestion: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isQuestion ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 15))
            .frame(maxWidth: .infinity, alignment: isQuestion ? .trailing : .leading)
            .padding(isQuestion ? .leading : .trailing, 28)
    }

    private func answerText(_ answer: String) -> Text {
        if let rendered = try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(rendered)
        }
        return Text(answer)
    }

    private func copyButton(_ text: String) -> some View {
        Button("复制", systemImage: "doc.on.doc") {
            #if os(iOS)
            UIPasteboard.general.string = text
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let destination = session.destination {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("问 AI", text: $session.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command), session.hasDraft, !session.isRequesting else {
                                return .ignored
                            }
                            session.send()
                            return .handled
                        }
                    if session.isRequesting {
                        Button("停止", systemImage: "stop.fill", action: session.stop)
                            .buttonStyle(.bordered)
                    } else {
                        Button("发送", systemImage: "arrow.up", action: session.send)
                            .buttonStyle(.borderedProminent)
                            .disabled(!session.hasDraft)
                    }
                }
                Text("对话和选文将发送至 \(destination)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label(session.settingsError ?? "请配置可用的问 AI 模型。", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("配置 AI 服务", systemImage: "gearshape") { activeSheet = .settings }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var historyList: some View {
        Group {
            if session.history.conversations.isEmpty {
                ContentUnavailableView("本书暂无问 AI 历史", systemImage: "clock.arrow.circlepath")
            } else {
                List {
                    ForEach(session.history.conversations) { conversation in
                        Button {
                            session.openConversation(conversation.id)
                            followsLatest = true
                            showsHistory = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(conversation.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    if !conversation.chapterTitle.isEmpty {
                                        Text(conversation.chapterTitle).lineLimit(1)
                                    }
                                    Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute())
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { session.deleteConversation(conversation.id) }
                        }
                        .contextMenu {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                session.deleteConversation(conversation.id)
                            }
                        }
                    }
                    Button("清空本书历史", role: .destructive) { confirmsClear = true }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum ScrollTarget { case latest }

    private enum PanelSheet: Identifiable {
        case settings, skills

        var id: Self { self }
    }
}

private struct ReaderAskAISkillPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String>
    let skills: [ReaderAISkill]
    let apply: (Set<String>) -> Void

    init(skills: [ReaderAISkill], selection: Set<String>, apply: @escaping (Set<String>) -> Void) {
        self.skills = skills
        self.apply = apply
        _selection = State(initialValue: selection)
    }

    var body: some View {
        NavigationStack {
            Group {
                if skills.isEmpty {
                    ContentUnavailableView(
                        "没有可用 Skill", systemImage: "list.bullet.rectangle",
                        description: Text("请在 AI 设置中导入或启用 Skill。")
                    )
                } else {
                    List {
                        Section {
                            ForEach(skills) { skill in
                                Toggle(isOn: Binding {
                                    selection.contains(skill.id)
                                } set: { isSelected in
                                    if isSelected { selection.insert(skill.id) }
                                    else { selection.remove(skill.id) }
                                }) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(skill.name.isEmpty ? "Skill" : skill.name)
                                        if !skill.description.isEmpty {
                                            Text(skill.description)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        } footer: {
                            Text("所选 Skill 只用于当前问 AI 窗口。")
                        }
                        Button("清空选择", role: .destructive) {
                            apply([])
                            dismiss()
                        }
                        .disabled(selection.isEmpty)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("当前窗口 Skill")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        apply(selection)
                        dismiss()
                    }
                }
            }
        }
    }
}
