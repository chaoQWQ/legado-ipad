import Foundation

// CSS selectors are translated to XPath so extraction has a single HTML tree and node model.
struct CSSSelector {
    static func xpath(_ selector: String, includingSelf: Bool, field: String) throws -> String {
        try splitRule(selector, separators: [","]).parts.map { group in
            var scanner = Scanner(group)
            var path = ""
            var axis = includingSelf ? "descendant-or-self::" : "descendant::"
            while !scanner.isAtEnd {
                _ = scanner.skipSpaces()
                let compound = try scanner.compound(field: field)
                path += (path.isEmpty ? "./" : "/") + axis + compound
                let spaced = scanner.skipSpaces()
                guard !scanner.isAtEnd else { break }
                switch scanner.current {
                case ">": axis = "child::"; scanner.advance()
                case "+": axis = "following-sibling::*[1]/self::"; scanner.advance()
                case "~": axis = "following-sibling::"; scanner.advance()
                default:
                    guard spaced else { throw BookSourceError.unsupported("CSS 选择器（\(field)）") }
                    axis = "descendant::"
                }
                _ = scanner.skipSpaces()
                guard !scanner.isAtEnd else { throw BookSourceError.invalidRule(field) }
            }
            guard !path.isEmpty else { throw BookSourceError.invalidRule(field) }
            return path
        }.joined(separator: " | ")
    }

    private struct Scanner {
        var input: Substring
        var current: Character? { input.first }
        var isAtEnd: Bool { input.isEmpty }

        init(_ input: String) { self.input = input[...] }

        mutating func advance() { _ = input.popFirst() }

        mutating func skipSpaces() -> Bool {
            let hasSpace = current?.isWhitespace == true
            while current?.isWhitespace == true { advance() }
            return hasSpace
        }

        mutating func identifier() -> String {
            var value = ""
            while let current {
                if current == "\\" {
                    advance()
                    guard let escaped = input.popFirst() else { break }
                    value.append(escaped)
                } else {
                    guard current.isLetter || current.isNumber || current == "-" || current == "_" else { break }
                    value.append(current)
                    advance()
                }
            }
            return value
        }

        mutating func compound(field: String) throws -> String {
            let tag: String
            if current == "*" {
                tag = "*"
                advance()
            } else {
                tag = identifier()
            }
            var predicates: [String] = []
            while let marker = current, [".", "#", "[", ":"].contains(marker) {
                advance()
                switch marker {
                case ".", "#":
                    let value = identifier()
                    guard !value.isEmpty else { throw BookSourceError.invalidRule(field) }
                    predicates.append(marker == "#" ? "@id = \(literal(value))" : classPredicate(value))
                case "[":
                    predicates.append(try attribute(field: field))
                default:
                    predicates.append(try pseudo(tag: tag, field: field))
                }
            }
            guard !tag.isEmpty || !predicates.isEmpty else { throw BookSourceError.invalidRule(field) }
            let node: String
            if tag.isEmpty || tag == "*" {
                node = "*"
            } else {
                node = "*[local-name() = \(literal(tag.lowercased()))]"
            }
            return node + predicates.map { "[\($0)]" }.joined()
        }

        mutating func attribute(field: String) throws -> String {
            _ = skipSpaces()
            let name = identifier()
            guard !name.isEmpty else { throw BookSourceError.invalidRule(field) }
            let path = "@*[local-name() = \(literal(name.lowercased()))]"
            _ = skipSpaces()
            if current == "]" {
                advance()
                return path
            }
            guard let marker = input.popFirst() else { throw BookSourceError.invalidRule(field) }
            if marker != "=" {
                guard ["~", "^", "$", "*", "|"].contains(marker), input.popFirst() == "=" else {
                    throw BookSourceError.unsupported("CSS 属性选择器（\(field)）")
                }
            }
            _ = skipSpaces()
            let value: String
            if let quote = current, quote == "\"" || quote == "'" {
                advance()
                var quoted = ""
                while let character = input.popFirst(), character != quote {
                    if character == "\\", let escaped = input.popFirst() {
                        quoted.append(escaped)
                    } else {
                        quoted.append(character)
                    }
                }
                value = quoted
            } else {
                value = identifier()
            }
            _ = skipSpaces()
            guard input.popFirst() == "]" else { throw BookSourceError.invalidRule(field) }
            let quoted = literal(value)
            switch marker {
            case "=": return "\(path) = \(quoted)"
            case "^": return "\(path) and starts-with(\(path), \(quoted))"
            case "*": return "\(path) and contains(\(path), \(quoted))"
            case "$": return "\(path) and substring(\(path), string-length(\(path)) - string-length(\(quoted)) + 1) = \(quoted)"
            case "~": return "contains(concat(' ', normalize-space(\(path)), ' '), \(literal(" \(value) ")))"
            default: return "\(path) = \(quoted) or starts-with(\(path), \(literal(value + "-")))"
            }
        }

