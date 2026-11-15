import Foundation
import SwiftUI

@MainActor
final class ReaderAskAISession: ObservableObject {
    struct ToolActivity {
        private struct Event {
            let callID: String
            var step: ReaderAskAIToolTrace.Step
        }

        private(set) var count = 0
        private var events: [Event] = []

        var trace: ReaderAskAIToolTrace? {
            guard count > 0 else { return nil }
            return ReaderAskAIToolTrace(count: count, steps: events.map(\.step))
        }

        mutating func call(id: String, name: String, arguments: String?) {
            count += 1
            if events.count == 64 { events.removeFirst() }
            let step = ReaderAskAIToolTrace.Step(id: UUID(), name: name, argumentsPreview: arguments, status: .running)
            events.append(Event(callID: id, step: step))
        }

        mutating func retry(id: String, attempt: Int) {
            guard let index = events.lastIndex(where: { $0.callID == id && $0.step.status == .running }) else { return }
            events[index].step.attempts = attempt
        }

        mutating func complete(id: String, succeeded: Bool, resultPreview: String?) {
            guard let index = events.lastIndex(where: { $0.callID == id && $0.step.status == .running }) else { return }
            events[index].step.status = succeeded ? .succeeded : .failed
            events[index].step.resultPreview = resultPreview
        }

        mutating func interruptPending() {
            for index in events.indices where events[index].step.status == .running {
                events[index].step.status = .interrupted
            }
        }
    }

    @Published private(set) var history = ReaderAskAIHistory()
    @Published private(set) var conversationID: UUID?
    @Published private(set) var choice: ReaderAIModelChoice?
    @Published private(set) var choices: [ReaderAIModelChoice] = []
    @Published private(set) var availableSkills: [ReaderAISkill] = []
    @Published private(set) var selectedSkillIDs: Set<String> = []
    @Published private(set) var availableMCPServers: [ReaderAIMCPServer] = []
    @Published private(set) var selectedMCPIDs: Set<String> = []
    @Published private(set) var returnToSend = true
    @Published private(set) var showsThinkingToolbar = true
    @Published private(set) var toolActivity = ToolActivity()
    @Published private(set) var historyError: String?
    @Published private(set) var settingsError: String?
    @Published private(set) var partialAnswer = ""
    @Published private(set) var partialReasoning = ""
    @Published private(set) var completedReasoning: [String] = []
    @Published private(set) var pendingTurnID: UUID?
    @Published var draft: String

    private let bookID: UUID
    @Published private(set) var context: ReaderAskAIContext
    let isGeneral: Bool
    private weak var library: LibraryStore?
    private var requestSettings = ReaderAISettings()
    private var operation: Task<Void, Never>?
    private var requestID: UUID?
    private var loaded = false

    init(
        bookID: UUID, context: ReaderAskAIContext, initialSkillIDs: Set<String> = [],
        initialMCPIDs: Set<String> = [], isGeneral: Bool = false
    ) {
        self.bookID = bookID
        self.context = context
        self.isGeneral = isGeneral
        self.draft = context.initialQuestion
        self.selectedSkillIDs = initialSkillIDs
        self.selectedMCPIDs = initialMCPIDs
    }

    var conversation: ReaderAskAIConversation? { history.conversation(conversationID) }
    var isRequesting: Bool { pendingTurnID != nil }
    var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var destination: String? {
        guard let provider = choice?.provider else { return nil }
        return try? ReaderAIEndpoint.make(provider.address, route: provider.apiMode.route).host
    }

    func load(library: LibraryStore? = nil) {
        self.library = library
        guard !loaded else { return }
        loaded = true
        do {
            history = try ReaderAskAIHistory.load(for: bookID)
            conversationID = history.conversation(history.currentID)?.id
            if !isGeneral && conversationID == nil {
                if let latest = history.conversations.first {
                    changeHistory { $0.currentID = latest.id }
                    conversationID = latest.id
                } else {
                    newConversation(keepsDraft: true)
                }
            }
        } catch {
            historyError = "无法打开本书的问 AI 历史。此面板的对话将临时保留。"
        }
        reloadSettings()
        if !context.excerpt.aiTrimmed.isEmpty { send() }
    }

    func reopen(at context: ReaderAskAIContext) {
        self.context = context
        if !context.initialQuestion.isEmpty && isRequesting { stop() }
        if loaded && !isRequesting { reloadSettings() }
        guard !context.initialQuestion.isEmpty else { return }
        draft = context.initialQuestion
        if loaded { send() }
    }

