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
