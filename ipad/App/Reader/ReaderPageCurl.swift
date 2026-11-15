#if os(iOS)
import UIKit

@MainActor
protocol ReaderPageMotion: AnyObject {
    func update(progress: CGFloat, lift: CGFloat)
    func settle(advances: Bool, duration: Double, completion: @escaping () -> Void)
    func stop()
}

/// Bezier construction following the Android reader's SimulationPageDelegate.
/// The corner stays fixed while the dragged part of the sheet crosses a crease.
struct ReaderCurlShape {
    let lifted: CGPath
    let back: CGPath
    let reflection: CGAffineTransform
    let shadowStart: CGPoint
    let shadowEnd: CGPoint
    let frontShadowEnd: CGPoint

    init?(size: CGSize, progress: CGFloat, cornerAtTop: Bool, lift: CGFloat) {
        guard size.width > 1, size.height > 1, progress > 0, progress < 1 else { return nil }
        let corner = CGPoint(x: size.width, y: cornerAtTop ? 0 : size.height)
        let travel = max(0.5, size.width * 2.25 * progress)
        let baseline = (sin(.pi * progress) * 0.105 + 0.025) * size.height
        let rise = max(0.25, min(size.height * 0.29, min(travel * 0.54, baseline + lift)))
        let touch = CGPoint(x: corner.x - travel, y: corner.y + rise * (cornerAtTop ? 1 : -1))
        let middle = CGPoint(x: (touch.x + corner.x) / 2, y: (touch.y + corner.y) / 2)
        let dx = corner.x - middle.x
        let dy = corner.y - middle.y
        let horizontal = CGPoint(x: middle.x - dy * dy / dx, y: corner.y)
        let vertical = CGPoint(x: corner.x, y: middle.y - dx * dx / dy)
        let horizontalStart = CGPoint(x: horizontal.x + (horizontal.x - corner.x) / 2, y: corner.y)
        let verticalStart = CGPoint(x: corner.x, y: vertical.y + (vertical.y - corner.y) / 2)
        guard let horizontalEnd = Self.intersection(touch, horizontal, horizontalStart, verticalStart),
              let verticalEnd = Self.intersection(touch, vertical, horizontalStart, verticalStart) else { return nil }
        let edgeVertex = Self.quadMidpoint(horizontalStart, horizontal, horizontalEnd)
        let sideVertex = Self.quadMidpoint(verticalStart, vertical, verticalEnd)

        let folded = CGMutablePath()
        folded.move(to: horizontalStart)
        folded.addQuadCurve(to: horizontalEnd, control: horizontal)
        folded.addLine(to: touch)
        folded.addLine(to: verticalEnd)
        folded.addQuadCurve(to: verticalStart, control: vertical)
        folded.addLine(to: corner)
        folded.closeSubpath()
        lifted = folded

        let verso = CGMutablePath()
        verso.addLines(between: [sideVertex, edgeVertex, horizontalEnd, touch, verticalEnd])
        verso.closeSubpath()
        back = verso

        let hingeDX = vertical.x - horizontal.x
        let hingeDY = vertical.y - horizontal.y
        let span = hypot(hingeDX, hingeDY)
        guard span > 0 else { return nil }
        let sign: CGFloat = cornerAtTop ? -1 : 1
        let nx = sign * -hingeDY / span
        let ny = sign * hingeDX / span
        let a = 1 - 2 * nx * nx
        let b = -2 * nx * ny
        let d = 1 - 2 * ny * ny
        reflection = CGAffineTransform(
            a: a, b: b, c: b, d: d,
            tx: horizontal.x - a * horizontal.x - b * horizontal.y,
            ty: horizontal.y - b * horizontal.x - d * horizontal.y
        )
        let crease = edgeVertex
        let shadowWidth = min(58, max(12, travel * 0.14))
        shadowStart = crease
        shadowEnd = CGPoint(x: crease.x + shadowWidth * nx, y: crease.y + shadowWidth * ny)
        frontShadowEnd = CGPoint(x: crease.x - shadowWidth * 0.44 * nx, y: crease.y - shadowWidth * 0.44 * ny)
    }

    private static func quadMidpoint(_ start: CGPoint, _ control: CGPoint, _ end: CGPoint) -> CGPoint {
        CGPoint(x: (start.x + 2 * control.x + end.x) / 4, y: (start.y + 2 * control.y + end.y) / 4)
    }

