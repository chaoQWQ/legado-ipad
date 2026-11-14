import Foundation

struct JSONPath {
    private enum Step {
        case property(String)
        case index(Int)
        case wildcard
        case recursive(String)
        case union([Step])
    }

    static func values(_ expression: String, in root: Any, field: String) throws -> [Any] {
        var path = expression.trimmed[...]
        if path.first == "$" || path.first == "@" { _ = path.popFirst() }
        var steps: [Step] = []
        while let current = path.first {
            if current == "[" {
                _ = path.popFirst()
                let inner = try readBracket(&path, field: field)
                let terms = splitRule(inner, separators: [","]).parts
                let choices = try terms.map { term -> Step in
                    if term == "*" { return .wildcard }
                    if let index = Int(term) { return .index(index) }
                    if let first = term.first, ["'", "\""].contains(first), term.last == first, term.count >= 2 {
                        let key = String(term.dropFirst().dropLast())
                            .replacingOccurrences(of: "\\\(first)", with: String(first))
                            .replacingOccurrences(of: "\\\\", with: "\\")
                        return .property(key)
                    }
                    throw BookSourceError.unsupported("JSONPath 筛选或切片（\(field)）")
                }
                steps.append(choices.count == 1 ? choices[0] : .union(choices))
                continue
            }
            var recursive = false
            if current == "." {
                _ = path.popFirst()
                if path.first == "." { _ = path.popFirst(); recursive = true }
            } else if !steps.isEmpty {
                throw BookSourceError.invalidRule(field)
            }
            let key = String(path.prefix { $0 != "." && $0 != "[" })
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw BookSourceError.invalidRule(field) }
            path = path.dropFirst(key.count)
            steps.append(recursive ? .recursive(key) : key == "*" ? .wildcard : .property(key))
        }
        return steps.reduce([root]) { values, step in values.flatMap { apply(step, to: $0) } }
    }

    private static func readBracket(_ input: inout Substring, field: String) throws -> String {
        var characters = ""
        var quote: Character?
        var escaped = false
        while let character = input.popFirst() {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let active = quote {
                if character == active { quote = nil }
            } else if ["'", "\""].contains(character) {
                quote = character
            } else if character == "]" {
                return characters
            }
            characters.append(character)
        }
        throw BookSourceError.invalidRule(field)
    }

    private static func apply(_ step: Step, to value: Any) -> [Any] {
        switch step {
        case .property(let name):
            return (value as? [String: Any])?[name].map { [$0] } ?? []
        case .index(let index):
            guard let values = value as? [Any] else { return [] }
            let index = index < 0 ? index + values.count : index
            return values.indices.contains(index) ? [values[index]] : []
        case .wildcard:
            return children(of: value)
        case .recursive(let name):
            let descendants = children(of: value)
            let direct = name == "*" ? descendants : apply(.property(name), to: value)
            return direct + descendants.flatMap { apply(step, to: $0) }
        case .union(let steps):
            return steps.flatMap { apply($0, to: value) }
        }
    }

    private static func children(of value: Any) -> [Any] {
        if let array = value as? [Any] { return array }
        if let dictionary = value as? [String: Any] { return dictionary.keys.sorted().compactMap { dictionary[$0] } }
        return []
    }
}
