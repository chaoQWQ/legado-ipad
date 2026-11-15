import Foundation
import SwiftUI

@MainActor
final class ReaderAskAISession: ObservableObject {
    struct ToolActivity: Identifiable {
        let id: String
        let callID: String
        let name: String
        var succeeded: Bool?
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
    @Published private(set) var toolActivity: [ToolActivity] = []
    @Published private(set) var historyError: String?
    @Published private(set) var settingsError: String?
    @Published private(set) var partialAnswer = ""
    @Published private(set) var pendingTurnID: UUID?
    @Published var draft: String

    private let bookID: UUID
    let context: ReaderAskAIContext
    let isGeneral: Bool
    private weak var library: LibraryStore?
    private var askPrompt = ""
    private var toolRoundLimit = 32
    private var readToolScope = ReaderAIToolScope.enabled
    private var disabledNativeTools: Set<String> = []
    private var tavily = ReaderAITavilyConfig()
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
        self.draft = context.excerpt.isEmpty ? "" : ReaderAskAIContext.defaultQuestion
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
        } catch {
            historyError = "无法打开本书的问 AI 历史。此面板的对话将临时保留。"
        }
        reloadSettings()
        if !context.excerpt.aiTrimmed.isEmpty { send() }
    }

    func reloadSettings() {
        do {
            let settings = try ReaderAISettings.load()
            let selectedID = choice?.id
            choices = settings.enabled ? settings.questionChoices : []
            choice = choices.first { $0.id == selectedID }
                ?? (settings.enabled ? (isGeneral ? settings.defaultChatChoice : settings.defaultQuestionChoice) : nil)
            availableSkills = settings.skills.filter(\.enabled)
            selectedSkillIDs.formIntersection(availableSkills.map(\.id))
            availableMCPServers = settings.mcpServers.filter(\.enabled)
            selectedMCPIDs.formIntersection(availableMCPServers.map(\.id))
            toolRoundLimit = settings.toolRoundLimit
            readToolScope = settings.readToolScope
            disabledNativeTools = settings.disabledNativeToolNames ?? []
            tavily = settings.tavily
            returnToSend = settings.returnToSend
            showsThinkingToolbar = settings.showsThinkingToolbar
            let prompt = settings.askPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            askPrompt = isGeneral
                ? "你是阅读 Archive 的 AI 助手。使用当前窗口可用的工具帮助用户。保留书源草稿在 AI 工作区。"
                : (prompt.isEmpty ? ReaderAISettings.defaultAskPrompt : prompt)
            settingsError = settings.enabled ? nil : "请在 AI 设置中启用 AI。"
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
        choice = model
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
            var conversation = history.conversation(conversationID) ?? ReaderAskAIConversation(id: id)
            conversation.turns.append(turn)
            conversation.updatedAt = .now
            history.update(conversation)
            id = conversation.id
            history.currentID = id
        }
        conversationID = id
        request(turnID: turn.id, using: choice)
    }

    func retry(_ turnID: UUID) {
        guard !isRequesting, let choice, destination != nil, let conversationID,
              conversation?.turns.last?.id == turnID else { return }
        changeHistory { history in
            guard var conversation = history.conversation(conversationID),
                  let index = conversation.turns.indices.last, conversation.turns[index].id == turnID else { return }
            conversation.turns[index].status = .waiting
            conversation.turns[index].answer = ""
            conversation.turns[index].error = nil
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
        stop()
        toolActivity = []
        changeHistory { $0.currentID = nil }
        conversationID = nil
        draft = context.excerpt.isEmpty ? "" : ReaderAskAIContext.defaultQuestion
    }

    func openConversation(_ id: UUID) {
        guard id != conversationID else { return }
        stop()
        toolActivity = []
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
        toolActivity = []
        changeHistory { $0 = ReaderAskAIHistory() }
        conversationID = nil
    }

    private func request(turnID: UUID, using choice: ReaderAIModelChoice) {
        guard let conversation, conversation.turns.last?.id == turnID else { return }
        let messages = conversation.requestMessages(prompt: askPrompt)
        let activeSkills = availableSkills.filter { selectedSkillIDs.contains($0.id) }
        let servers = availableMCPServers.filter { selectedMCPIDs.contains($0.id) }
        let native = ReaderAINativeTools.selected(
            for: conversation.id, library: library, scope: isGeneral ? .enabled : readToolScope,
            disabled: disabledNativeTools, tavily: tavily
        )
        let limit = toolRoundLimit
        let requestID = UUID()
        self.requestID = requestID
        pendingTurnID = turnID
        toolActivity = []
        operation = Task { [weak self] in
            do {
                let remote = try await ReaderAIMCP.tools(for: servers)
                let answer = try await ReaderAIClient.chat(
                    messages: messages, using: choice, skills: activeSkills, tools: native + remote, toolRoundLimit: limit,
                    allowsTextOnlyFallback: servers.isEmpty,
                    onProgress: { progress in
                        guard let self, self.requestID == requestID else { return }
                        self.updateToolActivity(progress)
                    }
                ) { delta in
                    guard let self, self.requestID == requestID else { return }
                    self.partialAnswer += delta
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
        case .thinking: break
        case .calling(let id, let name):
            toolActivity.append(.init(id: UUID().uuidString, callID: id, name: name))
        case .completed(let id, let succeeded):
            guard let index = toolActivity.lastIndex(where: { $0.callID == id && $0.succeeded == nil }) else { return }
            toolActivity[index].succeeded = succeeded
        }
    }

    private func finish(requestID: UUID, status: ReaderAskAITurn.Status, answer: String, error: String? = nil) {
        guard self.requestID == requestID, let turnID = pendingTurnID, let conversationID else { return }
        changeHistory { history in
            guard var conversation = history.conversation(conversationID),
                  let index = conversation.turns.firstIndex(where: { $0.id == turnID }) else { return }
            conversation.turns[index].answer = answer
            conversation.turns[index].status = status
            conversation.turns[index].error = error
            conversation.updatedAt = .now
            history.update(conversation)
        }
        self.requestID = nil
        pendingTurnID = nil
        partialAnswer = ""
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