    private static func intersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
        let rx = b.x - a.x
        let ry = b.y - a.y
        let sx = d.x - c.x
        let sy = d.y - c.y
        let denominator = rx * sy - ry * sx
        guard abs(denominator) > 0.000_001 else { return nil }
        let t = ((c.x - a.x) * sy - (c.y - a.y) * sx) / denominator
        let point = CGPoint(x: a.x + t * rx, y: a.y + t * ry)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
}

@MainActor
final class ReaderPageCurl: UIView, ReaderPageMotion {
    private let source: UIImage
    private let target: UIImage
    private let direction: ReaderPageDirection
    private let cornerAtTop: Bool
    private let paperColor: UIColor
    private var progress: CGFloat = 0
    private var lift: CGFloat = 0
    private var movement: Movement?
    private var displayLink: CADisplayLink?

    private struct Movement {
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let startProgress: CGFloat
        let finalProgress: CGFloat
        let startLift: CGFloat
        let completion: () -> Void
    }

    init(frame: CGRect, source: UIImage, target: UIImage, direction: ReaderPageDirection,
         cornerAtTop: Bool, paperColor: UIColor) {
        self.source = source
        self.target = target
        self.direction = direction
        self.cornerAtTop = cornerAtTop
        self.paperColor = paperColor
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { nil }

    func update(progress: CGFloat, lift: CGFloat) {
        self.progress = min(1, max(0, progress))
        self.lift = lift
        setNeedsDisplay()
    }

    func settle(advances: Bool, duration: Double, completion: @escaping () -> Void) {
        stop()
        let target: CGFloat = advances ? 1 : 0
        movement = Movement(
            start: CACurrentMediaTime(), duration: max(0.1, duration * abs(target - progress)),
            startProgress: progress, finalProgress: target, startLift: lift, completion: completion
        )
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        movement = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let movement else { return }
        let elapsed = min(1, max(0, (link.targetTimestamp - movement.start) / movement.duration))
        let eased = CGFloat(elapsed * elapsed * (3 - 2 * elapsed))
        update(
            progress: movement.startProgress + (movement.finalProgress - movement.startProgress) * eased,
            lift: movement.startLift * (1 - eased)
        )
        if elapsed == 1 {
            stop()
            movement.completion()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let turned = direction == .next ? progress : 1 - progress
        let front = direction == .next ? source : target
        let beneath = direction == .next ? target : source
        guard let geometry = ReaderCurlShape(
            size: bounds.size, progress: turned, cornerAtTop: cornerAtTop, lift: lift
        ) else {
            (turned < 0.5 ? front : beneath).draw(in: bounds)
            return
        }

        beneath.draw(in: bounds)
        context.saveGState()
        context.addPath(geometry.lifted)
        context.clip()
        Self.shade(context, gradient: Self.creaseShadow, from: geometry.shadowStart, to: geometry.shadowEnd)
        context.restoreGState()

        context.saveGState()
        context.addRect(bounds)
        context.addPath(geometry.lifted)
        context.clip(using: .evenOdd)
        front.draw(in: bounds)
        Self.shade(context, gradient: Self.frontShadow, from: geometry.shadowStart, to: geometry.frontShadowEnd)
        context.restoreGState()

        context.saveGState()
        context.addPath(geometry.lifted)
        context.clip()
        context.addPath(geometry.back)
        context.clip()
        paperColor.setFill()
        context.fill(bounds)
        context.saveGState()
        context.concatenate(geometry.reflection)
        front.draw(in: bounds, blendMode: .normal, alpha: 0.28)
        context.restoreGState()
        Self.shade(context, gradient: Self.creaseShadow, from: geometry.shadowStart, to: geometry.shadowEnd)
        context.restoreGState()
    }

    private static let creaseShadow = gradient(opacity: 0.37)
    private static let frontShadow = gradient(opacity: 0.19)

    private static func gradient(opacity: CGFloat) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor.black.withAlphaComponent(opacity).cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        )
    }

    private static func shade(_ context: CGContext, gradient: CGGradient?, from start: CGPoint, to end: CGPoint) {
        guard let gradient else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
    }
}
#endif