        mutating func pseudo(tag: String, field: String) throws -> String {
            let name = identifier().lowercased()
            switch name {
            case "first-child": return "not(preceding-sibling::*)"
            case "last-child": return "not(following-sibling::*)"
            case "only-child": return "not(preceding-sibling::* or following-sibling::*)"
            case "empty": return "not(* or text())"
            default: break
            }
            guard input.popFirst() == "(", let end = input.firstIndex(of: ")") else {
                throw BookSourceError.unsupported("CSS 伪类 :\(name)")
            }
            let argument = String(input[..<end]).trimmed
            input = input[input.index(after: end)...]
            switch name {
            case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type":
                let previous = !name.contains("last")
                let siblings = previous ? "preceding-sibling::" : "following-sibling::"
                let typed = name.contains("of-type")
                guard !typed || (!tag.isEmpty && tag != "*") else { throw BookSourceError.unsupported("CSS 伪类 :\(name)") }
                let nodes = typed ? "*[local-name() = \(literal(tag.lowercased()))]" : "*"
                return try nth(argument, position: "(count(\(siblings)\(nodes)) + 1)", field: field)
            case "not":
                var selector = Scanner(argument)
                let excluded = try selector.compound(field: field)
                guard selector.isAtEnd else { throw BookSourceError.unsupported("CSS 复合排除选择器") }
                return "not(self::\(excluded))"
            case "contains", "containsown":
                let text = unquote(argument)
                if name == "containsown" { return "text()[contains(., \(literal(text)))]" }
                return "contains(., \(literal(text)))"
            default:
                throw BookSourceError.unsupported("CSS 伪类 :\(name)")
            }
        }

        private func nth(_ argument: String, position: String, field: String) throws -> String {
            let pattern = argument.filter { !$0.isWhitespace }.lowercased()
            if let value = Int(pattern) { return "\(position) = \(value)" }
            if pattern == "odd" { return "\(position) mod 2 = 1" }
            if pattern == "even" { return "\(position) mod 2 = 0" }
            let terms = pattern.split(separator: "n", omittingEmptySubsequences: false)
            guard terms.count == 2 else { throw BookSourceError.invalidRule(field) }
            let factor = terms[0].isEmpty || terms[0] == "+" ? 1 : terms[0] == "-" ? -1 : Int(terms[0])
            let offset = terms[1].isEmpty ? 0 : Int(terms[1])
            guard let factor, let offset, factor != Int.min else { throw BookSourceError.invalidRule(field) }
            if factor == 0 { return "\(position) = \(offset)" }
            let bound = factor > 0 ? ">=" : "<="
            return "\(position) \(bound) \(offset) and (\(position) - (\(offset))) mod \(abs(factor)) = 0"
        }
    }

    static func classPredicate(_ value: String) -> String {
        "contains(concat(' ', normalize-space(@class), ' '), \(literal(" \(value) ")))"
    }

    static func literal(_ value: String) -> String {
        if !value.contains("'") { return "'\(value)'" }
        if !value.contains("\"") { return "\"\(value)\"" }
        return "concat(" + value.components(separatedBy: "'").map { "'\($0)'" }.joined(separator: ", \"'\", ") + ")"
    }

    private static func unquote(_ value: String) -> String {
        guard let first = value.first, ["'", "\""].contains(first), value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }
}
