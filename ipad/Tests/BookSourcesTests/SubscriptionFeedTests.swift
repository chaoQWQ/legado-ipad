@testable import BookSources
import Foundation
import Testing

struct SubscriptionFeedTests {
    @Test func readsRSSWithSummaryAndRelativeArticle() async throws {
        let url = try FeedSubscription.address(from: "https://example.com/feed/index.xml")
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>阅读资讯</title>
          <item><guid>post-1</guid><title>新文章</title><link>../posts/1</link>
          <description><![CDATA[<p>导读&amp;笔记</p>]]></description>
          <pubDate>Sun, 15 Nov 2026 10:05:00 +0800</pubDate></item>
          <item><guid>post-1</guid><title>重复文章</title></item>
        </channel></rss>
        """
        let client = SubscriptionFeedClient { address in (Data(xml.utf8), address) }
        let feed = try await client.load(url)
        #expect(feed.title == "阅读资讯")
        #expect(feed.articles.count == 1)
        let first = try #require(feed.articles.first)
        #expect(first.title == "新文章")
        #expect(first.summary == "导读&笔记")
        #expect(first.url?.absoluteString == "https://example.com/posts/1")
        #expect(first.publishedAt == (try? Date.ISO8601FormatStyle().parse("2026-11-15T02:05:00Z")))
    }

    @Test func readsAtomAndIgnoresNonWebArticleLinks() async throws {
        let url = try FeedSubscription.address(from: "https://example.com/atom.xml")
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>新订阅</title>
          <entry><id>item</id><title>带链接的文章</title><link rel="enclosure" href="track.mp3" />
          <link href="articles/1" /><updated>2026-11-15T02:05:00.031Z</updated></entry>
          <entry><id>other</id><title>无网页链接</title><link href="file:///a" /></entry>
        </feed>
        """
        let client = SubscriptionFeedClient { address in (Data(xml.utf8), address) }
        let feed = try await client.load(url)
        #expect(feed.articles.count == 2)
        #expect(feed.articles.first?.url?.absoluteString == "https://example.com/articles/1")
        #expect(feed.articles.first?.publishedAt != nil)
        #expect(feed.articles.last?.url == nil)
        #expect(throws: (any Error).self) { try FeedSubscription.address(from: "https://user:secret@example.com/a") }
    }
}
