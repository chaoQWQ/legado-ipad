import Foundation
import Testing
@testable import BookSources

@Test func bookSourceSubscriptionParsesAndroidLinksAndSchedulesRefresh() throws {
    let source = "https://example.test/source.json?name=first&part=2"
    var importLink = URLComponents()
    importLink.scheme = "yuedu"
    importLink.host = "import"
    importLink.path = "/bookSource"
    importLink.queryItems = [URLQueryItem(name: "src", value: source)]
    let encoded = try #require(importLink.string)
    let address = try BookSourceSubscription.address(from: encoded)
    #expect(address.absoluteString == source)
    #expect(try BookSourceSubscription.address(
        from: "https://www.yckceo.com/yuedu/shuyuans/content/id/123.html"
    ).absoluteString == "https://www.yckceo.com/yuedu/shuyuans/json/id/123.json")
    #expect(throws: BookSourceSubscriptionError.invalidAddress) {
        try BookSourceSubscription.address(from: "legado://import/rssSource?src=https://example.test/info.json")
    }
    #expect(throws: BookSourceSubscriptionError.invalidAddress) {
        try BookSourceSubscription.address(from: "legado://import/auto?src=file:///var/data")
    }
    #expect(throws: BookSourceSubscriptionError.invalidAddress) {
        try BookSourceSubscription.address(from: "https://user:pass@example.test/source.json")
    }

    let last = Date(timeIntervalSinceReferenceDate: 100)
    let saved = BookSourceSubscription(
        name: "译本", url: address, autoUpdate: true, updateIntervalHours: 2, lastRefreshedAt: last
    )
    #expect(!saved.isDue(at: last.addingTimeInterval(7_199)))
    #expect(saved.isDue(at: last.addingTimeInterval(7_200)))
    let restored = try JSONDecoder().decode(BookSourceSubscription.self, from: JSONEncoder().encode(saved))
    #expect(restored == saved)
}

@Test func bookSourceSubscriptionPreviewsDataAndReportsMalformedCollection() async throws {
    let url = try BookSourceSubscription.address(from: "https://example.test/sub.json")
    let valid = #"{"bookSourceName":"示例","bookSourceUrl":"https://library.example.test"}"#
    let client = BookSourceSubscriptionClient(fetch: { _, _ in (Data("[\(valid)]".utf8), url) })
    let sources = try await client.preview(url)
    #expect(sources.map(\.name) == ["示例"])

    let invalid = BookSourceSubscriptionClient(fetch: { _, _ in (Data("[\(valid),{}]".utf8), url) })
    await #expect(throws: BookSourceSubscriptionError.invalidPayload) {
        try await invalid.preview(url)
    }
}

@Test func bookSourceMarketplaceListsNativeRowsAndDerivesJSONOnMirror() async throws {
    let listing = """
    <html><body>
      <h2><a href="/yuedu/shuyuans/content/id/12.html?from=listing">示例 &amp; 样本</a></h2>
      <h2><a href="/yuedu/shuyuans/content/id/12.html">重复条目</a></h2>
      <h2><a href="/yuedu/shuyuan/content/id/13.html">其他分类</a></h2>
      <h2><a href="https://other.example.test/yuedu/shuyuans/content/id/14.html">第三方链接</a></h2>
      <h2><a href="/yuedu/shuyuans/content/id/15.html">两本书</a></h2>
    </body></html>
    """
    let client = BookSourceMarketplaceClient(fetch: { url, _ in
        if url.host == "www.yckceo.com" { throw URLError(.cannotConnectToHost) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "page", value: "2")))
        #expect(items.contains(URLQueryItem(name: "keys", value: "样本")))
        return (Data(listing.utf8), url)
    })
    let entries = try await client.entries(in: .collections, page: 2, keyword: "样本")
    #expect(entries.map(\.title) == ["示例 & 样本", "两本书"])
    let entry = try #require(entries.first)
    let download = try await client.downloadURL(for: entry)
    #expect(download.absoluteString == "https://www.yck2026.fun/yuedu/shuyuans/json/id/12.json")
}