    func reloadSettings() {
        do {
            let settings = try ReaderAISettings.load()
            requestSettings = settings
            let selectedID = isGeneral ? choice?.id : settings.askModelID
            choices = settings.enabled ? settings.questionChoices : []
            choice = choices.first { $0.id == selectedID }
                ?? (settings.enabled ? (isGeneral ? settings.defaultChatChoice : settings.defaultQuestionChoice) : nil)
            availableSkills = settings.skills.filter(\.enabled)
            selectedSkillIDs.formIntersection(availableSkills.map(\.id))
            availableMCPServers = settings.mcpServers.filter(\.enabled)
            selectedMCPIDs.formIntersection(availableMCPServers.map(\.id))
            returnToSend = settings.returnToSend
            showsThinkingToolbar = settings.showsThinkingToolbar
            settingsError = !settings.enabled ? "请在 AI 设置中启用 AI。"
                : (choice == nil ? "请在 AI 设置中配置问 AI 模型。" : nil)
        } catch {
            choice = nil
            choices = []
            availableSkills = []
            selectedSkillIDs = []
            availableMCPServers = []
            selectedMCPIDs = []
            settingsError = error.localizedDescription
        }
    }

    func choose(_ model: ReaderAIModelChoice) {
        guard !isRequesting else { return }
        if isGeneral {
            choice = model
        } else {
            do {
                var settings = try ReaderAISettings.load()
                settings.askModelID = model.id
                try settings.save()
                choice = model
            } catch {
                settingsError = error.localizedDescription
            }
        }
    }

    func chooseSkills(_ ids: Set<String>) {
        guard !isRequesting else { return }
        selectedSkillIDs = ids.intersection(availableSkills.map(\.id))
    }

    func chooseMCPServers(_ ids: Set<String>) {
        guard !isRequesting else { return }
        selectedMCPIDs = ids.intersection(availableMCPServers.map(\.id))
    }

    func send() {
        guard !isRequesting, let choice, destination != nil else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        let turn = ReaderAskAITurn(question: question, context: context)
        var id = UUID()
        changeHistory { history in
            let existing = history.conversation(conversationID)
            var conversation = existing ?? ReaderAskAIConversation(id: id)
            conversation.turns.append(turn)
            conversation.updatedAt = .now
            history.update(conversation)
            id = conversation.id
            history.currentID = id
        }
        conversationID = id
        request(turnID: turn.id, using: choice)
    }

    func hasRetryContext(for turn: ReaderAskAITurn) -> Bool {
        conversation?.turns.last?.id == turn.id
    }

    func retry(_ turnID: UUID) {
        guard let choice, let conversationID, let turn = conversation?.turns.last,
              turn.id == turnID, hasRetryContext(for: turn), !isRequesting, destination != nil else { return }
        changeHistory { history in
            guard var conversation = history.conversation(conversationID),
                  let index = conversation.turns.indices.last, conversation.turns[index].id == turnID else { return }
            conversation.turns[index].status = .waiting
            conversation.turns[index].answer = ""
            conversation.turns[index].error = nil
            conversation.turns[index].toolTrace = nil
            conversation.turns[index].reasoning = nil
            conversation.updatedAt = .now
            history.update(conversation)
        }
        request(turnID: turnID, using: choice)
    }

    func stop() {
        guard let requestID else { return }
        operation?.cancel()
        finish(requestID: requestID, status: .stopped, answer: partialAnswer)
    }

    func newConversation() {
        newConversation(keepsDraft: false)
    }

    private func newConversation(keepsDraft: Bool) {
        stop()
        toolActivity = .init()
        let conversation = isGeneral ? nil : ReaderAskAIConversation()
        changeHistory { history in
            if let conversation { history.update(conversation) }
            history.currentID = conversation?.id
        }
        conversationID = conversation?.id
        if !keepsDraft { draft = "" }
    }

    func openConversation(_ id: UUID) {
        guard id != conversationID else { return }
        stop()
        toolActivity = .init()
        changeHistory { history in
            if history.conversation(id) != nil { history.currentID = id }
        }
        conversationID = history.conversation(id)?.id
        draft = ""
    }

    func deleteConversation(_ id: UUID) {
        if id == conversationID { stop() }
        changeHistory { history in
            history.conversations.removeAll { $0.id == id }
            if history.currentID == id { history.currentID = history.conversations.first?.id }
        }
        if conversationID == id { conversationID = history.currentID }
    }

    func clearHistory() {
        stop()
        toolActivity = .init()
        changeHistory { $0 = ReaderAskAIHistory() }
        conversationID = nil
    }

