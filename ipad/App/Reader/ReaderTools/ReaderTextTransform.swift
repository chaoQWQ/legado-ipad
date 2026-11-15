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

    init(original: String, rules: [ReaderReplacementRule], script: ReaderScript = .off) {
        let length = original.utf16.count
        var display = script.convert(original)
        var stages: [[Edit]] = []
        if script != .off, original != display {
            let scriptEdits = Self.scriptEdits(from: original, to: display)
            if !scriptEdits.isEmpty { stages.append(scriptEdits) }
        }

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

    private static func scriptEdits(from original: String, to display: String) -> [Edit] {
        // The system conversion keeps line separators. Track UTF-16 widths
        // inside each line, since some Han glyphs map to supplementary scalars.
        let sourceLines = original.split(separator: "\n", omittingEmptySubsequences: false)
        let targetLines = display.split(separator: "\n", omittingEmptySubsequences: false)
        guard sourceLines.count == targetLines.count else {
            return [Edit(source: NSRange(location: 0, length: original.utf16.count),
                         destination: NSRange(location: 0, length: display.utf16.count))]
        }
        var sourceStart = 0
        var targetStart = 0
        var edits: [Edit] = []
        for (source, target) in zip(sourceLines, targetLines) {
            let sourceLength = source.utf16.count
            let targetLength = target.utf16.count
            if source != target {
                if source.unicodeScalars.count == target.unicodeScalars.count {
                    var sourceOffset = sourceStart
                    var targetOffset = targetStart
                    for (from, to) in zip(source.unicodeScalars, target.unicodeScalars) {
                        let fromWidth = from.value <= 0xFFFF ? 1 : 2
                        let toWidth = to.value <= 0xFFFF ? 1 : 2
                        if fromWidth != toWidth {
                            edits.append(Edit(source: NSRange(location: sourceOffset, length: fromWidth),
                                              destination: NSRange(location: targetOffset, length: toWidth)))
                        }
                        sourceOffset += fromWidth
                        targetOffset += toWidth
                    }
                } else {
                    edits.append(Edit(source: NSRange(location: sourceStart, length: sourceLength),
                                      destination: NSRange(location: targetStart, length: targetLength)))
                }
            }
            sourceStart += sourceLength + 1
            targetStart += targetLength + 1
        }
        return edits
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
