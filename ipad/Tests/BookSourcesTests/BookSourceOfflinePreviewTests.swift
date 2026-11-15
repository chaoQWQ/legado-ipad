import Foundation
import Testing
@testable import BookSources

@Test func previewUsesTheSourceEngineWithExplicitPageSamples() async throws {
    let source = try #require(BookSourceImport.decode(Data("""
        {
          "bookSourceUrl": "https://sample.example.invalid", "bookSourceName": "离线样本",
          "searchUrl": "/search?q={{key}}",
          "ruleSearch": {"bookList":"@css:.books li", "name":"@css:a@text", "bookUrl":"@css:a@href"},
          "ruleBookInfo": {"name":"@css:h1@text", "author":"@css:.author@text", "tocUrl":"@css:.toc@href"},
          "ruleToc": {"chapterList":"@css:.toc li", "chapterName":"@css:a@text", "chapterUrl":"@css:a@href"},
          "ruleContent": {"content":"@css:article@text"}
        }
        """.utf8)).first)
    let homepage = "https://sample.example.invalid"
    let preview = try BookSourceOfflinePreview(pages: [
        "\(homepage)/search?q=test": "<ul class='books'><li><a href='/book'>测试书</a></li></ul>",
        "\(homepage)/book": "<h1>测试书</h1><p class='author'>作者</p><a class='toc' href='/catalog'>目录</a>",
        "\(homepage)/catalog": "<ul class='toc'><li><a href='/one'>第一章</a></li></ul>",
        "\(homepage)/one": "<article>这是正文样本。</article>"
    ])
    let book = try #require(await preview.search("test", in: source).first)
    let details = try await preview.details(at: book.bookURL, in: source)
    let tocURL = try #require(details.tocURL)
    let chapter = try #require(await preview.chapters(at: tocURL, in: source).first)
    #expect(details.author == "作者")
    #expect(chapter.title == "第一章")
    #expect(try await preview.content(at: chapter.url, in: source) == "这是正文样本。")
    #expect(BookSourceOfflinePreview.configurationIssues(in: source).isEmpty)

    do {
        let missing = try #require(URL(string: "\(homepage)/missing"))
        _ = try await preview.content(at: missing, in: source)
        Issue.record("An address without an explicit sample should fail locally")
    } catch {
        #expect(error.localizedDescription.contains("样本"))
    }
}
