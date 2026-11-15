import SwiftUI

struct ReaderScrollRequest: Equatable {
    enum Target: Equatable {
        case offset(Int)
        case reveal(Int)
    }

    let id = UUID()
    let target: Target
}

#if os(iOS)
import UIKit

struct ReaderTextPane: UIViewRepresentable {
    let text: String
    let typography: ReaderTypography
    let initialOffset: Int
    let request: ReaderScrollRequest?
    let highlight: NSRange?
    let automaticSpeed: Double?
    let onScroll: (Int) -> Void
    let onAutomaticEnd: () -> Void

    func makeUIView(context: Context) -> ReadingTextView {
        let view = ReadingTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = false
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = UIEdgeInsets(top: 14, left: 24, bottom: 28, right: 24)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.onReveal = { [weak coordinator = context.coordinator] offset in
            coordinator?.report(offset)
        }
        view.onAutomaticEnd = { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.report(view.anchorOffset, automaticEnd: true) }
        }
        view.replace(text, typography: typography, at: initialOffset)
        context.coordinator.text = text
        context.coordinator.typography = typography
        return view
    }

    func updateUIView(_ view: ReadingTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScroll = onScroll
        coordinator.onAutomaticEnd = onAutomaticEnd
        let textChanged = coordinator.text != text
        let typographyChanged = coordinator.typography != typography
        if textChanged || typographyChanged {
            view.replace(text, typography: typography, at: textChanged ? initialOffset : view.anchorOffset)
            coordinator.text = text
            coordinator.typography = typography
        }
        if textChanged || typographyChanged || coordinator.highlight != highlight {
            view.updateHighlight(highlight, palette: typography.palette)
            coordinator.highlight = highlight
        }
        if let request, coordinator.request != request {
            coordinator.request = request
            if case .offset = request.target { coordinator.discardPendingScroll() }
            view.seek(to: request.target)
        }
        view.setAutomaticSpeed(automaticSpeed)
    }

    static func dismantleUIView(_ view: ReadingTextView, coordinator: Coordinator) {
        view.setAutomaticSpeed(nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll, onAutomaticEnd: onAutomaticEnd)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: String?
        var typography: ReaderTypography?
        var request: ReaderScrollRequest?
        var highlight: NSRange?
        var onScroll: (Int) -> Void
        var onAutomaticEnd: () -> Void
        private var lastOffset: Int?
        private var pendingOffset: Int?
        private var pendingEnd = false
        private var reportScheduled = false

        init(onScroll: @escaping (Int) -> Void, onAutomaticEnd: @escaping () -> Void) {
            self.onScroll = onScroll
            self.onAutomaticEnd = onAutomaticEnd
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? ReadingTextView, let offset = view.readingOffsetAfterScroll else { return }
            view.anchorOffset = offset
            report(offset)
        }

        func report(_ offset: Int, automaticEnd: Bool = false) {
            pendingOffset = offset
            pendingEnd = pendingEnd || automaticEnd
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.publishReport()
            }
        }

        func discardPendingScroll() {
            lastOffset = nil
            pendingOffset = nil
            pendingEnd = false
        }

        private func publishReport() {
            reportScheduled = false
            if let pendingOffset, pendingOffset != lastOffset {
                lastOffset = pendingOffset
                onScroll(pendingOffset)
            }
            if pendingEnd {
                pendingEnd = false
                onAutomaticEnd()
            }
        }
    }
}

final class ReadingTextView: UITextView {
    var anchorOffset = 0
    var onReveal: ((Int) -> Void)?
    var onAutomaticEnd: (() -> Void)?
    private var pendingTarget: ReaderScrollRequest.Target?
    private var lastLayoutSize: CGSize = .zero
    private var displayLink: CADisplayLink?
    private var automaticSpeed: Double?
    private var highlight: NSRange?
    private var maximumScroll: CGFloat { max(0, contentSize.height - bounds.height) }

