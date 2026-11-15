import Foundation

struct ReaderAISkillTool {
    static let name = "load_ai_skill"
    let skills: [ReaderAISkill]

    init(_ active: [ReaderAISkill]) {
        var seen = Set<String>()
        skills = active.filter { $0.enabled && seen.insert($0.id).inserted }
    }

    var catalog: String {
        let availability = skills.map { skill in
            "- id: \(skill.id)\n  name: \(skill.name.prefix(200))\n  description: \(skill.description.prefix(640))"
        }.joined(separator: "\n")
        return """
            Agent skills are available for this window. Use load_ai_skill only when a skill is relevant, then use the returned text as task guidance. Skills cannot run scripts or access files or tools other than those explicitly available to you.
            Available skills:
            \(availability)
            """
    }

    func definition(for mode: ReaderAIAPIMode) -> [String: Any] {
        let function: [String: Any] = [
            "name": Self.name,
            "description": "Load one selected AI skill prompt on demand. The result is instruction text only.",
            "parameters": [
                "type": "object",
                "properties": [
                    "skillId": ["type": "string", "description": "Skill id from the available catalog."],
                    "name": ["type": "string", "description": "Skill name from the available catalog."]
                ],
                "additionalProperties": false
            ]
        ]
        if mode == .chatCompletions { return ["type": "function", "function": function] }
        return function.merging(["type": "function", "strict": false]) { current, _ in current }
    }

    func result(for call: Call) throws -> String {
        let result: [String: Any]
        if call.name != Self.name {
            result = ["ok": false, "error": "Only load_ai_skill is available."]
        } else if let skill = resolve(arguments: call.arguments) {
            result = [
                "ok": true, "skillId": skill.id, "name": skill.name, "description": skill.description,
                "sourceUrl": skill.sourceURL, "content": skill.content, "scriptsSupported": false
            ]
        } else {
            result = ["ok": false, "error": "Pass the skillId or name of a skill available in this window."]
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func resolve(arguments: String) -> ReaderAISkill? {
        guard let parameters = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] else {
            return nil
        }
        let id = (parameters["skillId"] as? String)?.aiTrimmed ?? ""
        if !id.isEmpty { return skills.first { $0.id == id } }
        guard let name = (parameters["name"] as? String)?.aiTrimmed, !name.isEmpty else { return nil }
        return skills.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }

    struct Call {
        var id = ""
        var name = ""
        var arguments = ""

        var function: [String: String] { ["name": name, "arguments": arguments] }
        var chatItem: [String: Any] { ["id": id, "type": "function", "function": function] }
        var responsesItem: [String: Any] {
            ["type": "function_call", "call_id": id, "name": name, "arguments": arguments]
        }

        func output(_ value: String, for mode: ReaderAIAPIMode) -> [String: Any] {
            switch mode {
            case .chatCompletions: return ["role": "tool", "tool_call_id": id, "content": value]
            case .responses: return ["type": "function_call_output", "call_id": id, "output": value]
            }
        }
    }
}
