import Foundation

struct ReaderAITool: Identifiable {
    let name: String
    let description: String
    let parameters: [String: Any]
    let invoke: (String) async throws -> String

    var id: String { name }

    func definition(for mode: ReaderAIAPIMode) -> [String: Any] {
        let function: [String: Any] = ["name": name, "description": description, "parameters": parameters]
        switch mode {
        case .chatCompletions: return ["type": "function", "function": function]
        case .responses: return function.merging(["type": "function", "strict": false]) { current, _ in current }
        }
    }

    static func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func failure(_ message: String) -> String {
        (try? json(["ok": false, "error": String(message.prefix(512))])) ?? "{\"ok\":false}"
    }
}

enum ReaderAIToolScope: String, CaseIterable, Identifiable, Codable {
    case enabled, safe, all

    var id: Self { self }
    var title: String {
        switch self {
        case .enabled: return "使用已启用工具"
        case .safe: return "阅读安全工具"
        case .all: return "全量工具"
        }
    }
}

enum ReaderAIToolProgress {
    case thinking
    case calling(id: String, name: String, previewArguments: String?)
    case completed(id: String, succeeded: Bool)
}
