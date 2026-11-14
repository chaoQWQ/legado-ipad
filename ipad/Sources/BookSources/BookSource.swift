import Foundation

public struct BookSource: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let group: String?
    public var isEnabled: Bool
    public let baseURL: URL

    let type: Int
    let searchURL: String?
    let bookURLPattern: String?
    let headers: String?
    let usesCookies: Bool
    let loginCheck: String?
    let searchRule: SearchRule?
    let infoRule: InfoRule?
    let tocRule: TocRule?
    let contentRule: ContentRule?

    public var canSearch: Bool {
        type == 0 && searchURL?.nilIfBlank != nil && (searchRule != nil || infoRule != nil)
    }

    enum CodingKeys: String, CodingKey {
        case id = "bookSourceUrl"
        case name = "bookSourceName"
        case group = "bookSourceGroup"
        case isEnabled = "enabled"
        case type = "bookSourceType"
        case searchURL = "searchUrl"
        case bookURLPattern = "bookUrlPattern"
        case headers = "header"
        case usesCookies = "enabledCookieJar"
        case loginCheck = "loginCheckJs"
        case searchRule = "ruleSearch"
        case infoRule = "ruleBookInfo"
        case tocRule = "ruleToc"
        case contentRule = "ruleContent"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id).trimmed
        name = try values.decode(String.self, forKey: .name).trimmed
        group = try values.decodeIfPresent(String.self, forKey: .group)?.nilIfBlank
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        type = try values.decodeIfPresent(Int.self, forKey: .type) ?? 0
        searchURL = try values.decodeIfPresent(String.self, forKey: .searchURL)
        bookURLPattern = try values.decodeIfPresent(String.self, forKey: .bookURLPattern)
        if let map = try? values.decode([String: String].self, forKey: .headers) {
            headers = String(data: try JSONEncoder().encode(map), encoding: .utf8)
        } else {
            headers = try values.decodeIfPresent(String.self, forKey: .headers)
        }
        usesCookies = try values.decodeIfPresent(Bool.self, forKey: .usesCookies) ?? true
        loginCheck = try values.decodeIfPresent(String.self, forKey: .loginCheck)
        searchRule = try Self.decodeRule(SearchRule.self, from: values, key: .searchRule)
        infoRule = try Self.decodeRule(InfoRule.self, from: values, key: .infoRule)
        tocRule = try Self.decodeRule(TocRule.self, from: values, key: .tocRule)
        contentRule = try Self.decodeRule(ContentRule.self, from: values, key: .contentRule)

        guard !name.isEmpty, let baseURL = URL(string: id), baseURL.isWebURL else {
            throw BookSourceError.invalidSource
        }
        self.baseURL = baseURL
    }

    private static func decodeRule<T: Decodable>(
        _ type: T.Type, from values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) throws -> T? {
        if let serialized = try? values.decode(String.self, forKey: key) {
            guard let serialized = serialized.nilIfBlank else { return nil }
            return try JSONDecoder().decode(T?.self, from: Data(serialized.utf8))
        }
        return try values.decodeIfPresent(type, forKey: key)
    }
}

public enum BookSourceImport {
    public static func decode(_ data: Data) throws -> [BookSource] {
        let decoder = JSONDecoder()
        do {
            let sources: [BookSource]
            if let source = try? decoder.decode(BookSource.self, from: data) {
                sources = [source]
            } else {
                sources = try decoder.decode([BookSource].self, from: data)
            }
            guard !sources.isEmpty else { throw BookSourceError.invalidSource }
            var byID: [String: BookSource] = [:]
            var order: [String] = []
            for source in sources {
                if byID.updateValue(source, forKey: source.id) == nil { order.append(source.id) }
            }
            return order.compactMap { byID[$0] }
        } catch {
            throw BookSourceError.invalidSource
        }
    }
}

public struct SourceBook: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(sourceID.utf8.count):\(sourceID)\(bookRequest.identity)" }
    public var title: String
    public var author: String
    public var introduction: String
    public var coverURL: URL?
    public var bookURL: URL { bookRequest.url }
    public var tocURL: URL? { tocRequest?.url }
    public let sourceID: String

    let bookRequest: SourceRequest
    var tocRequest: SourceRequest?

    public init(
        title: String, author: String = "", introduction: String = "", coverURL: URL? = nil,
        bookURL: URL, tocURL: URL? = nil, sourceID: String
    ) {
        self.init(title: title, author: author, introduction: introduction, coverURL: coverURL,
                  bookRequest: SourceRequest(url: bookURL), tocRequest: tocURL.map { SourceRequest(url: $0) },
                  sourceID: sourceID)
    }

    init(title: String, author: String, introduction: String, coverURL: URL?,
         bookRequest: SourceRequest, tocRequest: SourceRequest? = nil, sourceID: String) {
        self.title = title
        self.author = author
        self.introduction = introduction
        self.coverURL = coverURL
        self.bookRequest = bookRequest
        self.tocRequest = tocRequest
        self.sourceID = sourceID
    }
}

public struct SourceChapter: Codable, Identifiable, Equatable, Sendable {
    public var id: String { request.identity }
    public let title: String
    public var url: URL { request.url }

    let request: SourceRequest
    var nextChapterURL: URL?

    public init(title: String, url: URL) {
        self.init(title: title, request: SourceRequest(url: url))
    }

    init(title: String, request: SourceRequest) {
        self.title = title
        self.request = request
    }
}

public enum BookSourceError: LocalizedError, Equatable, Sendable {
    case invalidSource
    case invalidURL(String)
    case missingRule(String)
    case invalidRule(String)
    case unsupported(String)
    case badStatus(Int)
    case invalidResponse
    case responseTooLarge
    case paginationLimit
    case emptyChapters
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .invalidSource: "无法导入书源。请选择有效的阅读 3.0 书源 JSON。"
        case .invalidURL(let field): "书源的\(field)地址无效。"
        case .missingRule(let field): "书源未配置\(field)规则。"
        case .invalidRule(let field): "书源的\(field)规则格式有误。"
        case .unsupported(let feature): "此书源需要当前版本尚未支持的功能（\(feature)）。"
        case .badStatus(let status): "书源返回了 HTTP \(status)。"
        case .invalidResponse: "无法识别书源的响应。"
        case .responseTooLarge: "书源返回的内容超过大小限制。"
        case .paginationLimit: "书源的分页数量超过加载限制。"
        case .emptyChapters: "目录规则没有找到可阅读的章节。"
        case .emptyContent: "正文规则没有找到内容。"
        }
    }
}

struct SearchRule: Codable, Equatable, Sendable {
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var coverUrl: String?
    var bookUrl: String?
}

struct InfoRule: Codable, Equatable, Sendable {
    var `init`: String?
    var name: String?
    var author: String?
    var intro: String?
    var coverUrl: String?
    var tocUrl: String?
}

struct TocRule: Codable, Equatable, Sendable {
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var nextTocUrl: String?
    var preUpdateJs: String?
    var formatJs: String?
}

struct ContentRule: Codable, Equatable, Sendable {
    var content: String?
    var subContent: String?
    var nextContentUrl: String?
    var replaceRegex: String?
    var webJs: String?
    var sourceRegex: String?
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfBlank: String? { trimmed.isEmpty ? nil : trimmed }
}

extension URL {
    var isWebURL: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return host?.isEmpty == false && user == nil && password == nil
    }
}
