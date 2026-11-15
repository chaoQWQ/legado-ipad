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
    private var animation: UIView?
    private var animationDuration = 0.3
    private var pageColor = UIColor.systemBackground
    private var interaction = ReaderInteractionPreferences()
    private lazy var swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))

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

    func configure(mode: ReaderPageMode, animationDuration: Double, interaction: ReaderInteractionPreferences) {
        self.animationDuration = animationDuration
        self.interaction = interaction
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

    func replace(_ text: String, typography: ReaderTypography, at offset: Int) {
        cancelAnimation()
        pageColor = UIColor(typography.palette.background)
        textView.replace(text, typography: typography, at: offset)
        pages = nil
        currentPage = nil
        setNeedsLayout()
    }

    func seek(to target: ReaderScrollRequest.Target) {
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
        textView.frame = bounds
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
        animation?.removeFromSuperview()
        animation = nil
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
            x: 0, y: textView.textContainerInset.top, width: bounds.width,
            height: min(pageTextHeight, page.bottom - page.top)
        )).cgPath
        CATransaction.commit()
        textView.accessibilityValue = (textView.textStorage.string as NSString).substring(with: page.characters)
    }

    @discardableResult
    private func turn(_ direction: ReaderPageDirection) -> Bool {
        if mode == .scroll {
            if !textView.turnViewport(direction, animated: interaction.animatesScrollTaps) {
                crossChapterBoundary(direction)
            }
            return true
        }
        guard let pages, let currentPage, animation == nil else { return false }
        let nextIndex = pageIndex + (direction == .next ? 1 : -1)
        guard let next = pages.page(at: nextIndex) else {
            crossChapterBoundary(direction)
            return true
        }

        show(next, index: nextIndex)
        textView.anchorOffset = next.characters.location
        onPageOffset(textView.anchorOffset)
        animate(from: currentPage, to: next, direction: direction)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .pageScrolled, argument: "第 \(pageIndex + 1) 页")
        }
        return true
    }

    private func crossChapterBoundary(_ direction: ReaderPageDirection) {
        if direction == .next {
            textView.anchorOffset = textView.textStorage.length
            onPageOffset(textView.anchorOffset)
        }
        onChapterTurn(direction)
    }

    @discardableResult
    private func turnFromUser(_ direction: ReaderPageDirection) -> Bool {
        guard animation == nil else { return false }
        textView.setAutomaticSpeed(nil)
        onUserPageTurn()
        return turn(direction)
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
            return mode != .scroll && abs(velocity.x) > abs(velocity.y)
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
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: self).x
        let defaultDistance = max(28, bounds.width * 0.07)
        let distance = interaction.swipeThreshold > 0
            ? min(bounds.width * 0.65, interaction.swipeThreshold)
            : defaultDistance
        guard abs(translation) >= distance else { return }
        turnFromUser(translation < 0 ? .next : .previous)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        switch tapAction(at: recognizer.location(in: self)) {
        case .previousPage: turnFromUser(.previous)
        case .nextPage: turnFromUser(.next)
        case .showControls: onToggleControls()
        case .none: break
        }
    }

    private func tapAction(at point: CGPoint) -> ReaderTapAction {
        if point.x < bounds.width / 3 { return interaction.tapPrevious }
        if point.x > bounds.width * 2 / 3 { return interaction.tapNext }
        return interaction.tapCenter
    }

    private func animate(
        from sourcePage: ReaderPageLayout.Page, to targetPage: ReaderPageLayout.Page,
        direction: ReaderPageDirection
    ) {
        guard window != nil, mode != .none, !UIAccessibility.isReduceMotionEnabled,
              animationDuration > 0 else { return }
        let overlay = UIView(frame: bounds)
        overlay.isUserInteractionEnabled = false
        overlay.clipsToBounds = true
        overlay.backgroundColor = pageColor
        let source = pageImage(sourcePage)
        let target = pageImage(targetPage)
        addSubview(overlay)
        animation = overlay

        func finish() {
            overlay.removeFromSuperview()
            if animation === overlay { animation = nil }
        }

        let duration = min(1.5, animationDuration)
        if mode == .curl {
            overlay.addSubview(source)
            UIView.transition(
                from: source, to: target, duration: min(1.5, duration * 1.6),
                options: direction == .next ? .transitionCurlUp : .transitionCurlDown
            ) { _ in finish() }
            return
        }

        let next = direction == .next
        let distance = next ? bounds.width : -bounds.width
        let slide = mode == .slide
        let linked = mode == .weread
        let moving = next || slide ? source : target
        let covered = next || slide ? target : source
        overlay.addSubview(covered)
        overlay.addSubview(moving)
        let targetStart = slide || !next ? distance : (linked ? distance * 0.2 : 0)
        target.transform = CGAffineTransform(translationX: targetStart, y: 0)
        let sourceEnd = slide || next ? -distance : (linked ? -distance * 0.2 : 0)

        let shade = UIView(frame: covered.bounds)
        if linked {
            shade.backgroundColor = .black
            shade.alpha = next ? 0.19 : 0
            covered.addSubview(shade)
        }
        if !slide {
            moving.layer.shadowColor = UIColor.black.cgColor
            moving.layer.shadowOpacity = 0.18
            moving.layer.shadowRadius = 12
            moving.layer.shadowOffset = CGSize(width: next ? 9 : -9, height: 0)
            moving.layer.shadowPath = UIBezierPath(rect: moving.bounds).cgPath
        }
        UIView.animate(withDuration: linked ? duration * 1.25 : duration, delay: 0, options: .curveEaseInOut) {
            source.transform = CGAffineTransform(translationX: sourceEnd, y: 0)
            target.transform = .identity
            shade.alpha = next ? 0 : 0.15
        } completion: { _ in finish() }
    }

    private func pageImage(_ page: ReaderPageLayout.Page) -> UIImageView {
        let render = UIGraphicsImageRenderer(size: bounds.size)
        let insets = textView.textContainerInset
        let origin = CGPoint(x: insets.left, y: insets.top - page.top)
        let image = render.image { context in
            pageColor.setFill()
            context.fill(bounds)
            let clipped = CGRect(
                x: 0, y: insets.top, width: bounds.width,
                height: min(pageTextHeight, page.bottom - page.top)
            )
            context.cgContext.clip(to: clipped)
            textView.layoutManager.drawBackground(forGlyphRange: page.glyphs, at: origin)
            textView.layoutManager.drawGlyphs(forGlyphRange: page.glyphs, at: origin)
        }
        let view = UIImageView(image: image)
        view.frame = bounds
        return view
    }
}
#endif
