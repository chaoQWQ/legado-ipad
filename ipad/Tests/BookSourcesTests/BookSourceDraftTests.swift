import BookSources
import Foundation
import Testing

struct BookSourceDraftTests {
    @Test func structuredEditsPreserveUnknownFieldsAndSerializedRuleObjects() throws {
        let sourceJSON = #"""
        {
          "bookSourceUrl":"https://fiction.example", "bookSourceName":"旧名称", "enabled":true,
          "header":{"User-Agent":"FictionReader"},
          "bookSourceComment":"注释\n带引号的 \"文字\"",
          "ruleExplore":{"extraRule":{"enabled":true, "path":["107",null,9]}},
          "ruleSearch":{"name":"tag.a@text", "unknown":"保留"},
          "ruleContent":"{\"content\":\"@css:article@text\",\"unknown\":[1,\"2\"]}",
          "lastUpdateTime":12345678901234567
        }
        """#
        let source = try #require(BookSourceImport.decode(Data(sourceJSON.utf8)).first)
        var draft = BookSourceDraft(source: source)
        #expect(draft["content", rule: "ruleContent"] == "@css:article@text")
        draft["bookSourceName"] = "新名称"
        draft["replaceRegex", rule: "ruleContent"] = "@js:java.t2s(result)"
        draft["reviewUrl", rule: "ruleReview"] = "/review"
        var edited = try draft.makeSource()
        edited.isEnabled = false

        let data = try JSONEncoder().encode(edited)
        let restored = try JSONDecoder().decode(BookSource.self, from: data)
        #expect(restored == edited)
        #expect(restored.name == "新名称")
        #expect(!restored.isEnabled)
        #expect(restored.convertCachedContent("長廊") == "长廊")
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(saved["bookSourceComment"] as? String == "注释\n带引号的 \"文字\"")
        #expect((saved["header"] as? [String: String])?["User-Agent"] == "FictionReader")
        #expect((saved["ruleSearch"] as? [String: String])?["unknown"] == "保留")
        let explore = try #require((saved["ruleExplore"] as? [String: Any])?["extraRule"] as? [String: Any])
        let path = try #require(explore["path"] as? [Any])
        #expect(path[0] as? String == "107")
        #expect(path[1] is NSNull)
        #expect(path[2] as? Int == 9)
        #expect(saved["lastUpdateTime"] as? Int64 == 12345678901234567)
        let serialized = try #require(saved["ruleContent"] as? String)
        let content = try #require(JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any])
        #expect(content["replaceRegex"] as? String == "@js:java.t2s(result)")
        let otherRules = try #require(content["unknown"] as? [Any])
        #expect(otherRules[0] as? Int == 1)
        #expect(otherRules[1] as? String == "2")
        #expect((saved["ruleReview"] as? [String: String])?["reviewUrl"] == "/review")
    }

    @Test func rawAndStructuredDraftsShareValidation() throws {
        var draft = BookSourceDraft()
        #expect(throws: BookSourceDraftError.missingName) { try draft.makeSource() }
        draft["bookSourceName"] = "   "
        #expect(throws: BookSourceDraftError.missingName) { try draft.makeSource() }
        draft["bookSourceName"] = "来源"
        draft["bookSourceUrl"] = "file:///tmp/test.txt"
        #expect(throws: BookSourceDraftError.invalidAddress) { try draft.makeSource() }
        draft["bookSourceUrl"] = " https://fiction.example "
        draft[flag: "enabledCookieJar", default: true] = false
        draft.sourceType = 3
        let rawDraft = try BookSourceDraft(json: draft.jsonString())
        #expect(try rawDraft.makeSource().id == "https://fiction.example")
        #expect(rawDraft.sourceType == 3)
        #expect(!rawDraft[flag: "enabledCookieJar", default: true])
        #expect(throws: BookSourceDraftError.invalidJSON) {
            try BookSourceDraft(json: "[{\"bookSourceUrl\":\"https://fiction.example\"}]")
        }
        let malformed = try BookSourceDraft(json: #"{"bookSourceUrl":"https://fiction.example", "bookSourceName":"测试", "ruleToc":"invalid JSON"}"#)
        #expect(throws: BookSourceDraftError.invalidField("ruleToc")) { try malformed.makeSource() }
    }
}
