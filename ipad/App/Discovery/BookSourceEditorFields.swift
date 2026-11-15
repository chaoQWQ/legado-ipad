import Foundation

struct BookSourceEditorField: Identifiable {
    let key: String
    let title: String
    var rule: String? = nil
    var isCode = true

    var id: String { rule.map { "\($0).\(key)" } ?? key }
}

enum BookSourceEditorTab: CaseIterable, Identifiable {
    case basics, search, explore, details, toc, content, reviews, json

    var id: Self { self }

    var title: String {
        switch self {
        case .basics: "基本"
        case .search: "搜索"
        case .explore: "发现"
        case .details: "详情"
        case .toc: "目录"
        case .content: "正文"
        case .reviews: "段评"
        case .json: "JSON"
        }
    }

    static let identityFields = [
        BookSourceEditorField(key: "bookSourceName", title: "书源名称", isCode: false),
        BookSourceEditorField(key: "bookSourceUrl", title: "书源地址", isCode: false),
        BookSourceEditorField(key: "bookSourceGroup", title: "书源分组", isCode: false),
        BookSourceEditorField(key: "bookSourceComment", title: "书源注释", isCode: false)
    ]

    static let requestFields = fields([
        ("bookUrlPattern", "详情地址匹配"), ("header", "请求头"), ("concurrentRate", "并发率")
    ])

    static let androidFields = fields([
        ("variableComment", "自定义变量说明"), ("loginUrl", "登录地址"), ("loginUi", "登录界面"),
        ("loginCheckJs", "登录检测脚本"), ("coverDecodeJs", "封面解码脚本"), ("jsLib", "JavaScript 库")
    ])

    var fields: [BookSourceEditorField] {
        switch self {
        case .basics, .json:
            []
        case .search:
            Self.fields([("searchUrl", "搜索地址")]) + Self.fields(
                [("checkKeyWord", "校验关键词")] + Self.listKeys, rule: "ruleSearch"
            )
        case .explore:
            Self.fields([("exploreUrl", "发现地址"), ("exploreScreen", "发现筛选规则")])
                + Self.fields(Self.listKeys, rule: "ruleExplore")
        case .details:
            Self.fields([("init", "详情初始化规则")] + Self.bookKeys + [
                ("tocUrl", "目录地址"), ("canReName", "允许更新书名"), ("downloadUrls", "下载地址")
            ], rule: "ruleBookInfo")
        case .toc:
            Self.fields([
                ("chapterList", "章节列表"), ("chapterName", "章节名称"), ("chapterUrl", "章节地址"),
                ("nextTocUrl", "目录下一页"), ("isVolume", "分卷规则"), ("updateTime", "章节更新时间"),
                ("isVip", "VIP 章节规则"), ("isPay", "已购章节规则"), ("preUpdateJs", "目录更新前脚本"),
                ("formatJs", "章节名称格式化脚本")
            ], rule: "ruleToc")
        case .content:
            Self.fields([
                ("content", "正文规则"), ("nextContentUrl", "正文下一页"), ("subContent", "副文规则"),
                ("replaceRegex", "正文替换规则"), ("title", "正文页章节名"), ("sourceRegex", "正文定位规则"),
                ("imageStyle", "图片样式"), ("imageDecode", "图片解码脚本"), ("webJs", "网页脚本"),
                ("payAction", "购买操作"), ("callBackJs", "事件回调脚本")
            ], rule: "ruleContent")
        case .reviews:
            Self.fields([
                ("reviewUrl", "段评地址"), ("avatarRule", "头像规则"), ("contentRule", "段评内容规则"),
                ("postTimeRule", "发布时间规则"), ("reviewQuoteUrl", "段评回复地址"), ("voteUpUrl", "点赞地址"),
                ("voteDownUrl", "点踩地址"), ("postReviewUrl", "发送段评地址"), ("postQuoteUrl", "发送回复地址"),
                ("deleteUrl", "删除段评地址")
            ], rule: "ruleReview")
        }
    }

    private static let bookKeys = [
        ("name", "书名"), ("author", "作者"), ("kind", "分类"), ("wordCount", "字数"),
        ("lastChapter", "最新章节"), ("updateTime", "更新时间"), ("intro", "简介"), ("coverUrl", "封面地址")
    ]

    private static let listKeys = [("bookList", "书籍列表")] + bookKeys + [("bookUrl", "书籍详情地址")]

    private static func fields(_ labels: [(String, String)], rule: String? = nil) -> [BookSourceEditorField] {
        labels.map { BookSourceEditorField(key: $0.0, title: $0.1, rule: rule) }
    }
}
