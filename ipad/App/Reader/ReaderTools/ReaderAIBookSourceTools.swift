import BookSources
import Foundation

enum ReaderAIBookSourceTools {
    static func tools(sources: [BookSource] = []) -> [ReaderAITool] {
        let source = string("完整的 Legado 书源 JSON。")
        let sourceURL = string("已授权书源的地址，或 list_book_sources 返回的 sourceRef。")
        let samples: [String: Any] = [
            "type": "object",
            "description": "用户提供的 HTML 或 JSON，键为完整请求地址，值为页面文本。包括需要测试的分页。",
            "additionalProperties": ["type": "string"]
        ]
        let query = string("要查找的书源规则或功能，如 CSS、JSONPath、XPath、POST、正则。")
        let limit: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 30]
        let savedSources = sources.enumerated().map { SavedSource(reference: "source-\($0.offset + 1)", source: $0.element) }
        return [
            tool("get_book_source_help", "查询 iPad 支持的书源语法和离线测试说明。", ["query": query]) {
                help($0)
            },
            tool("search_knowledge", "查询内置 iPad 书源语法说明。", ["query": query]) {
                help($0)
            },
            tool("get_css_selector_rules", "查看内置 CSS 书源规则示例。", [:]) { _ in
                help(["query": "CSS"])
            },
            tool("get_book_source_templates", "获取虚构站点的示例书源 JSON 和可离线重放的页面样本。", [:]) { _ in
                ["templates": [["source": template, "fixtures": templateFixtures, "keyword": "示例"]]]
            },
            tool("list_book_sources", "列出授权的本地书源名称、分组和引用。", [
                "keyword": string("筛选名称、分组或地址。"),
                "sourceGroup": string("筛选分组名称。"),
                "enabledOnly": ["type": "boolean"], "limit": limit
            ]) { args in
                ["sources": list(args, in: savedSources).map(\.summary)]
            },
            tool("get_book_source", "读取授权书源的正文、目录、详情和搜索规则摘要；敏感配置会省略。", [
                "bookSourceUrl": sourceURL, "searchKey": string("按名称、分组或地址查找书源。"), "limit": limit
            ]) { args in
                let selected = text("bookSourceUrl", in: args).map { address in
                    savedSources.filter { $0.matches(address) }
                } ?? list(["keyword": args["searchKey"] ?? "", "enabledOnly": false, "limit": args["limit"] ?? 3], in: savedSources)
                return ["sources": selected.prefix(5).map(\.details)]
            },
            tool("create_book_source", "验证并预览书源 JSON 草稿。结果由用户检查并自行导入。", [
                "sourceJson": source, "bookSourceUrl": string("草稿书源地址。"), "bookSourceName": string("草稿书源名称。"),
                "bookSourceGroup": string("草稿书源分组。"), "searchUrl": string("搜索链接规则。"),
                "ruleSearch": object, "ruleBookInfo": object, "ruleToc": object, "ruleContent": object
            ]) { args in
                let draft: String
                if let input = text("sourceJson", in: args) {
                    draft = input
                } else if args.isEmpty {
                    draft = try ReaderAITool.json(template)
                } else {
                    draft = try ReaderAITool.json(args)
                }
                let decoded = try decode(draft)
                if args.isEmpty {
                    return ["saved": false, "source": template, "issues": BookSourceOfflinePreview.configurationIssues(in: decoded)]
                }
                return ["saved": false, "draft": SavedSource(reference: "draft", source: decoded).details]
            },
            tool("validate_book_source", "离线检查 Legado 书源 JSON 能否导入并核对基本配置。", ["sourceJson": source], required: ["sourceJson"]) { args in
                let decoded = try sourceFor(args, from: [])
                return ["importable": true, "issues": BookSourceOfflinePreview.configurationIssues(in: decoded)]
            },
            tool("debug_book_source", "使用用户提供的页面样本测试搜索、详情、目录或正文规则。", [
                "sourceJson": source, "bookSourceUrl": sourceURL, "fixtures": samples,
                "key": string("搜索关键词；绝对 URL 表示详情；++URL 表示目录；--URL 表示正文。")
            ], required: ["fixtures", "key"]) { args in
                let selected = try sourceFor(args, from: savedSources)
                let runner = try preview(args)
                guard let key = text("key", in: args) else { throw ToolError.missingKey }
                if key.hasPrefix("++") {
                    let chapters = try await runner.chapters(at: pageURL(String(key.dropFirst(2))), in: selected)
                    return [
                        "stage": "toc", "count": chapters.count,
                        "chapters": chapters.prefix(15).map { ["title": clipped($0.title), "url": safeAddress($0.url)] }
                    ]
                }
                if key.hasPrefix("--") {
                    let content = try await runner.content(at: pageURL(String(key.dropFirst(2))), in: selected)
                    return ["stage": "content", "content": String(content.prefix(5_000)), "truncated": content.count > 5_000]
                }
                if key.lowercased().hasPrefix("http://") || key.lowercased().hasPrefix("https://") {
                    let details = try await runner.details(at: pageURL(key), in: selected)
                    return ["stage": "details", "book": bookSummary(details)]
                }
                return try await search(key, in: selected, using: runner)
            },
            tool("search_book_source", "用用户提供的页面样本离线重放文本书源搜索。", [
                "sourceJson": source, "sourceUrl": sourceURL, "fixtures": samples, "keyword": string("搜索关键词。")
            ], required: ["fixtures", "keyword"]) { args in
                guard let keyword = text("keyword", in: args) else { throw ToolError.missingKey }
                return try await search(keyword, in: sourceFor(args, from: savedSources), using: preview(args))
            }
        ]
    }

    private static func tool(
        _ name: String, _ description: String, _ properties: [String: Any], required: [String] = [],
        invoke: @escaping ([String: Any]) async throws -> [String: Any]
    ) -> ReaderAITool {
        var parameters: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { parameters["required"] = required }
        return ReaderAITool(name: name, description: description, parameters: parameters) { raw in
            guard raw.utf8.count <= 512 * 1024,
                  let arguments = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  arguments.keys.allSatisfy({ properties[$0] != nil }) else {
                return ReaderAITool.failure("工具参数无效或过大。")
            }
            do {
                var result = try await invoke(arguments)
                result["ok"] = true
                return try ReaderAITool.json(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return ReaderAITool.failure(error.localizedDescription)
            }
        }
    }

    private static func sourceFor(_ args: [String: Any], from sources: [SavedSource]) throws -> BookSource {
        if let draft = text("sourceJson", in: args) { return try decode(draft) }
        if let address = text("bookSourceUrl", in: args) ?? text("sourceUrl", in: args) {
            let matched = sources.filter { $0.matches(address) }
            if matched.count == 1, let source = matched.first?.source { return source }
        }
        throw ToolError.missingSource
    }

    private static func decode(_ draft: String) throws -> BookSource {
        guard draft.utf8.count <= 32 * 1024 else { throw ToolError.largeSource }
        let decoded = try BookSourceImport.decode(Data(draft.utf8))
        guard decoded.count == 1, let source = decoded.first else { throw ToolError.singleSource }
        return source
    }

    private static func preview(_ args: [String: Any]) throws -> BookSourceOfflinePreview {
        try BookSourceOfflinePreview(pages: args["fixtures"] as? [String: String] ?? [:])
    }

    private static func pageURL(_ address: String) throws -> URL {
        guard let url = URL(string: address.aiTrimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw ToolError.invalidURL }
        return url
    }

    private static func search(
        _ keyword: String, in source: BookSource, using runner: BookSourceOfflinePreview
    ) async throws -> [String: Any] {
        let found = try await runner.search(keyword, in: source)
        return ["stage": "search", "count": found.count, "books": found.prefix(15).map(bookSummary)]
    }

    private static func bookSummary(_ book: SourceBook) -> [String: String] {
        var output = ["title": clipped(book.title), "author": clipped(book.author), "url": safeAddress(book.bookURL)]
        if let toc = book.tocURL { output["tocUrl"] = safeAddress(toc) }
        return output
    }

    private static func list(_ args: [String: Any], in sources: [SavedSource]) -> [SavedSource] {
        let keyword = text("keyword", in: args)
        let group = text("sourceGroup", in: args)
        let enabledOnly = args["enabledOnly"] as? Bool ?? true
        let limit = min(30, max(1, args["limit"] as? Int ?? 10))
        return Array(sources.lazy.filter { record in
            let source = record.source
            guard !enabledOnly || source.isEnabled else { return false }
            if let group, source.group?.localizedStandardContains(group) != true { return false }
            guard let keyword else { return true }
            return [source.name, source.group ?? "", safeAddress(source.baseURL)].contains {
                $0.localizedStandardContains(keyword)
            }
        }.prefix(limit))
    }

    private struct SavedSource {
        let reference: String
        let source: BookSource

        func matches(_ value: String) -> Bool {
            value == reference || value == safeAddress(source.baseURL)
        }

        var summary: [String: Any] {
            [
                "sourceRef": reference, "bookSourceName": clipped(source.name), "bookSourceUrl": safeAddress(source.baseURL),
                "bookSourceGroup": clipped(source.group ?? ""), "enabled": source.isEnabled, "canSearch": source.canSearch
            ]
        }

        var details: [String: Any] {
            var output = summary
            let fields: [String: [String]] = [
                "ruleSearch": ["bookList", "name", "author", "intro", "coverUrl", "bookUrl"],
                "ruleBookInfo": ["init", "name", "author", "intro", "coverUrl", "tocUrl"],
                "ruleToc": ["chapterList", "chapterName", "chapterUrl", "nextTocUrl"],
                "ruleContent": ["content", "subContent", "nextContentUrl"]
            ]
            if let data = try? JSONEncoder().encode(source),
               let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for (rule, allowed) in fields {
                    let section = dictionary(document[rule])
                    let values = allowed.reduce(into: [String: String]()) { results, field in
                        if let selector = section[field] as? String, isShareableSelector(selector) {
                            results[field] = selector
                        }
                    }
                    if !values.isEmpty { output[rule] = values }
                }
            }
            output["issues"] = BookSourceOfflinePreview.configurationIssues(in: source)
            return output
        }
    }

    private static func dictionary(_ raw: Any?) -> [String: Any] {
        if let value = raw as? [String: Any] { return value }
        guard let text = raw as? String else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private static func isShareableSelector(_ selector: String) -> Bool {
        let value = selector.aiTrimmed.lowercased()
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return !["://", "{{", "##", "<js", "@js:", "@webjs:", "@get:", "@put:", "authorization", "cookie",
                 "password", "secret", "token", "api-key", "apikey", "api_key"].contains(where: value.contains)
    }

    private static func safeAddress(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        return clipped(parts.string ?? "")
    }

    private static func clipped(_ value: String) -> String { String(value.prefix(220)) }

    private static func text(_ key: String, in args: [String: Any]) -> String? {
        guard let text = (args[key] as? String)?.aiTrimmed, !text.isEmpty else { return nil }
        return text
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static let object: [String: Any] = ["type": "object", "additionalProperties": ["type": "string"]]

    private static func help(_ args: [String: Any]) -> [String: Any] {
        let guidance: [String: String] = [
            "JSON 结构": "bookSourceUrl 和 bookSourceName 是必填字段。用 searchUrl、ruleSearch、ruleBookInfo、ruleToc、ruleContent 分别定义入口、搜索、详情、目录和正文。",
            "CSS": "@css:.books li 选择列表元素，@css:a@text 提取标题，@css:a@href 提取链接。列表节点内的规则相对当前元素。",
            "XPath": "@xpath://div[@id='content'] 选择元素，@xpath:.//a/@href 从当前节点找链接。",
            "JSONPath": "@json:$.data.books[*] 选择数组，@json:$.title 读取结果中的标题。",
            "GET / POST": "搜索地址可用 {{key}} 和 {{page}}。POST 用相对地址后追加逗号和 JSON 选项，例如 /search,{\"method\":\"POST\",\"body\":\"q={{key}}\"}。",
            "正则": "正文清理格式为 ##正则##替换。测试时提供包含待清理内容的正文样本，核对输出。",
            "离线验证": "先 validate_book_source 检查基本配置，再用 debug_book_source 传入完整地址与页面样本。样本匹配完整请求地址，测试经过 iPad 实际书源解析器。",
            "边界": "本工具只处理本地配置或提供的样本。iPad 的书源解析支持文本、CSS、XPath、JSONPath、GET/POST 和常见替换规则。"
        ]
        let query = text("query", in: args)
        let matched = query.map { words in guidance.filter { words.localizedStandardContains($0.key) } } ?? [:]
        return ["platform": "Legado iPad", "guidance": matched.isEmpty ? guidance : matched]
    }

    private static let template: [String: Any] = [
        "bookSourceUrl": "https://books.example.invalid", "bookSourceName": "示例书源",
        "bookSourceType": 0, "enabledCookieJar": false, "searchUrl": "/search?q={{key}}",
        "ruleSearch": ["bookList": "@css:.results li", "name": "@css:a@text", "bookUrl": "@css:a@href"],
        "ruleBookInfo": ["name": "@css:h1@text", "tocUrl": "@css:#toc@href"],
        "ruleToc": ["chapterList": "@css:.chapters li", "chapterName": "@css:a@text", "chapterUrl": "@css:a@href"],
        "ruleContent": ["content": "@css:.chapter@html"]
    ]

    private static let templateFixtures = [
        "https://books.example.invalid/search?q=%E7%A4%BA%E4%BE%8B": #"<ul class="results"><li><a href="/book">示例小说</a></li></ul>"#,
        "https://books.example.invalid/book": #"<h1>示例小说</h1><a id="toc" href="/chapters">目录</a>"#,
        "https://books.example.invalid/chapters": #"<ul class="chapters"><li><a href="/chapter">第一章</a></li></ul>"#,
        "https://books.example.invalid/chapter": #"<div class="chapter"><p>这一段是离线测试的正文。</p></div>"#
    ]

    private enum ToolError: LocalizedError {
        case missingSource, missingKey, largeSource, singleSource, invalidURL

        var errorDescription: String? {
            switch self {
            case .missingSource: "请提供书源 JSON，或指定唯一的已授权书源引用。"
            case .missingKey: "请提供搜索关键词或待验证的页面地址。"
            case .largeSource: "待验证的书源 JSON 超过 32 KiB。"
            case .singleSource: "单次测试需要一个书源。"
            case .invalidURL: "请提供有效的 HTTP(S) 页面地址。"
            }
        }
    }
}
