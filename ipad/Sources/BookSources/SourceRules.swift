import CoreFoundation
import Foundation

enum RuleValue {
    case html(HTMLNode)
    case json(Any)
    case scalar(String)

    static func document(_ text: String) throws -> Self {
        let trimmed = text.trimmed
        if let initial = trimmed.first, initial == "{" || initial == "[",
           let data = trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            return .json(json)
        }
        return .html(try HTMLDocument(trimmed).root)
    }

    func select(_ rule: String?, field: String) throws -> [Self] {
        guard let rule = rule?.nilIfBlank else { throw BookSourceError.missingRule(field) }
        return try evaluate(rule, field: field, selectsNodes: true).flatMap { value in
            if case .json(let array as [Any]) = value { return array.map(Self.json) }
            return [value]
        }
    }

    func strings(_ rule: String?, field: String) throws -> [String] {
        guard let rule = rule?.nilIfBlank else { return [] }
        return try evaluate(rule, field: field, selectsNodes: false).flatMap(\.stringValues).compactMap(\.nilIfBlank)
    }

    func string(_ rule: String?, field: String) throws -> String {
        try strings(rule, field: field).joined(separator: "\n")
    }

    private var stringValues: [String] {
        switch self {
        case .scalar(let value): return [value]
        case .html(let node): return [node.text]
        case .json(let string as String): return [string]
        case .json(let number as NSNumber):
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return [number.boolValue ? "true" : "false"] }
            return [number.stringValue]
        case .json(let array as [Any]): return array.flatMap { Self.json($0).stringValues }
        default: return []
        }
    }

    private func evaluate(_ rule: String, field: String, selectsNodes: Bool) throws -> [Self] {
        guard rule.utf8.count <= 8_192 else { throw BookSourceError.invalidRule(field) }
        try rejectDynamicRule(rule)
        if rule.contains("{{"), rule.contains("}}") { throw BookSourceError.unsupported("内嵌规则或 JavaScript（\(field)）") }
        let terms = rule.components(separatedBy: "##")
        let selector = terms[0].trimmed
        let replacement = terms.count > 1 ? try RuleReplacement(terms, field: field) : nil
        let selected: [Self]
        if selector.isEmpty, replacement != nil {
            selected = [self]
        } else {
            selected = try query(selector, field: field, selectsNodes: selectsNodes)
        }
        guard let replacement else { return selected }
        guard !selectsNodes else { throw BookSourceError.unsupported("列表正则替换（\(field)）") }
        return selected.flatMap(\.stringValues).map { .scalar(replacement.apply($0)) }
    }

    private func query(_ expression: String, field: String, selectsNodes: Bool, depth: Int = 0) throws -> [Self] {
        guard depth < 24 else { throw BookSourceError.invalidRule(field) }
        let mode: Mode?
        let raw: String
        if let explicit = Mode.prefix(in: expression) {
            mode = explicit
            raw = String(expression.dropFirst(explicit.prefix.count)).trimmed
        } else {
            mode = nil
            raw = expression
        }
        guard !raw.isEmpty else { throw BookSourceError.invalidRule(field) }
        let group = splitRule(raw, separators: ["||", "&&", "%%"])
        if let operation = group.separator {
            var values: [[Self]] = []
            for term in group.parts {
                let prefixed = Mode.prefix(in: term) == nil ? (mode?.prefix ?? "") + term : term
                let matches = try query(prefixed, field: field, selectsNodes: selectsNodes, depth: depth + 1)
                if operation == "||" {
                    let nonempty = selectsNodes ? !matches.isEmpty : matches.contains { $0.stringValues.contains { !$0.trimmed.isEmpty } }
                    if nonempty { return matches }
                } else {
                    values.append(matches)
                }
            }
            if operation == "%%" {
                let count = values.map(\.count).max() ?? 0
                return (0..<count).flatMap { index in values.compactMap { $0.indices.contains(index) ? $0[index] : nil } }
            }
            return values.flatMap { $0 }
        }
        switch self {
        case .html(let node):
            if mode == .xpath || (mode == nil && (raw.hasPrefix("/") || raw.hasPrefix("./"))) {
                let scoped = raw.hasPrefix("//") && node.pointer != node.document.root.pointer ? "." + raw : raw
                return try node.xpath(scoped, field: field)
            }
            if mode == .json { throw BookSourceError.invalidRule(field) }
            if raw.hasPrefix(":") { throw BookSourceError.unsupported("列表正则提取（\(field)）") }
            return try htmlMatches(raw, in: node, explicitCSS: mode == .css, field: field, selectsNodes: selectsNodes)
        case .json(let value):
            guard mode == nil || mode == .json else { throw BookSourceError.invalidRule(field) }
            return try JSONPath.values(raw, in: value, field: field).map(Self.json)
        case .scalar:
            return raw == "." || raw == "text" ? [self] : []
        }
    }

    private func htmlMatches(
        _ raw: String, in node: HTMLNode, explicitCSS: Bool, field: String, selectsNodes: Bool
    ) throws -> [Self] {
        var terms = splitRule(raw, separators: ["@"]).parts
        var output = "text"
        if !selectsNodes, let last = terms.last {
            let explicitOutput = terms.count > 1 || last.range(of: #"^[a-zA-Z][\w:-]*$"#, options: .regularExpression) != nil
            if explicitOutput && (!explicitCSS || terms.count > 1) {
                output = last
                terms.removeLast()
            }
        }
        if terms == ["."] { terms = [] }
        var values: [Self] = [.html(node)]
        for term in terms {
            values = try values.flatMap { value -> [Self] in
                guard case .html(let current) = value else { return [] }
                if explicitCSS {
                    return try current.xpath(CSSSelector.xpath(term, includingSelf: true, field: field), field: field)
                }
                let indexed = SelectorIndex(term)
                let expression = try legacySelector(indexed.selector, field: field)
                return indexed.filter(try current.xpath(expression, field: field))
            }
        }
        guard !selectsNodes else { return values }
        return values.map { value in
            guard case .html(let node) = value else { return value }
            switch output {
            case "text": return .scalar(node.text)
            case "ownText": return .scalar(node.ownText.joined(separator: " "))
            case "textNodes": return .scalar(node.ownText.joined(separator: "\n"))
            case "html", "all": return .scalar(node.markup)
            default: return .scalar(node.attribute(output.lowercased()))
            }
        }
    }

    private func legacySelector(_ selector: String, field: String) throws -> String {
        let parts = selector.split(separator: ".", maxSplits: 1).map(String.init)
        if selector.isEmpty || selector == "children" { return "./*" }
        if parts.count == 2 {
            switch parts[0] {
            case "id": return "./descendant-or-self::*[@id = \(CSSSelector.literal(parts[1]))]"
            case "class": return "./descendant-or-self::*[\(CSSSelector.classPredicate(parts[1]))]"
            case "tag": return "./descendant-or-self::*[local-name() = \(CSSSelector.literal(parts[1].lowercased()))]"
            case "text": return "./descendant-or-self::*[text()[contains(., \(CSSSelector.literal(parts[1])))] ]"
            default: break
            }
        }
        return try CSSSelector.xpath(selector, includingSelf: true, field: field)
    }

    private enum Mode: CaseIterable {
        case xpath, json, css, legacy

        var prefix: String {
            switch self {
            case .xpath: "@xpath:"
            case .json: "@json:"
            case .css: "@css:"
            case .legacy: "@@"
            }
        }

        static func prefix(in value: String) -> Self? {
            allCases.first { value.lowercased().hasPrefix($0.prefix) }
        }
    }
}

