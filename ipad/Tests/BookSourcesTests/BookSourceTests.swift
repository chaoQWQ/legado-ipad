@testable import BookSources
import Foundation
import Testing

struct BookSourceTests {
    @Test func testHTMLSourceSearchDetailsAndPagedReading() async throws {
        let source = try importSource(#"""
        {
          "bookSourceUrl": "https://fiction.example/root/", "bookSourceName": "HTML 书源",
          "header": "{\"User-Agent\":\"LegadoPadTests\"}",
          "searchUrl": "search?q={{key}}&page=<,{{page}}>",
          "ruleSearch": {"bookList":"@css:.result", "name":"@css:a@text", "author":"class.author@text", "bookUrl":"tag.a@href"},
          "ruleBookInfo": {"init":"@XPath://article", "intro":"@XPath:.//p", "tocUrl":"@css:a[href^='toc']@href"},
          "ruleToc": {"chapterList":"@css:nav > .chapter", "chapterName":"text", "chapterUrl":"href", "nextTocUrl":"@css:a.more@href"},
          "ruleContent": {"content":"id.story@html", "nextContentUrl":"@css:a.next@href", "replaceRegex":"##【广告】"}
        }
        """#)
        let client = BookSourceClient { request, cookies in
            #expect(cookies)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "LegadoPadTests")
            let url = try #require(request.url)
            switch url.path {
            case "/root/search":
                #expect(url.absoluteString == "https://fiction.example/root/search?q=%E5%8D%8A%20%26%2F%E5%A4%9C&page=")
                return self.response(url, #"<section class="result"><a href="book/42">月亮岛</a><span class="author">小林</span></section>"#,
                                     finalURL: URL(string: "https://fiction.example/root/results"))
            case "/root/book/42":
                return self.response(url, #"<article><p>序言 &amp; 背景</p><a href="toc">目录</a></article>"#)
            case "/root/book/toc":
                return self.response(url, #"<nav><a class="chapter" href="ch1">第一章</a></nav><a class="more" href="toc2">下一页</a>"#)
            case "/root/book/toc2":
                return self.response(url, #"<nav><a class="chapter" href="ch1">重复</a><a class="chapter" href="ch2">第二章</a></nav><a class="more" href="toc">上页</a>"#)
            case "/root/book/ch1":
                return self.response(url, #"<div id="story"><p>第一段</p><script>bad()</script><p>第二段【广告】</p></div><a class="next" href="ch1-p2">下一页</a>"#)
            case "/root/book/ch1-p2":
                return self.response(url, #"<div id="story"><p>第三段 &amp; 尾声</p></div><a class="next" href="ch2">下一章</a>"#)
            default:
                Issue.record("Unexpected request to \(url)")
                throw URLError(.unsupportedURL)
            }
        }
        let results = try await client.search("半 &/夜", in: source)
        let book = try #require(results.first)
        #expect(book.title == "月亮岛")
        #expect(book.author == "小林")
        let detail = try await client.details(for: book, in: source)
        #expect(detail.introduction == "序言 & 背景")
        #expect(detail.tocURL?.absoluteString == "https://fiction.example/root/book/toc")
        let chapters = try await client.chapters(for: detail, in: source)
        #expect(chapters.map(\.title) == ["第一章", "第二章"])
        let content = try await client.content(of: chapters[0], in: source)
        #expect(content == "第一段\n\n第二段\n\n第三段 & 尾声")
    }

    @Test func testJSONPostSourceAndPersistentRequestOptions() async throws {
        let source = try importSource(#"""
        {
          "bookSourceUrl":"https://fiction.example", "bookSourceName":"JSON 书源", "enabledCookieJar":false,
          "searchUrl":"/find,{\"method\":\"POST\",\"body\":{\"q\":\"{{key}}\",\"page\":\"{{page}}\"}}",
          "ruleSearch":"{\"bookList\":\"@Json:$.response.items[*]\",\"name\":\"$.name\",\"bookUrl\":\"url\"}",
          "ruleToc":{"chapterList":"-$.chapters", "chapterName":"name", "chapterUrl":"url"},
          "ruleContent":{"content":"$.text"}
        }
        """#)
        let client = BookSourceClient { request, cookies in
            #expect(!cookies)
            let url = try #require(request.url)
            switch url.path {
            case "/find":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try #require(request.httpBody)
                #expect((try JSONSerialization.jsonObject(with: body) as? [String: String]) == ["page": "1", "q": "字\"&"])
                return self.response(url, #"{"response":{"items":[{"name":"江城","url":"/reader"}]}}"#)
            case "/reader":
                return self.response(url, #"{"chapters":[{"name":"第二章","url":"/chapter2"},{"name":"第一章","url":"/chapter,{\"method\":\"POST\",\"body\":\"id=1\"}"}]}"#)
            case "/chapter":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                #expect(request.httpBody == Data("id=1".utf8))
                return self.response(url, #"{"text":"起风了。"}"#)
            default:
                Issue.record("Unexpected request to \(url)")
                throw URLError(.unsupportedURL)
            }
        }
        let results = try await client.search("字\"&", in: source)
        let book = try #require(results.first)
        let chapters = try await client.chapters(for: book, in: source)
        #expect(chapters.map(\.title) == ["第一章", "第二章"])
        let decoder = JSONDecoder()
        let restored = try decoder.decode([SourceChapter].self, from: JSONEncoder().encode(chapters))
        let text = try await client.content(of: restored[0], in: source)
        #expect(text == "起风了。")
    }

    @Test func testLegacySelectorsFallbackAndUnsafeLinks() throws {
        let root = try RuleValue.document("""
        <ul id='list'><li class='item'>一</li><li class='item'>二</li><li class='item'>三</li></ul>
        """)
        let list = try root.select("@@id.list@class.item!0", field: "目录")
        #expect(try list.map { try $0.string("not-present||text", field: "名称") } == ["二", "三"])
        #expect(try root.string("@css:ul > li:nth-child(2)@text", field: "名称") == "二")
        #expect(try root.string("@XPath:string(//li[last()])", field: "名称") == "三")
        #expect(throws: BookSourceError.invalidURL("章节")) {
            try SourceRequest.parse("file:///etc/passwd", relativeTo: nil, field: "章节")
        }
        #expect(throws: BookSourceError.unsupported("JavaScript 或自定义链接变量")) {
            try SourceRequest.parse("https://fiction.example/{{java.encode(key)}}", relativeTo: nil, field: "搜索")
        }
    }

    @Test func testGBKSearchCanReturnRedirectedDetails() async throws {
        let source = try importSource(#"""
        {
          "bookSourceUrl":"https://fiction.example", "bookSourceName":"GBK 书源",
          "searchUrl":"/find?q={{key}},{\"charset\":\"GBK\"}",
          "bookUrlPattern":"https://fiction[.]example/book/[0-9]+",
          "ruleBookInfo":{"name":"@css:h1@text", "tocUrl":"@css:a@href"}
        }
        """#)
        let client = BookSourceClient { request, _ in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://fiction.example/find?q=%BD%AD%B3%C7")
            let finalURL = try #require(URL(string: "https://fiction.example/book/23"))
            let response = try #require(HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: [:]))
            let encoding = try #require(stringEncoding("GBK"))
            let data = try #require(#"<meta charset=gbk><h1>江城</h1><a href="chapters">目录</a>"#.data(using: encoding))
            return (data, response)
        }
        let results = try await client.search("江城", in: source)
        let book = try #require(results.first)
        #expect(book.title == "江城")
        #expect(book.bookURL.absoluteString == "https://fiction.example/book/23")
        #expect(book.tocURL?.absoluteString == "https://fiction.example/book/chapters")
    }

    @Test func testBookSourceImportDeduplicatesAndPreservesEnabledState() throws {
        let sources = try BookSourceImport.decode(Data(#"""
        [
          {"bookSourceUrl":"https://fiction.example", "bookSourceName":"旧"},
          {"bookSourceUrl":"https://other.example", "bookSourceName":"其他"},
          {"bookSourceUrl":"https://fiction.example", "bookSourceName":"新", "enabled":false}
        ]
        """#.utf8))
        #expect(sources.map(\.name) == ["新", "其他"])
        #expect(sources.map(\.isEnabled) == [false, true])
        #expect(try JSONDecoder().decode([BookSource].self, from: JSONEncoder().encode(sources)) == sources)
    }

    @Test func explicitChapterRefreshRevalidatesAllPages() async throws {
        let source = try importSource(#"""
        {
          "bookSourceUrl":"https://fiction.example", "bookSourceName":"分页",
          "ruleContent":{"content":"@css:p@text", "nextContentUrl":"@css:a@href"}
        }
        """#)
        let url = try #require(URL(string: "https://fiction.example/chapter"))
        let client = BookSourceClient { request, _ in
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            let page = try #require(request.url)
            switch page.path {
            case "/chapter": return self.response(page, #"<p>前半章</p><a href="/second">下一页</a>"#)
            case "/second": return self.response(page, "<p>后半章</p>")
            default: throw URLError(.unsupportedURL)
            }
        }
        let text = try await client.content(of: SourceChapter(title: "第一章", url: url), in: source, bypassCache: true)
        #expect(text == "前半章\n\n后半章")
    }

    @Test func builtInSimplificationConvertsAllPagesAndExistingCache() async throws {
        let source = try importSource(#"""
        {
          "bookSourceUrl":"https://fiction.example", "bookSourceName":"中文正文",
          "ruleContent":{"content":"@css:p@text", "nextContentUrl":"@css:a@href", "replaceRegex":"@js:java.t2s(result)"}
        }
        """#)
        let url = try #require(URL(string: "https://fiction.example/chapter"))
        let client = BookSourceClient { request, _ in
            let page = try #require(request.url)
            switch page.path {
            case "/chapter": return self.response(page, #"<p>風起後，國門開了。 📚</p><a href="/second">下一頁</a>"#)
            case "/second": return self.response(page, "<p>長廊裡亮了燈。</p>")
            default: throw URLError(.unsupportedURL)
            }
        }
        let original = "風起後，國門開了。 📚\n\n長廊裡亮了燈。"
        let expected = "风起后，国门开了。 📚\n\n长廊里亮了灯。"
        let chapter = SourceChapter(title: "第一章", url: url)
        let converted = try await client.content(of: chapter, in: source)
        let raw = try await client.content(of: chapter, in: source, applyingTextConversion: false)
        #expect(converted == expected)
        #expect(raw == original)
        #expect(source.convertCachedContent(raw) == expected)
        #expect(source.convertCachedContent(expected) == expected)
        #expect(converted.utf16.count == original.utf16.count)
    }

    @Test func simplificationRecognizesOnlyTheBuiltInExpression() throws {
        let traditional = "歡迎閱讀。"
        let simplified = "欢迎阅读。"
        #expect(try applyReplacement(" @JS:\njava . t2s ( result ); ", to: traditional) == simplified)
        #expect(try applyReplacement("<js>\njava.t2s(result);\n</js>", to: traditional) == simplified)
        #expect(try applyReplacement(nil, to: traditional) == traditional)
        #expect(try applyReplacement("##。", to: traditional, applyingTextConversion: false) == "歡迎閱讀")
        let source = try importSource(#"""
        {
          "bookSourceUrl":"https://fiction.example", "bookSourceName":"普通替换",
          "ruleContent":{"replaceRegex":"##。"}
        }
        """#)
        #expect(source.convertCachedContent(traditional) == traditional)
        #expect(throws: BookSourceError.unsupported("JavaScript 或规则变量")) {
            try applyReplacement("@js:java.t2s(result); otherFunction(result)", to: traditional, applyingTextConversion: false)
        }
        #expect(throws: BookSourceError.unsupported("JavaScript 或规则变量")) {
            try applyReplacement("@js:java.t2s(result + 'extra')", to: traditional)
        }
    }

    private func importSource(_ json: String) throws -> BookSource {
        try #require(BookSourceImport.decode(Data(json.utf8)).first)
    }

    private func response(_ url: URL, _ text: String, finalURL: URL? = nil) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: finalURL ?? url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
        return (Data(text.utf8), response)
    }
}
