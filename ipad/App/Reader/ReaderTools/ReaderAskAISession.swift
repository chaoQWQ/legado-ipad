import Foundation
import SwiftUI

@MainActor
final class ReaderAskAISession: ObservableObject {
    @Published private(set) var history = ReaderAskAIHistory()
    @Published private(set) var conversationID: UUID?
    @Published private(set) var choice: ReaderAIModelChoice?
    @Published private(set) var choices: [ReaderAIModelChoice] = []
    @Published private(set) var historyError: String?
    @Published private(set) var settingsError: String?
    @Published private(set) var partialAnswer = ""
    @Published private(set) var pendingTurnID: UUID?
    @Published var draft: String

    private let bookID: UUID
    let context: ReaderAskAIContext
    private var askPrompt = ""
    private var operation: Task<Void, Never>?
    private var requestID: UUID?
    private var loaded = false

    init(bookID: UUID, context: ReaderAskAIContext) {
        self.bookID = bookID
        self.context = context
        self.draft = context.excerpt.isEmpty ? "" : ReaderAskAIContext.defaultQuestion
    }

    var conversation: ReaderAskAIConversation? { history.conversation(conversationID) }
    var isRequesting: Bool { pendingTurnID != nil }
    var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var destination: String? {
        guard let provider = choice?.provider else { return nil }
        return try? ReaderAIEndpoint.make(provider.address, route: provider.apiMode.route).host
    }

    func load() {
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
                ?? (settings.enabled ? settings.defaultQuestionChoice : nil)
            let prompt = settings.askPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            askPrompt = prompt.isEmpty ? ReaderAISettings.defaultAskPrompt : prompt
            settingsError = settings.enabled ? nil : "请在 AI 设置中启用 AI。"
        } catch {
            choice = nil
            choices = []
            settingsError = error.localizedDescription
        }
    }

    func choose(_ model: ReaderAIModelChoice) {
        guard !isRequesting else { return }
        choice = model
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
        changeHistory { $0.currentID = nil }
        conversationID = nil
        draft = context.excerpt.isEmpty ? "" : ReaderAskAIContext.defaultQuestion
    }

    func openConversation(_ id: UUID) {
        guard id != conversationID else { return }
        stop()
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
        changeHistory { $0 = ReaderAskAIHistory() }
        conversationID = nil
    }

    private func request(turnID: UUID, using choice: ReaderAIModelChoice) {
        guard let conversation, conversation.turns.last?.id == turnID else { return }
        let messages = conversation.requestMessages(prompt: askPrompt)
        let requestID = UUID()
        self.requestID = requestID
        pendingTurnID = turnID
        operation = Task { [weak self] in
            do {
                let answer = try await ReaderAIClient.chat(messages: messages, using: choice) { delta in
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