private struct SelectorIndex {
    let selector: String
    let indexes: [String]
    let excludes: Bool

    init(_ term: String) {
        let bracket = term.range(of: #"\[!?[-0-9,:\s]+\]$"#, options: .regularExpression)
        let suffix = term.range(of: #"[.!]-?\d+(?::-?\d+)*$"#, options: .regularExpression)
        if let bracket {
            let body = term[bracket].dropFirst().dropLast()
            excludes = body.hasPrefix("!")
            indexes = (excludes ? body.dropFirst() : body).split(separator: ",").map { String($0).trimmed }
            selector = String(term[..<bracket.lowerBound])
        } else if let suffix {
            let body = term[suffix]
            excludes = body.hasPrefix("!")
            indexes = body.dropFirst().split(separator: ":").map(String.init)
            selector = String(term[..<suffix.lowerBound])
        } else {
            selector = term
            indexes = []
            excludes = false
        }
    }

    func filter<T>(_ values: [T]) -> [T] {
        guard !indexes.isEmpty, !values.isEmpty else { return values }
        var seen = Set<Int>()
        let maxIndex = values.count - 1
        func normalize(_ index: Int) -> Int { index < 0 ? values.count + index : index }
        let picks = indexes.flatMap { position -> [Int] in
            if let single = Int(position) { return values.indices.contains(normalize(single)) ? [normalize(single)] : [] }
            let range = position.split(separator: ":", omittingEmptySubsequences: false).map { Int(String($0).trimmed) }
            guard (2...3).contains(range.count) else { return [] }
            let start = min(max(normalize(range[0] ?? 0), 0), maxIndex)
            let end = min(max(normalize(range[1] ?? -1), 0), maxIndex)
            let rawStep = range.count == 3 ? range[2] ?? 1 : 1
            let step = max(1, min(rawStep, values.count))
            return start <= end ? Array(stride(from: start, through: end, by: step))
                : Array(stride(from: start, through: end, by: -step))
        }.filter { seen.insert($0).inserted }
        if excludes { return values.enumerated().compactMap { seen.contains($0.offset) ? nil : $0.element } }
        return picks.map { values[$0] }
    }
}

private struct RuleReplacement {
    let regex: NSRegularExpression
    let replacement: String
    let firstOnly: Bool

    init(_ parts: [String], field: String) throws {
        guard (2...4).contains(parts.count), !parts[1].isEmpty,
              let regex = try? NSRegularExpression(pattern: parts[1]) else {
            throw BookSourceError.invalidRule(field)
        }
        self.regex = regex
        replacement = parts.count > 2 ? parts[2] : ""
        firstOnly = parts.count == 4
    }

    func apply(_ value: String) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        if firstOnly {
            guard let match = regex.firstMatch(in: value, range: range) else { return "" }
            return regex.replacementString(for: match, in: value, offset: 0, template: replacement)
        }
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}

func applyReplacement(_ rule: String?, to text: String) throws -> String {
    guard let rule = rule?.nilIfBlank else { return text }
    try rejectDynamicRule(rule)
    guard rule.hasPrefix("##") else { throw BookSourceError.unsupported("非正则正文替换") }
    return try RuleReplacement(rule.components(separatedBy: "##"), field: "正文替换").apply(text)
}

func splitRule(_ value: String, separators: [String]) -> (parts: [String], separator: String?) {
    var tokens: [String] = []
    var remaining = value[...]
    var token = ""
    var separator: String?
    var quote: Character?
    var depth = 0
    while let char = remaining.first {
        if char == "\\" {
            token.append(remaining.removeFirst())
            if let escaped = remaining.popFirst() { token.append(escaped) }
            continue
        }
        if let active = quote {
            if char == active { quote = nil }
        } else if char == "\"" || char == "'" {
            quote = char
        } else if char == "[" || char == "(" {
            depth += 1
        } else if char == "]" || char == ")" {
            depth = max(0, depth - 1)
        } else if depth == 0, let next = separators.first(where: { remaining.hasPrefix($0) }), separator == nil || separator == next {
            separator = next
            tokens.append(token.trimmed)
            token = ""
            remaining = remaining.dropFirst(next.count)
            continue
        }
        token.append(remaining.removeFirst())
    }
    tokens.append(token.trimmed)
    return (tokens, separator)
}