    private func request(turnID: UUID, using choice: ReaderAIModelChoice) {
        guard let conversation, let turn = conversation.turns.last, turn.id == turnID else { return }
        let isGeneral = isGeneral
        let settings = requestSettings
        let messages = isGeneral
            ? conversation.requestMessages(prompt: "你是阅读 Archive 的 AI 助手。使用当前窗口可用的工具帮助用户。保留书源草稿在 AI 工作区。")
            : conversation.readingRequestMessages()
        let memory = isGeneral ? nil : ReaderAIMemoryContext(
            bookTitle: turn.context.bookTitle, author: turn.context.author, sessionID: conversation.id
        )
        let activeSkills = availableSkills.filter { selectedSkillIDs.contains($0.id) }
        let servers = availableMCPServers.filter { selectedMCPIDs.contains($0.id) }
        let native = ReaderAINativeTools.selected(
            for: conversation.id, library: library, scope: isGeneral ? .enabled : settings.readToolScope,
            disabled: settings.disabledNativeToolNames ?? [], tavily: settings.tavily
        )
        let requestID = UUID()
        self.requestID = requestID
        pendingTurnID = turnID
        toolActivity = .init()
        completedReasoning = []
        partialReasoning = ""
        operation = Task { [weak self] in
            do {
                let remote = try await ReaderAIMCP.tools(for: servers)
                let tools = native + remote
                let prepared = isGeneral ? messages : try await ReaderAIRequestPreparation.prepare(
                    messages: messages, settings: settings, tools: tools, skills: activeSkills, memoryContext: memory
                )
                let answer = try await ReaderAIClient.chat(
                    messages: prepared, using: choice, skills: activeSkills, tools: tools, toolRoundLimit: settings.toolRoundLimit,
                    allowsTextOnlyFallback: isGeneral && servers.isEmpty,
                    includesSkillCatalog: isGeneral, includesToolRoundText: isGeneral,
                    onProgress: { progress in
                        guard let self, self.requestID == requestID else { return }
                        self.updateToolActivity(progress)
                    }
                ) { delta in
                    guard let self, self.requestID == requestID else { return }
                    self.partialAnswer += delta
                }
                if let memory {
                    try? await ReaderAIRequestPreparation.record(answer: answer, messages: messages, memoryContext: memory)
                }
                try Task.checkCancellation()
                self?.finish(requestID: requestID, status: .answered, answer: answer)
            } catch {
                guard let self, self.requestID == requestID else { return }
                if Task.isCancelled {
                    self.finish(requestID: requestID, status: .stopped, answer: self.partialAnswer)
                } else {
                    self.finish(
                        requestID: requestID, status: .failed, answer: self.partialAnswer,
                        error: error.localizedDescription
                    )
                }
            }
        }
    }

    private func updateToolActivity(_ progress: ReaderAIToolProgress) {
        switch progress {
        case .thinking:
            if !isGeneral { partialAnswer = "" }
            finishReasoningRound()
        case .reasoning(let text):
            partialReasoning = String(text.prefix(8_000))
        case .calling(let id, let name, let previewArguments):
            let turn = conversation?.turns.last
            let preview = previewArguments.flatMap {
                ReaderAskAIToolTrace.argumentsPreview($0, context: turn?.context ?? context, question: turn?.question ?? "")
            }
            toolActivity.call(id: id, name: name, arguments: preview)
        case .retrying(let id, let attempt):
            toolActivity.retry(id: id, attempt: attempt)
        case .completed(let id, let succeeded, let resultPreview):
            toolActivity.complete(id: id, succeeded: succeeded, resultPreview: resultPreview)
        }
    }

    private func finishReasoningRound() {
        if !partialReasoning.aiTrimmed.isEmpty {
            completedReasoning = Array((completedReasoning + [partialReasoning]).suffix(12))
        }
        partialReasoning = ""
    }

    private func finish(requestID: UUID, status: ReaderAskAITurn.Status, answer: String, error: String? = nil) {
        guard self.requestID == requestID, let turnID = pendingTurnID, let conversationID else { return }
        toolActivity.interruptPending()
        let trace = toolActivity.trace
        finishReasoningRound()
        let reasoning = completedReasoning
        changeHistory { history in
            guard var conversation = history.conversation(conversationID),
                  let index = conversation.turns.firstIndex(where: { $0.id == turnID }) else { return }
            conversation.turns[index].answer = answer
            conversation.turns[index].status = status
            conversation.turns[index].error = error
            conversation.turns[index].toolTrace = trace
            conversation.turns[index].reasoning = reasoning.isEmpty ? nil : reasoning
            conversation.updatedAt = .now
            history.update(conversation)
        }
        self.requestID = nil
        pendingTurnID = nil
        partialAnswer = ""
        completedReasoning = []
        operation = nil
    }

    private func changeHistory(_ change: (inout ReaderAskAIHistory) -> Void) {
        if historyError != nil {
            change(&history)
            return
        }
        do {
            var latest = try ReaderAskAIHistory.load(for: bookID)
            change(&latest)
            try latest.save(for: bookID)
            history = latest
        } catch {
            change(&history)
            historyError = "无法保存本书的问 AI 历史。此面板的后续对话将临时保留。"
        }
    }
}
