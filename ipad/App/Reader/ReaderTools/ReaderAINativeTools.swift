import Foundation

@MainActor
enum ReaderAINativeTools {
    private static let safeWorkspaceNames: Set<String> = [
        "workspace_list_files", "workspace_read_file", "workspace_read_lines", "workspace_read_matches",
        "workspace_search_files", "workspace_list_backups", "workspace_diff_file", "workspace_import_book_source",
        "workspace_debug_book_source"
    ]

    static func catalog(
        for conversationID: UUID, library: LibraryStore? = nil, tavily: ReaderAITavilyConfig = .init()
    ) -> [ReaderAITool] {
        let source = ReaderAIBookSourceTools.tools(sources: library?.sources ?? [])
        let workspaceDebugger = source.first { $0.name == "debug_book_source" }.map {
            workspaceDebug($0, for: conversationID)
        }
        return ReaderAILibraryTools.tools(library: library) + source
            + ReaderAIWorkspace.tools(for: conversationID)
            + (workspaceDebugger.map { [$0] } ?? [])
            + (ReaderAITavily.tool(for: tavily).map { [$0] } ?? [])
    }

    static func selected(
        for conversationID: UUID, library: LibraryStore?, scope: ReaderAIToolScope, disabled: Set<String>,
        tavily: ReaderAITavilyConfig = .init()
    ) -> [ReaderAITool] {
        catalog(for: conversationID, library: library, tavily: tavily).filter { tool in
            switch scope {
            case .enabled: return !disabled.contains(tool.name)
            case .safe: return ReaderAILibraryTools.names.contains(tool.name) || safeWorkspaceNames.contains(tool.name)
            case .all: return true
            }
        }
    }

    static func group(_ name: String) -> String {
        if name.hasPrefix("workspace_") { return "AI 工作区" }
        if name == "list_book_characters" { return "角色资料" }
        if ReaderAILibraryTools.names.contains(name) { return "书架与正文" }
        if name == "search_web_tavily" { return "联网工具" }
        return "书源"
    }

    private static func workspaceDebug(_ engine: ReaderAITool, for conversationID: UUID) -> ReaderAITool {
        var schema = engine.parameters
        var properties = schema["properties"] as? [String: Any] ?? [:]
        properties.removeValue(forKey: "sourceJson")
        properties.removeValue(forKey: "bookSourceUrl")
        properties["path"] = ["type": "string", "description": "当前 AI 工作区里的书源 JSON 文件路径。"]
        schema["properties"] = properties
        schema["required"] = ["path", "fixtures", "key"]
        return ReaderAITool(name: "workspace_debug_book_source", description: "用提供的页面样本检查 AI 工作区内的书源。", parameters: schema) { raw in
            guard var payload = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  let path = payload.removeValue(forKey: "path") as? String else {
                return ReaderAITool.failure("请提供工作区文件路径。")
            }
            payload["sourceJson"] = try await ReaderAIWorkspace.shared.document(for: conversationID, path: path)
            return try await engine.invoke(ReaderAITool.json(payload))
        }
    }
}
