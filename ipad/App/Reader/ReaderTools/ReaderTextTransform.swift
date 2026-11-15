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

struct ReaderInlineImage: Equatable {
    let originalOffset: Int
    let url: URL
}

struct ReaderDisplayImage: Equatable {
    let location: Int
    let url: URL
}

struct ReaderTextTransform {
    let text: String
    let images: [ReaderDisplayImage]

    private struct Edit {
        let source: NSRange
        let destination: NSRange
    }

    private let originalLength: Int
    private let steps: [[Edit]]
    private let scriptStageCount: Int
    private let imageEdits: [Edit]

    init(
        original: String, rules: [ReaderReplacementRule], script: ReaderScript = .off, images: [ReaderInlineImage] = []
    ) {
        let length = original.utf16.count
        var display = script.convert(original)
        var stages: [[Edit]] = []
        if script != .off, original != display {
            let scriptEdits = Self.scriptEdits(from: original, to: display)
            if !scriptEdits.isEmpty { stages.append(scriptEdits) }
        }
        scriptStageCount = stages.count

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

        let decorations = Self.insertImages(images, into: display, originalLength: length, through: stages)
        text = decorations.text
        self.images = decorations.images
        originalLength = length
        steps = stages
        imageEdits = decorations.edits
    }

    private static func insertImages(
        _ images: [ReaderInlineImage], into text: String, originalLength: Int, through stages: [[Edit]]
    ) -> (text: String, images: [ReaderDisplayImage], edits: [Edit]) {
        guard !images.isEmpty else { return (text, [], []) }
        let source = text as NSString
        let placements = images
            .filter { (0...originalLength).contains($0.originalOffset) }
            .map { image in
                let mapped = stages.reduce(image.originalOffset) { offset, edits in
                    map(offset, through: edits, from: \.source, to: \.destination)
                }
                let location = min(max(0, mapped), source.length)
                guard location < source.length else { return (location: location, url: image.url) }
                let character = source.rangeOfComposedCharacterSequence(at: location)
                return (location: character.location == location ? location : NSMaxRange(character), url: image.url)
            }
            .sorted { $0.location < $1.location }
        var cursor = 0
        var delta = 0
        var chunks: [String] = []
        var attachments: [ReaderDisplayImage] = []
        var edits: [Edit] = []
        for placement in placements {
            let location = placement.location
            if location > cursor {
                chunks.append(source.substring(with: NSRange(location: cursor, length: location - cursor)))
            }
            let followsLineBreak = location == 0 || cursor == location && !edits.isEmpty
                || UnicodeScalar(source.character(at: location - 1)).map(CharacterSet.newlines.contains) == true
            let prefix = followsLineBreak ? 0 : 1
            let added = followsLineBreak ? "\u{FFFC}\n" : "\n\u{FFFC}\n"
            let addedLength = 2 + prefix
            attachments.append(ReaderDisplayImage(location: location + delta + prefix, url: placement.url))
            edits.append(Edit(
                source: NSRange(location: location, length: 0),
                destination: NSRange(location: location + delta, length: addedLength)
            ))
            chunks.append(added)
            cursor = location
            delta += addedLength
        }
        chunks.append(source.substring(from: cursor))
        return (chunks.joined(), attachments, edits)
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

    func displayOffset(forOriginal offset: Int, beforeInlineImages: Bool = false) -> Int {
        let base = steps.reduce(min(max(0, offset), originalLength)) { offset, edits in
            Self.map(offset, through: edits, from: \.source, to: \.destination)
        }
        if beforeInlineImages, let image = imageEdits.first(where: { $0.source.location == base }) {
            return image.destination.location
        }
        return Self.map(base, through: imageEdits, from: \.source, to: \.destination)
    }

    func originalOffset(forDisplay offset: Int) -> Int {
        let base = Self.map(min(max(0, offset), text.utf16.count), through: imageEdits, from: \.destination, to: \.source)
        return steps.reversed().reduce(base) { offset, edits in
            Self.map(offset, through: edits, from: \.destination, to: \.source)
        }
    }

    func originalReadingRanges(forDisplay range: NSRange) -> [NSRange] {
        let length = text.utf16.count
        guard range.location >= 0, range.location <= length, range.length > 0,
              range.length <= length - range.location else { return [] }
        var ranges = Self.sourceRanges(visible: range, undoing: imageEdits)
        for edits in steps.dropFirst(scriptStageCount).reversed() {
            ranges = ranges.flatMap { Self.sourceRanges(visible: $0, undoing: edits) }
        }
        for edits in steps.prefix(scriptStageCount).reversed() {
            ranges = ranges.flatMap { Self.sourceRanges(visible: $0, undoing: edits, includeConvertedText: true) }
        }
        return ranges
    }

    private static func sourceRanges(
        visible: NSRange, undoing edits: [Edit], includeConvertedText: Bool = false
    ) -> [NSRange] {
        guard !edits.isEmpty else { return [visible] }
        let visibleEnd = NSMaxRange(visible)
        var sourceCursor = 0
        var displayCursor = 0
        var result: [NSRange] = []

        func appendUnchanged(upTo displayEnd: Int) {
            let start = max(visible.location, displayCursor)
            let end = min(visibleEnd, displayEnd)
            if end > start {
                result.append(NSRange(location: sourceCursor + start - displayCursor, length: end - start))
            }
        }

        for edit in edits {
            appendUnchanged(upTo: edit.destination.location)
            if edit.destination.location >= visibleEnd { return result }
            if includeConvertedText, edit.destination.length > 0,
               visible.location <= edit.destination.location, NSMaxRange(edit.destination) <= visibleEnd {
                result.append(edit.source)
            }
            sourceCursor = NSMaxRange(edit.source)
            displayCursor = NSMaxRange(edit.destination)
        }
        appendUnchanged(upTo: visibleEnd)
        return result
    }

    private static func map(
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
