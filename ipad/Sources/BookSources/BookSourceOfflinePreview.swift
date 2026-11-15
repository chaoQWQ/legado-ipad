import Foundation

/// Runs the normal book source reader against explicit in-memory page samples.
public struct BookSourceOfflinePreview: Sendable {
    private let client: BookSourceClient

    public init(pages: [String: String]) throws {
        guard !pages.isEmpty, pages.count <= 8 else { throw PreviewError.invalidSamples }
        var responses: [String: Data] = [:]
        var totalBytes = 0
        for (address, text) in pages {
            guard let url = URL(string: address), url.isWebURL else { throw PreviewError.invalidSamples }
            totalBytes += text.utf8.count
            guard totalBytes <= 256 * 1024 else { throw PreviewError.invalidSamples }
            responses[url.absoluteString] = Data(text.utf8)
        }
        let samples = responses
        client = BookSourceClient { request, _ in
            try Task.checkCancellation()
            guard let url = request.url, let data = samples[url.absoluteString],
                  let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "text/plain; charset=UTF-8"]
                  ) else {
                throw PreviewError.missingSample
            }
            return (data, response)
        }
    }

    public func search(_ keyword: String, in source: BookSource) async throws -> [SourceBook] {
        try await client.search(keyword, in: source)
    }

    public func details(at url: URL, in source: BookSource) async throws -> SourceBook {
        guard source.infoRule != nil else { throw BookSourceError.missingRule("详情") }
        return try await client.details(for: SourceBook(title: "", bookURL: url, sourceID: source.id), in: source)
    }

    public func chapters(at url: URL, in source: BookSource) async throws -> [SourceChapter] {
        try await client.chapters(for: SourceBook(title: "", bookURL: url, sourceID: source.id), in: source)
    }

    public func content(at url: URL, in source: BookSource) async throws -> String {
        try await client.content(of: SourceChapter(title: "", url: url), in: source)
    }

    /// Checks configuration fields without claiming that a selector matches a real page.
    public static func configurationIssues(in source: BookSource) -> [String] {
        var issues: [String] = []
        if source.type != 0 { issues.append("当前仅支持文本书源。") }
        if source.loginCheck?.nilIfBlank != nil { issues.append("当前不执行登录检测脚本。") }
        if let template = source.searchURL?.nilIfBlank {
            do {
                let request = try SourceRequest.parse(template, relativeTo: source.baseURL, field: "搜索", keyword: "示例")
                _ = try request.request(sourceHeaders: source.headers)
            } catch {
                issues.append("搜索地址或请求配置无效，或包含当前不支持的功能。")
            }
        } else {
            issues.append("尚未配置搜索地址。")
        }
        if source.searchRule?.bookList?.nilIfBlank == nil && source.infoRule?.name?.nilIfBlank == nil {
            issues.append("尚未配置搜索结果列表或直达详情书名。")
        }
        if source.tocRule?.chapterList?.nilIfBlank == nil
            || source.tocRule?.chapterName?.nilIfBlank == nil || source.tocRule?.chapterUrl?.nilIfBlank == nil {
            issues.append("目录规则需要章节列表、章节名和链接。")
        }
        if source.tocRule?.preUpdateJs?.nilIfBlank != nil || source.tocRule?.formatJs?.nilIfBlank != nil {
            issues.append("当前不执行目录脚本。")
        }
        if source.contentRule?.content?.nilIfBlank == nil { issues.append("尚未配置正文规则。") }
        if source.contentRule?.webJs?.nilIfBlank != nil || source.contentRule?.sourceRegex?.nilIfBlank != nil {
            issues.append("当前不处理正文网页渲染或定位脚本。")
        }
        let selectors: [(String, [String?])] = [
            ("搜索", [source.searchRule?.bookList, source.searchRule?.name, source.searchRule?.author,
                     source.searchRule?.intro, source.searchRule?.coverUrl, source.searchRule?.bookUrl]),
            ("详情", [source.infoRule?.`init`, source.infoRule?.name, source.infoRule?.author,
                     source.infoRule?.intro, source.infoRule?.coverUrl, source.infoRule?.tocUrl]),
            ("目录", [source.tocRule?.chapterList, source.tocRule?.chapterName,
                     source.tocRule?.chapterUrl, source.tocRule?.nextTocUrl]),
            ("正文", [source.contentRule?.content, source.contentRule?.subContent, source.contentRule?.nextContentUrl])
        ]
        for (stage, rules) in selectors {
            if rules.compactMap({ $0 }).contains(where: { (try? rejectDynamicRule($0)) == nil }) {
                issues.append("\(stage)规则包含当前不支持的脚本或变量。")
            }
        }
        if (try? applyReplacement(source.contentRule?.replaceRegex, to: "示例")) == nil {
            issues.append("正文替换规则无效，或包含当前不支持的脚本。")
        }
        return issues
    }

    private enum PreviewError: LocalizedError {
        case invalidSamples, missingSample

        var errorDescription: String? {
            switch self {
            case .invalidSamples: "请提供 1 至 8 个有效 HTTP(S) 地址的文本样本，总大小最多 256 KiB。"
            case .missingSample: "请求地址没有匹配的样本。请为展开后的完整地址及任何分页地址提供样本。"
            }
        }
    }
}
