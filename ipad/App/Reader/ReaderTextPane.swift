import SwiftUI

struct ReaderScrollRequest: Equatable {
    enum Target: Equatable {
        case offset(Int)
        case reveal(Int)
        case page(ReaderPageDirection)
    }

    let id = UUID()
    let target: Target
}

enum ReaderSelectionAction {
    case askAI, generateImage, searchBook, searchWeb, readAloud, bookmark
}

struct ReaderTextSelection {
    let text: String
    let range: NSRange
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
    var pageMode: ReaderPageMode = .scroll
    var pageAnimationDuration = 0.3
    var onChapterTurn: (ReaderPageDirection) -> Void = { _ in }
    var interaction = ReaderInteractionPreferences()
    var columnWidth: CGFloat? = nil
    var onToggleControls: () -> Void = {}
    var onUserPageTurn: () -> Void = {}
    var onSelectionAction: (ReaderSelectionAction, ReaderTextSelection) -> Void = { _, _ in }

    func makeUIView(context: Context) -> ReaderPagingViewport {
        let viewport = ReaderPagingViewport()
        let view = viewport.textView
        view.isEditable = false
        view.backgroundColor = .clear
        view.alwaysBounceVertical = false
        view.contentInsetAdjustmentBehavior = .never
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.onReveal = { [weak coordinator = context.coordinator] offset in
            coordinator?.report(offset)
        }
        view.onAutomaticEnd = { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.report(view.anchorOffset, automaticEnd: true) }
        }
        viewport.onPageOffset = { [weak coordinator = context.coordinator] offset in
            coordinator?.report(offset)
        }
        viewport.onChapterTurn = { [weak coordinator = context.coordinator] direction in
            DispatchQueue.main.async { coordinator?.onChapterTurn(direction) }
        }
        viewport.onToggleControls = { [weak coordinator = context.coordinator] in
            coordinator?.onToggleControls()
        }
        viewport.onUserPageTurn = { [weak coordinator = context.coordinator] in
            coordinator?.onUserPageTurn()
        }
        viewport.configure(
            mode: pageMode, animationDuration: pageAnimationDuration,
            interaction: interaction, columnWidth: columnWidth
        )
        viewport.replace(text, typography: typography, at: initialOffset)
        context.coordinator.text = text
        context.coordinator.typography = typography
        return viewport
    }

    func updateUIView(_ viewport: ReaderPagingViewport, context: Context) {
        let view = viewport.textView
        let coordinator = context.coordinator
        coordinator.onScroll = onScroll
        coordinator.onAutomaticEnd = onAutomaticEnd
        coordinator.onChapterTurn = onChapterTurn
        coordinator.onToggleControls = onToggleControls
        coordinator.onUserPageTurn = onUserPageTurn
        coordinator.onSelectionAction = onSelectionAction
        viewport.configure(
            mode: pageMode, animationDuration: pageAnimationDuration,
            interaction: interaction, columnWidth: columnWidth
        )
        let textChanged = coordinator.text != text
        let typographyChanged = coordinator.typography != typography
        if textChanged || typographyChanged {
            viewport.replace(text, typography: typography, at: textChanged ? initialOffset : view.anchorOffset)
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
            viewport.seek(to: request.target)
        }
        view.setAutomaticSpeed(pageMode == .scroll ? automaticSpeed : nil)
    }

    static func dismantleUIView(_ viewport: ReaderPagingViewport, coordinator: Coordinator) {
        viewport.cancelAnimation()
        viewport.textView.setAutomaticSpeed(nil)
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
        var onChapterTurn: (ReaderPageDirection) -> Void = { _ in }
        var onToggleControls: () -> Void = {}
        var onUserPageTurn: () -> Void = {}
        var onSelectionAction: (ReaderSelectionAction, ReaderTextSelection) -> Void = { _, _ in }
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

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            let body = textView.textStorage.string as NSString
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= body.length else {
                return nil
            }
            let passage = body.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !passage.isEmpty else { return nil }
            let selection = ReaderTextSelection(text: passage, range: range)

            func action(_ title: String, _ image: String, _ item: ReaderSelectionAction) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: image)) { [weak self, weak textView] _ in
                    textView?.selectedRange = NSRange(location: range.location, length: 0)
                    self?.onSelectionAction(item, selection)
                }
            }

            let search = UIMenu(title: "搜索", image: UIImage(systemName: "magnifyingglass"), children: [
                action("搜索本书", "book", .searchBook),
                action("网页搜索", "globe", .searchWeb)
            ])
            let tools = UIMenu(title: "阅读工具", image: UIImage(systemName: "ellipsis.circle"), children: [
                action("朗读选中文字", "speaker.wave.2", .readAloud),
                action("在此处添加书签", "bookmark", .bookmark)
            ])
            return UIMenu(children: [
                action("问 AI", "sparkles", .askAI),
                action("生图", "photo", .generateImage),
                search, tools
            ] + suggestedActions)
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
    private var showsDiscretePages = false
    private var pageOriginY: CGFloat?
    private var maximumScroll: CGFloat { max(0, contentSize.height - bounds.height) }

    func replace(_ text: String, typography: ReaderTypography, at offset: Int) {
        anchorOffset = offset
        pendingTarget = showsDiscretePages ? nil : .offset(offset)
        pageOriginY = nil

        let fontSize = CGFloat(typography.fontSize)
        let weight = fontWeight(for: typography.fontWeight)
        let systemFont = UIFont.systemFont(ofSize: fontSize, weight: weight)
        let font: UIFont
        switch typography.font {
        case .serif:
            let serif = systemFont.fontDescriptor.withDesign(.serif)
                .map { UIFont(descriptor: $0, size: fontSize) }
            let name = typography.fontWeight >= 750 ? "Black" :
                typography.fontWeight >= 550 ? "Bold" : typography.fontWeight < 350 ? "Light" : "Regular"
            font = UIFont(name: "SongtiSC-\(name)", size: fontSize) ?? serif ?? systemFont
        case .sourceHanSerif:
            font = ReaderBundledFont.sourceHanSerif(size: fontSize, weight: typography.fontWeight)
                .map { $0 as UIFont } ?? UIFont(name: "SongtiSC-Regular", size: fontSize) ?? systemFont
        case .sansSerif:
            font = systemFont
        case .kai:
            let name = typography.fontWeight >= 550 ? "KaitiSC-Bold" : "KaitiSC-Regular"
            font = UIFont(name: name, size: fontSize) ?? systemFont
        case .monospaced:
            font = .monospacedSystemFont(ofSize: fontSize, weight: weight)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = typography.lineSpacing
        paragraph.paragraphSpacing = typography.paragraphSpacing
        paragraph.alignment = typography.justifiesText ? .justified : .natural
        textContainerInset = UIEdgeInsets(
            top: typography.topMargin, left: typography.leadingMargin,
            bottom: typography.bottomMargin, right: typography.trailingMargin
        )
        tintColor = UIColor(typography.palette.accent)
        indicatorStyle = typography.palette == .night ? .white : .black
        let formatted = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .kern: typography.letterSpacing,
            .foregroundColor: UIColor(typography.palette.foreground),
            .paragraphStyle: paragraph
        ])
        if typography.indentWidth > 0 {
            let indented = NSMutableParagraphStyle()
            indented.setParagraphStyle(paragraph)
            indented.firstLineHeadIndent = fontSize * typography.indentWidth
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

    private func fontWeight(for value: Double) -> UIFont.Weight {
        let weights: [UIFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        let position = (min(900, max(100, value)) - 100) / 100
        let index = Int(position)
        guard index < weights.count - 1 else { return .black }
        let lower = weights[index].rawValue
        let upper = weights[index + 1].rawValue
        return UIFont.Weight(rawValue: lower + (upper - lower) * (position - Double(index)))
    }

    func setDiscretePages(_ enabled: Bool) {
        showsDiscretePages = enabled
        if enabled { pendingTarget = nil }
        else { pageOriginY = nil }
    }

    func showPage(at y: CGFloat) {
        pageOriginY = y
        setContentOffset(CGPoint(x: 0, y: y), animated: false)
        alignPageOrigin()
    }

    private func alignPageOrigin() {
        // TextKit can already know the page's exact line position while
        // UITextView is still scrolling against an earlier layout estimate.
        if let pageOriginY, abs(bounds.origin.y - pageOriginY) > 0.5 {
            bounds.origin.y = pageOriginY
        }
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
        guard !showsDiscretePages, let offset = firstVisibleOffset else { return nil }
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
        if !showsDiscretePages && resized && lastLayoutSize != .zero && pendingTarget == nil {
            pendingTarget = .offset(anchorOffset)
        }
        super.layoutSubviews()

        lastLayoutSize = bounds.size
        if showsDiscretePages {
            alignPageOrigin()
            return
        }
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
        case .page:
            pendingTarget = nil
            return
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

    func turnViewport(_ direction: ReaderPageDirection, animated: Bool) -> Bool {
        let y = max(0, contentOffset.y)
        let distance = max(1, bounds.height - textContainerInset.top - textContainerInset.bottom) * 0.88
        var target = max(0, y + (direction == .next ? distance : -distance))
        if direction == .next, target >= maximumScroll - 1 {
            target = min(target, laidOutMaximumScroll())
        }
        guard abs(target - y) > 0.5 else { return false }
        setContentOffset(CGPoint(x: 0, y: target), animated: animated && !UIAccessibility.isReduceMotionEnabled)
        return true
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
        guard let automaticSpeed, pendingTarget == nil, selectedRange.length == 0,
              !isTracking, !isDragging, !isDecelerating else { return }
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
    var pageMode: ReaderPageMode = .scroll
    var pageAnimationDuration = 0.3
    var onChapterTurn: (ReaderPageDirection) -> Void = { _ in }
    var interaction = ReaderInteractionPreferences()
    var columnWidth: CGFloat? = nil
    var onToggleControls: () -> Void = {}
    var onUserPageTurn: () -> Void = {}
    var onSelectionAction: (ReaderSelectionAction, ReaderTextSelection) -> Void = { _, _ in }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: typography.fontSize, design: typography.font == .serif ? .serif : .default))
                .lineSpacing(typography.lineSpacing)
                .textSelection(.enabled)
                .padding(24)
                .frame(maxWidth: columnWidth ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}
#endif
