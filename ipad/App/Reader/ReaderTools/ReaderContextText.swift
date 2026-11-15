import Foundation

enum ReaderContextText {
    /// Returns only text inside the approved UTF-16 range. Do not expand an
    /// excerpt across a grapheme boundary into text outside that range.
    static func excerpt(in text: String, from lower: Int, to upper: Int) -> String? {
        let source = text as NSString
        guard 0 <= lower, lower < upper, upper <= source.length else { return nil }
        let first = source.rangeOfComposedCharacterSequence(at: lower)
        let last = source.rangeOfComposedCharacterSequence(at: upper - 1)
        let start = first.location < lower ? NSMaxRange(first) : lower
        let end = NSMaxRange(last) > upper ? last.location : upper
        guard start < end else { return nil }
        let excerpt = source.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return excerpt.isEmpty ? nil : excerpt
    }
}
