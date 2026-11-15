#if os(iOS)
import UIKit

@MainActor
final class ReaderPageTranslation: UIView, ReaderPageMotion {
    private let source: UIImageView
    private let target: UIImageView
    private let shade = UIView()
    private let mode: ReaderPageMode
    private let direction: ReaderPageDirection
    private var progress: CGFloat = 0

    init(frame: CGRect, source: UIImage, target: UIImage, mode: ReaderPageMode,
         direction: ReaderPageDirection, paperColor: UIColor) {
        self.source = UIImageView(image: source)
        self.target = UIImageView(image: target)
        self.mode = mode
        self.direction = direction
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = paperColor
        self.source.frame = bounds
        self.target.frame = bounds

        let next = direction == .next
        let moving = next || mode == .slide ? self.source : self.target
        let covered = next || mode == .slide ? self.target : self.source
        addSubview(covered)
        addSubview(moving)
        if mode == .weread {
            shade.frame = covered.bounds
            shade.backgroundColor = .black
            covered.addSubview(shade)
        }
        if mode != .slide {
            moving.layer.shadowColor = UIColor.black.cgColor
            moving.layer.shadowOpacity = 0.18
            moving.layer.shadowRadius = 12
            moving.layer.shadowOffset = CGSize(width: next ? 9 : -9, height: 0)
            moving.layer.shadowPath = UIBezierPath(rect: moving.bounds).cgPath
        }

        update(progress: 0, lift: 0)
    }

    required init?(coder: NSCoder) { nil }

    func update(progress: CGFloat, lift: CGFloat) {
        let progress = min(1, max(0, progress))
        self.progress = progress
        let next = direction == .next
        let travel = next ? bounds.width : -bounds.width
        let slide = mode == .slide
        let linked = mode == .weread
        let sourceOffset = slide || next ? -travel : (linked ? -travel * 0.2 : 0)
        let targetOffset = slide || !next ? travel : (linked ? travel * 0.2 : 0)
        source.transform = CGAffineTransform(translationX: sourceOffset * progress, y: 0)
        target.transform = CGAffineTransform(translationX: targetOffset * (1 - progress), y: 0)
        if linked { shade.alpha = next ? 0.19 * (1 - progress) : 0.15 * progress }
    }

    func settle(advances: Bool, duration: Double, completion: @escaping () -> Void) {
        let final: CGFloat = advances ? 1 : 0
        UIView.animate(
            withDuration: max(0.1, duration * abs(final - progress)), delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.update(progress: final, lift: 0)
        } completion: { _ in completion() }
    }

    func stop() {
        source.layer.removeAllAnimations()
        target.layer.removeAllAnimations()
        shade.layer.removeAllAnimations()
    }
}
#endif
