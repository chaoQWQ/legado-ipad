import SwiftUI

enum ReaderPageMode: String, CaseIterable, Identifiable, Codable {
    case cover
    case weread
    case slide
    case curl
    case scroll
    case none

    var id: Self { self }

    var title: String {
        switch self {
        case .cover: "覆盖"
        case .weread: "微读"
        case .slide: "滑动"
        case .curl: "仿真"
        case .scroll: "滚动"
        case .none: "无动画"
        }
    }
}

enum ReaderPageDirection: Equatable {
    case previous
    case next
}

struct ReaderInteractionPreferences: Equatable {
    var allowsTextSelection = true
    var tapPrevious: ReaderTapAction = .previousPage
    var tapCenter: ReaderTapAction = .showControls
    var tapNext: ReaderTapAction = .nextPage
    var tapTop: ReaderTapAction = .showControls
    var tapBottom: ReaderTapAction = .showControls
    var swipeThreshold = 0.0
    var animatesScrollTaps = true

    func tapAction(at point: CGPoint, in size: CGSize, mode: ReaderPageMode) -> ReaderTapAction {
        if point.x < size.width / 3 { return tapPrevious }
        if point.x > size.width * 2 / 3 { return tapNext }
        if point.y < size.height / 3 { return mode == .scroll ? tapPrevious : tapTop }
        if point.y > size.height * 2 / 3 { return mode == .scroll ? tapNext : tapBottom }
        return tapCenter
    }
}

#if os(iOS)
import UIKit

/// Splits the single TextKit container on line boundaries. Each page starts
/// exactly where the previous one ended, including wrapped paragraphs.
@MainActor
final class ReaderPageLayout {
    struct Page {
        let glyphs: NSRange
        let characters: NSRange
        let top: CGFloat
        let bottom: CGFloat
    }

    private let manager: NSLayoutManager
    private let container: NSTextContainer
    private let height: CGFloat
    private let glyphCount: Int
    private var pages: [Page] = []

    init(manager: NSLayoutManager, container: NSTextContainer, height: CGFloat) {
        self.manager = manager
        self.container = container
        self.height = max(1, height)
        glyphCount = manager.numberOfGlyphs
    }

    func page(at index: Int) -> Page? {
        guard index >= 0 else { return nil }
        while pages.count <= index, appendPage() {}
        return pages.indices.contains(index) ? pages[index] : nil
    }

    func pageIndex(containing offset: Int) -> Int {
        while (pages.last.map { NSMaxRange($0.characters) <= offset } ?? true), appendPage() {}
        var lower = 0
        var upper = pages.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(pages[middle].characters) <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return min(lower, max(0, pages.count - 1))
    }

    private func appendPage() -> Bool {
        let start = pages.last.map { NSMaxRange($0.glyphs) } ?? 0
        guard start < glyphCount, manager.textContainer(forGlyphAt: start, effectiveRange: nil) === container else {
            return false
        }

        var lineRange = NSRange()
        let firstLine = manager.lineFragmentRect(forGlyphAt: start, effectiveRange: &lineRange)
        let top = start == 0 ? 0 : firstLine.minY
        let limit = top + height
        var bottom = firstLine.maxY
        var end = min(glyphCount, max(start + 1, NSMaxRange(lineRange)))

        while end < glyphCount {
            let line = manager.lineFragmentRect(forGlyphAt: end, effectiveRange: &lineRange)
            let next = NSMaxRange(lineRange)
            guard next > end, line.maxY <= limit + 0.25 else { break }
            end = min(glyphCount, next)
            bottom = line.maxY
        }

        let glyphs = NSRange(location: start, length: end - start)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        pages.append(Page(glyphs: glyphs, characters: characters, top: top, bottom: bottom))
        return true
    }
}
#endif
