import Foundation

struct ReaderReplacementRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var find: String = ""
    var replacement: String = ""
    var isEnabled = true

    static func storageKey(bookID: UUID) -> String {
        "reader.replacements.\(bookID.uuidString)"
    }

    static func decode(_ data: Data) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }

    static func encode(_ rules: [Self]) -> Data? {
        try? JSONEncoder().encode(rules)
    }
}

struct ReaderTextTransform {
    let text: String

    private struct Edit {
        let source: NSRange
        let destination: NSRange
    }

    private let originalLength: Int
    private let steps: [[Edit]]

    init(original: String, rules: [ReaderReplacementRule]) {
        let length = original.utf16.count
        var display = original
        var stages: [[Edit]] = []

        for rule in rules where rule.isEnabled && !rule.find.isEmpty && rule.find != rule.replacement {
            let source = display as NSString
            let replacementLength = rule.replacement.utf16.count
            var cursor = 0
            var delta = 0
            var edits: [Edit] = []

            while cursor < source.length {
                let search = NSRange(location: cursor, length: source.length - cursor)
                let match = source.range(of: rule.find, options: .literal, range: search)
                guard match.location != NSNotFound, match.length > 0 else { break }

                edits.append(Edit(
                    source: match,
                    destination: NSRange(location: match.location + delta, length: replacementLength)
                ))
                cursor = NSMaxRange(match)
                delta += replacementLength - match.length
            }

            guard !edits.isEmpty else { continue }
            var chunks: [String] = []
            cursor = 0
            for edit in edits {
                if cursor < edit.source.location {
                    chunks.append(source.substring(with: NSRange(
                        location: cursor, length: edit.source.location - cursor
                    )))
                }
                chunks.append(rule.replacement)
                cursor = NSMaxRange(edit.source)
            }
            if cursor < source.length { chunks.append(source.substring(from: cursor)) }
            display = chunks.joined()
            stages.append(edits)
        }

        text = display
        originalLength = length
        steps = stages
    }

    func displayOffset(forOriginal offset: Int) -> Int {
        steps.reduce(min(max(0, offset), originalLength)) { offset, edits in
            map(offset, through: edits, from: \.source, to: \.destination)
        }
    }

    func originalOffset(forDisplay offset: Int) -> Int {
        steps.reversed().reduce(min(max(0, offset), text.utf16.count)) { offset, edits in
            map(offset, through: edits, from: \.destination, to: \.source)
        }
    }

    private func map(
        _ offset: Int,
        through edits: [Edit],
        from source: KeyPath<Edit, NSRange>,
        to destination: KeyPath<Edit, NSRange>
    ) -> Int {
        var lower = 0
        var upper = edits.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if edits[middle][keyPath: source].location <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return offset }

        let edit = edits[lower - 1]
        let from = edit[keyPath: source]
        let to = edit[keyPath: destination]
        if offset >= NSMaxRange(from) {
            // Adjacent deletions can collapse to the same display offset. The
            // end of the last deletion is the first remaining reading position.
            return NSMaxRange(to) + offset - NSMaxRange(from)
        }
        return to.location + (offset - from.location) * to.length / from.length
    }
}
