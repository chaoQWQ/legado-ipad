import Foundation

enum ReaderAIRequestPreparation {
    static func prepare(
        messages: [ReaderAIChatMessage], settings: ReaderAISettings, tools: [ReaderAITool],
        skills: [ReaderAISkill] = [], memoryContext: ReaderAIMemoryContext? = nil
    ) async throws -> [ReaderAIChatMessage] {
        let clean = messages.filter { !$0.content.aiTrimmed.isEmpty }
        let systemPrompt = systemPrompt(settings: settings, context: memoryContext)
        let skillTool = ReaderAISkillTool(skills)
        let skillCatalog = skillTool.skills.isEmpty ? "" : skillTool.catalog
        let definitions = skillTool.skills.isEmpty ? tools : tools + [skillTool.tool]
        let reserve = staticTokens(
            definitions: definitions, systemPrompt: systemPrompt, skillCatalog: skillCatalog,
            requiresLocalData: needsBookshelfTool(in: clean)
        )
        let prepared = compress(clean, enabled: settings.contextCompressionEnabled,
                                limit: settings.contextWindowTokens, reserve: reserve)
        let memory = try await ReaderAIMemoryStore.shared.prompt(for: memoryContext, messages: prepared.messages)
        let world = try await ReaderAIWorldBookStore.shared.injections(for: memoryContext, messages: prepared.messages)
        let plan = actionPlan(for: prepared.messages, hasTools: !definitions.isEmpty)
        let total = reserve + prepared.tokens + estimateTokens(plan) + world.reduce(0) {
            $0 + estimateTokens($1.message.content)
        }
        guard total <= settings.contextWindowTokens else { throw ContextError.overLimit }

        var request = [system(systemPrompt), system(workspacePrompt)]
        request += world.filter { $0.position == .afterSystemPrompt }.map(\.message)
        if !prepared.summary.isEmpty { request.append(system("Conversation summary from earlier context:\n\(prepared.summary)")) }
        if !memory.isEmpty { request.append(system(memory)) }
        if !plan.isEmpty { request.append(system(plan)) }
        if !skillCatalog.isEmpty { request.append(system(skillCatalog)) }
        if needsBookshelfTool(in: prepared.messages) { request.append(system(bookshelfPrompt)) }
        request += world.filter { $0.position == .beforePrompt }.map(\.message)
        request += settings.contextCompressionEnabled ? prepared.messages : Array(prepared.messages.suffix(12))

        let beforeLastUser = world.filter { $0.position == .beforeLastUser }.map(\.message)
        request.insert(contentsOf: beforeLastUser, at: request.lastIndex { $0.role == .user } ?? request.endIndex)
        for entry in world.filter({ $0.position == .injectDepth }).sorted(by: { $0.depth > $1.depth }) {
            request.insert(entry.message, at: max(1, request.count - entry.depth))
        }
        return request
    }

    static func record(answer: String, messages: [ReaderAIChatMessage], memoryContext: ReaderAIMemoryContext?) async throws {
        guard let memoryContext, let question = messages.last(where: { $0.role == .user })?.content else { return }
        try await ReaderAIMemoryStore.shared.record(answer: answer, question: question, context: memoryContext)
    }

    private static func system(_ text: String) -> ReaderAIChatMessage { .init(role: .system, content: text) }

    private static func systemPrompt(settings: ReaderAISettings, context: ReaderAIMemoryContext?) -> String {
        let override = settings.askPrompt.aiTrimmed
        if context?.isBook == true, !override.isEmpty, override != ReaderAISettings.defaultAskPrompt {
            return defaultSystemPrompt + "\n\n" + override
        }
        return defaultSystemPrompt
    }

    private static func needsBookshelfTool(in messages: [ReaderAIChatMessage]) -> Bool {
        guard let latest = messages.last(where: { $0.role == .user })?.content else { return false }
        return ["书架", "书籍", "书名", "作者", "阅读记录", "最近读", "在读", "简介", "书源", "分组", "标签", "分类", "整理", "批量"]
            .contains { latest.localizedCaseInsensitiveContains($0) }
    }