    func replace(_ text: String, typography: ReaderTypography, at offset: Int) {
        anchorOffset = offset
        pendingTarget = .offset(offset)

        let fontSize = CGFloat(typography.fontSize)
        let systemFont = UIFont.systemFont(ofSize: fontSize)
        let font: UIFont
        switch typography.font {
        case .serif:
            let serif = systemFont.fontDescriptor.withDesign(.serif)
                .map { UIFont(descriptor: $0, size: fontSize) }
            font = UIFont(name: "SongtiSC-Regular", size: fontSize) ?? serif ?? systemFont
        case .sansSerif:
            font = systemFont
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = typography.lineSpacing
        paragraph.paragraphSpacing = typography.paragraphSpacing
        tintColor = UIColor(typography.palette.accent)
        indicatorStyle = typography.palette == .night ? .white : .black
        let formatted = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(typography.palette.foreground),
            .paragraphStyle: paragraph
        ])
        if typography.indentParagraphs {
            let indented = NSMutableParagraphStyle()
            indented.setParagraphStyle(paragraph)
            indented.firstLineHeadIndent = fontSize * 2
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byParagraphs, .substringNotRequired]) {
                _, range, enclosingRange, _ in
                guard let first = text[range].first, !first.isWhitespace else { return }
                formatted.addAttribute(.paragraphStyle, value: indented, range: NSRange(enclosingRange, in: text))
            }
        }
        highlight = nil
        attributedText = formatted
        setNeedsLayout()
    }

    func updateHighlight(_ range: NSRange?, palette: ReadingPalette) {
        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        if let highlight, NSMaxRange(highlight) <= textStorage.length {
            textStorage.removeAttribute(.backgroundColor, range: highlight)
        }
        highlight = range.flatMap {
            guard $0.location != NSNotFound else { return nil }
            let clamped = NSIntersectionRange($0, NSRange(location: 0, length: textStorage.length))
            return clamped.length > 0 ? clamped : nil
        }
        if let highlight {
            textStorage.addAttribute(
                .backgroundColor,
                value: UIColor(palette.accent).withAlphaComponent(0.23),
                range: highlight
            )
        }
    }

    func seek(to target: ReaderScrollRequest.Target) {
        pendingTarget = target
        if case .offset(let offset) = target { anchorOffset = offset }
        setNeedsLayout()
    }

    var readingOffsetAfterScroll: Int? {
        guard let offset = firstVisibleOffset else { return nil }
        // UITextView can report a partial contentSize while TextKit lays out
        // the chapter. Verify the real end before saving the 100% position.
        if contentOffset.y > 0, contentOffset.y >= maximumScroll - 1,
           contentOffset.y >= laidOutMaximumScroll() - 1 {
            return textStorage.length
        }
        return offset
    }

    private var firstVisibleOffset: Int? {
        guard pendingTarget == nil, lastLayoutSize == bounds.size, bounds.width > 0, textStorage.length > 0 else {
            return nil
        }
        let point = CGPoint(x: 0, y: max(0, contentOffset.y))
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        var line = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        return layoutManager.characterIndexForGlyph(at: line.location)
    }

    override func layoutSubviews() {
        let resized = lastLayoutSize != bounds.size
        if resized && lastLayoutSize != .zero && pendingTarget == nil {
            pendingTarget = .offset(anchorOffset)
        }
        super.layoutSubviews()

        lastLayoutSize = bounds.size
        guard let target = pendingTarget, bounds.width > 0, bounds.height > 0,
              textStorage.length > 0 else { return }
        let y: CGFloat
        switch target {
        case .offset(0):
            y = 0
        case .offset(let offset) where offset >= textStorage.length:
            y = laidOutMaximumScroll()
        case .offset(let offset):
            let location = min(max(0, offset), textStorage.length - 1)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: location, length: 1))
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            y = min(line.minY, maximumScroll)
        case .reveal(let offset):
            let location = min(max(0, offset), textStorage.length - 1)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: location, length: 1))
            let glyph = layoutManager.glyphIndexForCharacter(at: location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let minVisibleY = contentOffset.y
            let maxVisibleY = minVisibleY + bounds.height - textContainerInset.top - textContainerInset.bottom
            if line.minY >= minVisibleY && line.maxY <= maxVisibleY {
                pendingTarget = nil
                return
            }
            y = min(line.minY, maximumScroll)
        }
        setContentOffset(CGPoint(x: 0, y: y), animated: false)
        pendingTarget = nil
        if case .reveal = target, let offset = firstVisibleOffset {
            anchorOffset = offset
            onReveal?(offset)
        }
    }

    private func laidOutMaximumScroll() -> CGFloat {
        layoutManager.ensureLayout(for: textContainer)
        let textBottom = max(
            layoutManager.usedRect(for: textContainer).maxY,
            layoutManager.extraLineFragmentRect.maxY
        )
        return max(0, ceil(textBottom + textContainerInset.top + textContainerInset.bottom) - bounds.height)
    }

    func setAutomaticSpeed(_ speed: Double?) {
        guard automaticSpeed != speed else { return }
        automaticSpeed = speed
        displayLink?.invalidate()
        displayLink = nil
        guard speed != nil else { return }

        let target = AutomaticScrollTarget(view: self)
        let link = CADisplayLink(target: target, selector: #selector(AutomaticScrollTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func advanceAutomaticScroll(by elapsed: TimeInterval) {
        guard let automaticSpeed, pendingTarget == nil, !isTracking, !isDragging, !isDecelerating else { return }
        let delta = min(max(elapsed, 0), 0.05)
        let next = max(0, contentOffset.y) + automaticSpeed * delta
        let estimatedEnd = maximumScroll
        let end = next >= estimatedEnd - 0.5 ? laidOutMaximumScroll() : estimatedEnd
        let y = next >= end - 0.5 ? end : next
        if y != contentOffset.y {
            setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        if y >= end {
            if end > 0 { anchorOffset = textStorage.length }
            setAutomaticSpeed(nil)
            onAutomaticEnd?()
        }
    }

    private final class AutomaticScrollTarget: NSObject {
        weak var view: ReadingTextView?

        init(view: ReadingTextView) { self.view = view }

        @objc func tick(_ link: CADisplayLink) {
            guard let view else {
                link.invalidate()
                return
            }
            view.advanceAutomaticScroll(by: link.targetTimestamp - link.timestamp)
        }
    }
}
#else
struct ReaderTextPane: View {
    let text: String
    let typography: ReaderTypography
    let initialOffset: Int
    let request: ReaderScrollRequest?
    let highlight: NSRange?
    let automaticSpeed: Double?
    let onScroll: (Int) -> Void
    let onAutomaticEnd: () -> Void

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: typography.fontSize, design: typography.font == .serif ? .serif : .default))
                .lineSpacing(typography.lineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
    }
}
#endif
