import CoreFoundation
import Foundation

enum TextBookParser {
    // Recognize the usual Legado heading styles plus English chapter headings.
    private static let headingPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:第\s{0,4}[0-9０-９〇零一二两兩三四五六七八九十百千万萬壹贰貳叁參肆伍陆陸柒捌玖拾佰仟]+\s{0,4}(?:章|节(?!课)|節(?!課)|卷|回|部(?![分赛賽])|篇)|序章|序言|前言|楔子|引子|终章|終章|后记|後記|尾声|尾聲|番外).{0,36}|[0-9０-９〇零一二两兩三四五六七八九十百千万萬]{1,8}[、.．:：—_\-].{1,30}|(?:Chapter|Part|Book)\s+[0-9IVXLCDM]+\b.{0,60}|Prologue|Epilogue)$"#,
        options: .caseInsensitive
    )

    static func read(_ data: Data, title: String) throws -> LocalBook {
        guard let text = decode(data),
              !text.unicodeScalars.contains(where: { $0.value < 32 && !(9...13).contains($0.value) }) else {
            throw LocalBookImportError.unreadableText
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{000C}", with: "\n\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalBookImportError.emptyBook
        }

        var chapters: [LocalChapter] = []
        var chapterTitle: String?
        var contentStart = normalized.startIndex
        var lineStart = normalized.startIndex

        while lineStart < normalized.endIndex {
            try Task.checkCancellation()
            let lineEnd = normalized[lineStart...].firstIndex(of: "\n") ?? normalized.endIndex
            let nextLine = lineEnd < normalized.endIndex ? normalized.index(after: lineEnd) : lineEnd
            let line = normalized[lineStart..<lineEnd]
            // Check the length first to avoid allocating copies of long unbroken prose.
            if line.utf16.count <= 128 {
                let candidate = line.trimmingCharacters(in: .whitespaces)
                if headingPattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil {
                    appendChapters(normalized[contentStart..<lineStart], title: chapterTitle, to: &chapters)
                    chapterTitle = candidate
                    contentStart = nextLine
                }
            }
            lineStart = nextLine
        }
        appendChapters(normalized[contentStart...], title: chapterTitle, to: &chapters)
        guard chapters.contains(where: { !$0.text.isEmpty }) else {
            throw LocalBookImportError.emptyBook
        }
        return LocalBook(title: title, chapters: chapters)
    }

    static func appendChapters(
        _ content: Substring,
        title: String?,
        to chapters: inout [LocalChapter]
    ) {
        var start = content.startIndex
        var part = 1
        let limit = title == nil ? 10_000 : 32_000
        while start < content.endIndex {
            var end = content.index(start, offsetBy: limit, limitedBy: content.endIndex) ?? content.endIndex
            if end < content.endIndex,
               let lineBreak = content[start..<end].lastIndex(of: "\n"),
               content.distance(from: start, to: lineBreak) >= limit / 2 {
                end = content.index(after: lineBreak)
            }
            let text = content[start..<end].trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let baseTitle = title ?? (chapters.isEmpty && end == content.endIndex ? "正文" : "第\(chapters.count + 1)节")
                let label = part > 1 && title != nil ? "\(baseTitle)（\(part)）" : baseTitle
                chapters.append(LocalChapter(title: label, text: text))
                part += 1
            }
            start = end
        }
        if part == 1, let title {
            chapters.append(LocalChapter(title: title, text: ""))
        }
    }

    static func decode(_ data: Data) -> String? {
        let prefix = Array(data.prefix(4))
        let encodings: [([UInt8], String.Encoding)] = [
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian)
        ]
        for (bom, encoding) in encodings where prefix.starts(with: bom) {
            return String(data: data.dropFirst(bom.count), encoding: encoding)
        }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.utf8.contains(0) {
            return utf8
        }

        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        let candidates = [gb18030, big5, String.Encoding.utf16LittleEndian.rawValue, String.Encoding.utf16BigEndian.rawValue]
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: candidates,
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        guard candidates.contains(encoding) else { return nil }
        return converted as String?
    }
}