@Test func bookSourceMarketplaceYioveSearchPaginationAndPreviewUsePublicRoutes() async throws {
    let id = "01234567-89ab-cdef-0123-456789abcdef"
    let list = """
    {"items":[{"id":"\(id)","name":"示例书源合集"},{"id":"\(id)","name":"重复条目"}],"total":25,"page":1,"size":20,"pages":2}
    """
    let source = #"[{"bookSourceUrl":"https://fiction.example","bookSourceName":"测试书源"}]"#
    let client = BookSourceMarketplaceClient(fetch: { url, _ in
        #expect(url.scheme == "https")
        #expect(url.host == "shuyuan-api.yiove.com")
        switch url.path {
        case "/shuyuan/search":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []
            #expect(query.contains(.init(name: "search_type", value: "book-source-collections")))
            #expect(query.contains(.init(name: "search_key", value: "中文 & 搜索")))
            #expect(query.contains(.init(name: "page", value: "1")))
            #expect(query.contains(.init(name: "page_size", value: "20")))
            return (Data(list.utf8), url)
        case "/import/book-source-collection/\(id)":
            return (Data(source.utf8), url)
        default:
            throw URLError(.unsupportedURL)
        }
    })
    let page = try await client.page(in: .collections, keyword: " 中文 & 搜索 ", provider: .yiove)
    #expect(page.hasNextPage)
    #expect(page.entries.map(\.title) == ["示例书源合集"])
    let entry = try #require(page.entries.first)
    #expect(entry.provider == .yiove)
    #expect(entry.detailURL.absoluteString == "https://shuyuan.yiove.com/book-source-collection/\(id)")
    let preview = try await client.preview(for: entry)
    #expect(preview.url.absoluteString == "https://shuyuan-api.yiove.com/import/book-source-collection/\(id)")
    #expect(preview.sources.map(\.name) == ["测试书源"])
    #expect(try BookSourceSubscription.address(from: entry.detailURL.absoluteString) == preview.url)
}

@Test func bookSourceMarketplaceRetriesPreviewOnMirrorAndReportsSanitizedFailures() async throws {
    let client = BookSourceMarketplaceClient(fetch: { url, _ in
        switch (url.host, url.path) {
        case ("www.yckceo.com", "/yuedu/shuyuan/index.html"):
            return (Data(#"<h2><a href="/yuedu/shuyuan/content/id/99.html">示例书源</a></h2>"#.utf8), url)
        case ("www.yckceo.com", "/yuedu/shuyuan/json/id/99.json"):
            throw URLError(.serverCertificateUntrusted)
        case ("www.yck2026.fun", "/yuedu/shuyuan/json/id/99.json"):
            return (Data(#"{"bookSourceUrl":"https://fiction.example","bookSourceName":"示例书源"}"#.utf8), url)
        default:
            throw URLError(.unsupportedURL)
        }
    })
    let entries = try await client.entries(in: .sources)
    let entry = try #require(entries.first)
    #expect(entry.detailURL.host == "www.yckceo.com")
    let preview = try await client.preview(for: entry)
    #expect(preview.url.host == "www.yck2026.fun")
    #expect(preview.sources.map(\.name) == ["示例书源"])

    let failure = BookSourceMarketplaceClient(fetch: { url, _ in
        if url.host == "www.yckceo.com" {
            throw URLError(.serverCertificateUntrusted, userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        }
        return (Data("<p>Unexpected response</p>".utf8), url)
    })
    do {
        _ = try await failure.entries(in: .sources, keyword: "private search value")
        Issue.record("An unrecognized HTML page must not be interpreted as an empty search")
    } catch {
        let description = error.localizedDescription
        #expect(description.contains("www.yckceo.com"))
        #expect(description.contains("设备不信任服务器证书"))
        #expect(description.contains("NSURLErrorDomain -1202"))
        #expect(description.contains("www.yck2026.fun"))
        #expect(description.contains("响应未包含可识别的目录条目"))
        #expect(description.contains("切换网络后重试"))
        #expect(!description.contains("private"))
    }
}
