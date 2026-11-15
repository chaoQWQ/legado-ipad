#if os(iOS)
import UIKit

@MainActor
final class ReaderPagingViewport: UIView, UIGestureRecognizerDelegate {
    let textView = ReadingTextView(usingTextLayoutManager: false)
    var onPageOffset: (Int) -> Void = { _ in }
    var onChapterTurn: (ReaderPageDirection) -> Void = { _ in }
    var onToggleControls: () -> Void = {}
    var onUserPageTurn: () -> Void = {}
    private(set) var mode: ReaderPageMode = .scroll

    private let pageMask = CAShapeLayer()
    private var pages: ReaderPageLayout?
    private var pageIndex = 0
    private var pageSize = CGSize.zero
    private var currentPage: ReaderPageLayout.Page?
    private var request: ReaderScrollRequest.Target?
    private var turnAnimation: TurnAnimation?
    private var drag: PageDrag?
    private var animationDuration = 0.3
    private var pageColor = UIColor.systemBackground
    private var interaction = ReaderInteractionPreferences()
    private var columnWidth: CGFloat?
    private lazy var swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))

    private struct TurnAnimation {
        let overlay: UIView & ReaderPageMotion
        let target: ReaderPageLayout.Page
        let index: Int
    }

    private struct PageDrag {
        let direction: ReaderPageDirection
        let cornerAtTop: Bool

        func forwardDistance(_ translation: CGFloat) -> CGFloat {
            direction == .next ? -translation : translation
        }
    }

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(textView)
        swipe.delegate = self
        swipe.isEnabled = false
        swipe.maximumNumberOfTouches = 1
        swipe.allowedScrollTypesMask = [.continuous, .discrete]
        addGestureRecognizer(swipe)
        tap.delegate = self
        tap.cancelsTouchesInView = false
        tap.require(toFail: swipe)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { nil }

    func configure(mode: ReaderPageMode, animationDuration: Double, interaction: ReaderInteractionPreferences,
                   columnWidth: CGFloat? = nil) {
        self.animationDuration = animationDuration
        self.interaction = interaction
        if self.columnWidth != columnWidth {
            self.columnWidth = columnWidth
            cancelAnimation()
            pages = nil
            setNeedsLayout()
        }
        if textView.isSelectable != interaction.allowsTextSelection {
            textView.isSelectable = interaction.allowsTextSelection
        }
        guard self.mode != mode else { return }
        let wasScrolling = self.mode == .scroll
        self.mode = mode
        cancelAnimation()
        let scrolls = mode == .scroll
        if wasScrolling != scrolls {
            textView.setDiscretePages(!scrolls)
            if scrolls { textView.seek(to: .offset(textView.anchorOffset)) }
        }
        swipe.isEnabled = !scrolls
        textView.panGestureRecognizer.isEnabled = scrolls
        textView.showsVerticalScrollIndicator = scrolls
        guard wasScrolling != scrolls else { return }

        if scrolls {
            textView.layer.mask = nil
            textView.contentInset.bottom = 0
            textView.accessibilityValue = nil
            textView.accessibilityCustomActions = nil
            pages = nil
            currentPage = nil
        } else {
            pageMask.fillColor = UIColor.black.cgColor
            textView.layer.mask = pageMask
            installAccessibilityActions()
        }
        setNeedsLayout()
    }

    func replace(_ text: String, typography: ReaderTypography, at offset: Int, images: [ReaderDisplayImage] = []) {
        cancelAnimation()
        pageColor = UIColor(typography.palette.background)
        textView.replace(text, typography: typography, at: offset, images: images)
        pages = nil
        currentPage = nil
        setNeedsLayout()
    }

    func seek(to target: ReaderScrollRequest.Target) {
        if turnAnimation != nil || drag != nil {
            switch target {
            case .page, .reveal: return
            case .offset: break
            }
        }
        cancelAnimation()
        if mode == .scroll {
            if case .page(let direction) = target {
                request = .page(direction)
                setNeedsLayout()
            } else {
                request = nil
                textView.seek(to: target)
            }
        } else {
            if case .offset(let offset) = target { textView.anchorOffset = offset }
            request = target
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let resized = pageSize != bounds.size
        pageSize = bounds.size
        if resized { cancelAnimation() }
        let width = min(bounds.width, columnWidth ?? bounds.width)
        textView.frame = CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        textView.layoutIfNeeded()
        guard bounds.width > 0, bounds.height > 0, textView.textStorage.length > 0 else { return }

        if mode != .scroll, resized || pages == nil {
            pages = ReaderPageLayout(
                manager: textView.layoutManager,
                container: textView.textContainer,
                height: pageTextHeight
            )
            textView.contentInset.bottom = bounds.height
            showPage(containing: textView.anchorOffset, reportsPosition: false)
        }
        guard let request else { return }
        self.request = nil
        switch request {
        case .offset(let offset):
            showPage(containing: offset, reportsPosition: false)
        case .reveal(let offset):
            showPage(containing: offset, reportsPosition: true)
        case .page(let direction):
            turn(direction)
        }
    }

    func cancelAnimation() {
        drag = nil
        let overlay = turnAnimation?.overlay
        turnAnimation = nil
        overlay?.stop()
        overlay?.removeFromSuperview()
    }

    private var pageTextHeight: CGFloat {
        max(1, bounds.height - textView.textContainerInset.top - textView.textContainerInset.bottom)
    }

    private func showPage(containing offset: Int, reportsPosition: Bool) {
        guard let pages else { return }
        let index = pages.pageIndex(containing: offset)
        if reportsPosition, currentPage != nil, index == pageIndex { return }
        guard let page = pages.page(at: index) else { return }
        show(page, index: index)
        if reportsPosition {
            textView.anchorOffset = page.characters.location
            onPageOffset(textView.anchorOffset)
        }
    }

    private func show(_ page: ReaderPageLayout.Page, index: Int) {
        pageIndex = index
        currentPage = page
        // UITextView may still have an estimated content height after TextKit
        // has laid out the page. Publish the known height before scrolling.
        let insets = textView.textContainerInset
        let measuredHeight = ceil(page.bottom + insets.top + insets.bottom)
        if textView.contentSize.height < measuredHeight {
            textView.contentSize.height = measuredHeight
        }
        textView.showPage(at: page.top)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageMask.frame = textView.bounds
        pageMask.path = UIBezierPath(rect: CGRect(
            x: 0, y: textView.textContainerInset.top, width: textView.bounds.width,
            height: min(pageTextHeight, page.bottom - page.top)
        )).cgPath
        CATransaction.commit()
        textView.accessibilityValue = (textView.textStorage.string as NSString).substring(with: page.characters)
    }

    @discardableResult
    private func turn(_ direction: ReaderPageDirection, touch: CGPoint? = nil) -> Bool {
        if mode == .scroll {
            if !textView.turnViewport(direction, animated: interaction.animatesScrollTaps) {
                crossChapterBoundary(direction)
            }
            return true
        }
        guard let pages, currentPage != nil, turnAnimation == nil else { return false }
        let nextIndex = pageIndex + (direction == .next ? 1 : -1)
        guard let next = pages.page(at: nextIndex) else {
            crossChapterBoundary(direction)
            return true
        }

        if startAnimation(
            to: next, index: nextIndex, direction: direction,
            cornerAtTop: direction == .next && (touch?.y ?? bounds.midY) < bounds.midY
        ) {
            settleAnimation(advances: true)
        } else {
            commit(next, index: nextIndex)
        }
        return true
    }

    private func commit(_ page: ReaderPageLayout.Page, index: Int) {
        show(page, index: index)
        textView.anchorOffset = page.characters.location
        onPageOffset(textView.anchorOffset)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .pageScrolled, argument: "第 \(pageIndex + 1) 页")
        }
    }

    private func crossChapterBoundary(_ direction: ReaderPageDirection) {
        if direction == .next {
            textView.anchorOffset = textView.textStorage.length
            onPageOffset(textView.anchorOffset)
        }
        onChapterTurn(direction)
    }

    @discardableResult
    private func turnFromUser(_ direction: ReaderPageDirection, touch: CGPoint? = nil) -> Bool {
        guard turnAnimation == nil, drag == nil else { return false }
        textView.setAutomaticSpeed(nil)
        onUserPageTurn()
        return turn(direction, touch: touch)
    }

    private func installAccessibilityActions() {
        textView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "上一页") { [weak self] _ in self?.turnFromUser(.previous) ?? false },
            UIAccessibilityCustomAction(name: "下一页") { [weak self] _ in self?.turnFromUser(.next) ?? false },
            UIAccessibilityCustomAction(name: "切换阅读工具") { [weak self] _ in
                guard let self else { return false }
                onToggleControls()
                return true
            }
        ]
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipe || gestureRecognizer === tap else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard textView.selectedRange.length == 0 else { return false }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: self)
            return mode != .scroll && turnAnimation == nil && abs(velocity.x) > abs(velocity.y)
        }
        return tapAction(at: gestureRecognizer.location(in: self)) != .none
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        guard interaction.allowsTextSelection, gestureRecognizer === tap, let other = other as? UITapGestureRecognizer,
              let owner = other.view, owner.isDescendant(of: textView) else { return false }
        return other.numberOfTapsRequired > 1
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === tap, let other = other as? UITapGestureRecognizer,
              let owner = other.view, owner.isDescendant(of: textView) else { return false }
        return other.numberOfTapsRequired == 1
    }

    @objc private func swiped(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        let velocity = recognizer.velocity(in: self).x
        switch recognizer.state {
        case .began:
            guard turnAnimation == nil, drag == nil else { return }
            let direction: ReaderPageDirection = (translation.x == 0 ? velocity : translation.x) < 0 ? .next : .previous
            let originY = recognizer.location(in: self).y - translation.y
            let cornerAtTop = direction == .next && originY < bounds.midY
            drag = PageDrag(direction: direction, cornerAtTop: cornerAtTop)
            textView.setAutomaticSpeed(nil)
            onUserPageTurn()
            let index = pageIndex + (direction == .next ? 1 : -1)
            if let candidate = pages?.page(at: index) {
                _ = startAnimation(to: candidate, index: index, direction: direction, cornerAtTop: cornerAtTop)
            }
            updateDrag(translation)
        case .changed:
            updateDrag(translation)
        case .ended:
            guard let drag else { return }
            updateDrag(translation)
            self.drag = nil
            let threshold = interaction.swipeThreshold > 0
                ? min(bounds.width * 0.65, interaction.swipeThreshold)
                : 24
            let forwardVelocity = drag.direction == .next ? -velocity : velocity
            let advances = drag.forwardDistance(translation.x) >= threshold && forwardVelocity > -360
            if turnAnimation != nil {
                settleAnimation(advances: advances)
            } else if advances {
                turn(drag.direction, touch: recognizer.location(in: self))
            }
        case .cancelled, .failed:
            if drag != nil {
                drag = nil
                settleAnimation(advances: false)
            }
        default: break
        }
    }

    private func updateDrag(_ translation: CGPoint) {
        guard let drag, let turnAnimation else { return }
        turnAnimation.overlay.update(
            progress: drag.forwardDistance(translation.x) / max(1, bounds.width),
            lift: (drag.cornerAtTop ? translation.y : -translation.y) * 0.65
        )
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch tapAction(at: point) {
        case .previousPage: turnFromUser(.previous, touch: point)
        case .nextPage: turnFromUser(.next, touch: point)
        case .showControls: onToggleControls()
        case .none: break
        }
    }

    private func tapAction(at point: CGPoint) -> ReaderTapAction {
        interaction.tapAction(at: point, in: bounds.size, mode: mode)
    }

    private func startAnimation(
        to targetPage: ReaderPageLayout.Page, index: Int, direction: ReaderPageDirection,
        cornerAtTop: Bool
    ) -> Bool {
        guard window != nil, mode != .none, !UIAccessibility.isReduceMotionEnabled,
              animationDuration > 0, let currentPage else { return false }
        let source = pageImage(currentPage)
        let target = pageImage(targetPage)
        let overlay: UIView & ReaderPageMotion
        if mode == .curl {
            overlay = ReaderPageCurl(
                frame: bounds, source: source, target: target, direction: direction,
                cornerAtTop: cornerAtTop, paperColor: pageColor
            )
        } else {
            overlay = ReaderPageTranslation(
                frame: bounds, source: source, target: target, mode: mode,
                direction: direction, paperColor: pageColor
            )
        }
        addSubview(overlay)
        overlay.update(progress: 0, lift: 0)
        turnAnimation = TurnAnimation(overlay: overlay, target: targetPage, index: index)
        return true
    }

    private func settleAnimation(advances: Bool) {
        guard let turn = turnAnimation else { return }
        let multiplier = mode == .curl ? 1.55 : mode == .weread ? 1.25 : 1
        turn.overlay.settle(
            advances: advances,
            duration: min(1.5, animationDuration * multiplier)
        ) { [weak self, weak overlay = turn.overlay] in
            guard let self, let overlay, self.turnAnimation?.overlay === overlay,
                  let completed = self.turnAnimation else { return }
            self.turnAnimation = nil
            if advances { self.commit(completed.target, index: completed.index) }
            overlay.removeFromSuperview()
        }
    }

    private func pageImage(_ page: ReaderPageLayout.Page) -> UIImage {
        let render = UIGraphicsImageRenderer(size: bounds.size)
        let insets = textView.textContainerInset
        let origin = CGPoint(x: textView.frame.minX + insets.left, y: insets.top - page.top)
        return render.image { context in
            pageColor.setFill()
            context.fill(bounds)
            let clipped = CGRect(
                x: textView.frame.minX, y: insets.top, width: textView.bounds.width,
                height: min(pageTextHeight, page.bottom - page.top)
            )
            context.cgContext.clip(to: clipped)
            textView.layoutManager.drawBackground(forGlyphRange: page.glyphs, at: origin)
            textView.layoutManager.drawGlyphs(forGlyphRange: page.glyphs, at: origin)
        }
    }
}
#endif