    private static func actionPlan(for messages: [ReaderAIChatMessage], hasTools: Bool) -> String {
        guard let latest = messages.last(where: { $0.role == .user })?.content else { return "" }
        let goal = latest.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).aiTrimmed
        guard !goal.isEmpty else { return "" }
        let readKeywords = ["书架", "书籍", "章节", "阅读记录", "书源", "角色", "配音", "工具", "设置", "查询", "查看", "读取", "搜索", "调试", "生成图片", "生图"]
        let writeKeywords = ["创建", "新增", "修改", "更新", "删除", "移除", "设置", "分配", "导入", "保存", "清空", "批量", "生成头像", "生成图片", "重绘"]
        let needsLocalData = readKeywords.contains { goal.localizedCaseInsensitiveContains($0) }
        let needsWrite = writeKeywords.contains { goal.localizedCaseInsensitiveContains($0) }
        var steps = ["理解用户目标、约束和当前上下文；校验：目标和约束必须在最终回复中被覆盖"]
        if hasTools, needsLocalData {
            steps.append("调用本地工具读取必要数据，不凭空推断；依赖：understand_goal；校验：工具结果必须为 ok=true 或给出明确失败原因")
        }
        if hasTools {
            if needsWrite {
                let dependency = needsLocalData ? "read_local_context" : "understand_goal"
                steps.append("执行创建、修改、删除或批量写入操作；依赖：\(dependency)；校验：写入类工具必须返回 ok=true，并且数量、id 或目标字段可核对")
            } else {
                steps.append("按需调用工具获取事实、生成内容或执行用户请求；依赖：understand_goal；校验：工具结果 JSON 必须完整，失败时先重试或说明限制")
            }
        }
        let lastStep = hasTools ? (needsWrite ? "apply_changes" : "execute_tools") : "understand_goal"
        steps.append("校验工具结果是否满足目标，并检查多步骤任务是否遗漏；依赖：\(lastStep)；校验：校验失败时不要直接给成功结论")
        steps.append("输出简洁结论、结果和必要的风险说明；依赖：validate_result；校验：最终回复必须基于已验证结果")
        let list = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        本轮 Agent 执行计划由客户端生成，用于约束执行顺序：
        目标：\(goal.prefix(1_000))
        \(list)
        最终回复前必须确认：工具结果已满足目标，写入类工具返回 ok=true，多步骤任务没有遗漏；如果校验失败，先重试或说明失败原因。
        """
    }

    private struct Prepared {
        let messages: [ReaderAIChatMessage]
        let summary: String
        var tokens: Int { messages.reduce(0) { $0 + estimateTokens($1.content) + 8 } + estimateTokens(summary) }
    }

    private static func compress(_ messages: [ReaderAIChatMessage], enabled: Bool, limit: Int, reserve: Int) -> Prepared {
        let prepared = Prepared(messages: messages, summary: "")
        guard enabled else { return prepared }
        let available = max(0, limit - reserve)
        if prepared.tokens < available * 90 / 100 { return prepared }

        let recent = Array(messages.suffix(10))
        let old = messages.dropLast(recent.count)
        let summaryBudget = available * 35 / 100
        let summaryLimit = min(32_000, summaryBudget * 3)
        let condensed = old.map { message in
            let role = message.role == .user ? "User" : "Assistant"
            let text = message.content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).aiTrimmed
            return "- \(role): \(text.prefix(900))"
        }.joined(separator: "\n")
        let summary = condensed.isEmpty ? "" : fittingTail(
            String(("Condensed conversation facts:\n" + condensed).suffix(summaryLimit)), tokens: summaryBudget
        )
        let messageBudget = available - estimateTokens(summary)
        var fittedReversed: [ReaderAIChatMessage] = []
        var used = 0
        for message in recent.reversed() {
            let cost = estimateTokens(message.content) + 8
            if cost + used > messageBudget {
                if fittedReversed.isEmpty {
                    let text = fittingTail(message.content, tokens: max(0, messageBudget - 8))
                    if !text.isEmpty { fittedReversed.append(.init(role: message.role, content: text)) }
                }
                break
            }
            used += cost
            fittedReversed.append(message)
        }
        return .init(messages: fittedReversed.reversed(), summary: summary)
    }

    private static func fittingTail(_ text: String, tokens: Int) -> String {
        guard tokens > 0 else { return "" }
        if estimateTokens(text) <= tokens { return text }
        let units = Array(text.utf16)
        var ascii = 0
        var nonASCII = 0
        var count = 0
        for unit in units.reversed() {
            if unit < 128 { ascii += 1 } else { nonASCII += 1 }
            if ascii / 4 + nonASCII + 1 > tokens { break }
            count += 1
        }
        return String(decoding: units.suffix(count), as: UTF16.self).aiTrimmed
    }

    private static func staticTokens(
        definitions: [ReaderAITool], systemPrompt: String, skillCatalog: String, requiresLocalData: Bool
    ) -> Int {
        let toolTokens = definitions.reduce(0) { result, tool in
            let json = (try? ReaderAITool.json(tool.definition(for: .chatCompletions))) ?? tool.description
            return result + estimateTokens(json) + 16
        }
        return estimateTokens(systemPrompt) + estimateTokens(skillCatalog) + toolTokens + (requiresLocalData ? 180 : 0) + 256
    }

    private static func estimateTokens(_ text: String) -> Int {
        guard !text.aiTrimmed.isEmpty else { return 0 }
        let ascii = text.utf16.reduce(0) { $0 + ($1 < 128 ? 1 : 0) }
        return ascii / 4 + text.utf16.count - ascii + 1
    }

    private static let defaultSystemPrompt = """
    你是阅读应用内的 AI 助手。回答直接、准确、简洁。需要真实应用数据时必须优先调用工具，工具返回的数据优先级高于你的记忆，不允许编造工具未返回的结果。用户询问书架、书籍、作者、阅读记录、书籍简介、书源、分组、标签、分类方案时，必须先调用 query_bookshelf、get_bookshelf_book_info、manage_bookshelf_group 或 manage_bookshelf_tag，不要只说“我先看看”却不调用工具。用户要求创建、修改或调试书源时，你要像一个小型书源 agent 一样闭环执行：新建书源先调用 create_book_source(save=false) 生成草稿；修改已有书源先调用 get_book_source 读取完整 JSON；缺少页面结构时调用 fetch_source_html 获取搜索页、详情页、目录页或正文页 HTML；每次调试失败后都调用 update_book_source(save=false) 按日志和 HTML 修正规则，可传 patch，也可直接传 ruleToc/ruleContent/searchUrl 等字段；再调用 debug_book_source 调试，优先使用用户给出的详情页 URL、目录 URL、正文页 URL 或关键词；最多循环 3 次。只有搜索、详情、目录、正文主要链路通过，或达到 3 次仍失败时，才给出最终结果和剩余失败点。只有用户明确要求保存、导入或完成时，才调用 update_book_source(save=true) 或 create_book_source(save=true) 写入本地书源库。用户要求整理书架时，顶层书架使用分组，分组内的小分类使用书籍标签；未分标签的书按“全部”处理。批量设置标签、重命名标签、移动分组或删除分组前，先查询书架并给出方案，用户确认后再调用写入工具。任何情况下都不允许删除书籍。工具返回图片路径时直接展示已有图片；用户只要求查看、展示头像时不要调用生图工具，只有明确要求生成、重绘或重新生成时才生成图片。
    """

    private static let bookshelfPrompt = "本轮用户请求涉及本地书架、书籍详情、阅读记录、分组、标签或书源搜索。回复正文前必须先调用合适的本地工具；不要只说明将要查询。需要选择书源时先调用 list_book_sources。search_book_source 的结果会由客户端自动渲染成可点击卡片，回复里不要生成链接、不要输出内部 URL、不要手写 Markdown 打开链接，只需要用自然语言简短说明搜索结果。"

    private static let workspacePrompt = #"""
    Agent file workflow is mandatory for source, rule, log, JSON, HTML, and project-style edits. If the user provides long data, source text, logs, JSON, HTML, or project snippets, first save it with workspace_save_input_file. Before editing, inspect files with workspace_list_files, workspace_search_files, workspace_read_file, workspace_read_lines, or workspace_read_matches. Before modifying any existing file, proactively call workspace_create_backup, especially before regex replacements, bulk edits, deletes, overwrites, or applying a book source. Make focused changes with the most specific edit tool: workspace_replace_text for plain exact snippets, workspace_replace_regex for rule-like text, escaped quotes, capture groups, or regex patterns, workspace_edit_lines only after workspace_read_lines or workspace_read_matches gives stable line numbers and include expectedText when possible, and workspace_insert_text for additive edits. Use workspace_edit_file only for small batches of already verified replacements. Always set expectMatches for replacement tools and keep backup=true or backup=auto. Never set backup=false unless the user explicitly requests no backup. After editing, call workspace_diff_file with the returned backupId to verify the diff is exactly what was intended before applying a book source or reporting success. Do not pass regex-looking or heavily escaped text as a literal oldText. For regex edits, use workspace_replace_regex with pattern, replacement, flags, expectMatches, and Python replacement syntax like \1, \g<1>, or \g<name>. For Legado book sources, do not use create_book_source or update_book_source for normal modification. Instead import with workspace_import_book_source, create drafts with workspace_create_book_source_file, explicitly back up the workspace file, edit with workspace_edit_file, debug with workspace_debug_book_source, and apply with workspace_apply_book_source only after validation or explicit user request. After destructive or high-risk changes, report the backupId and the edited path. Do not paste full book source JSON in chat unless the user explicitly asks for it.
    """#

    private enum ContextError: LocalizedError {
        case overLimit
        var errorDescription: String? { "当前 AI 配置或对话超过上下文限制。请缩短输入，或在 AI 设置里调整上下文压缩。" }
    }
}
