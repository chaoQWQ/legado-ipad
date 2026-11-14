import SwiftUI

#if os(iOS)
import UIKit

struct ReaderTextPane: UIViewRepresentable {
    let text: String
    let typography: ReaderTypography
    let initialOffset: Int
    let onOffset: (Int) -> Void

    func makeUIView(context: Context) -> ReadingTextView {
        let view = ReadingTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = false
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = UIEdgeInsets(top: 24, left: 24, bottom: 28, right: 24)
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.replace(text, typography: typography, at: initialOffset)
        context.coordinator.typography = typography
        return view
    }

    func updateUIView(_ view: ReadingTextView, context: Context) {
        context.coordinator.onOffset = onOffset
        if context.coordinator.typography != typography {
            view.replace(text, typography: typography, at: view.anchorOffset)
            context.coordinator.typography = typography
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOffset: onOffset)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var typography: ReaderTypography?
        var onOffset: (Int) -> Void

        init(onOffset: @escaping (Int) -> Void) {
            self.onOffset = onOffset
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? ReadingTextView,
                  let offset = view.firstVisibleOffset, offset != view.anchorOffset else { return }
            view.anchorOffset = offset
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, view.anchorOffset == offset else { return }
                onOffset(offset)
            }
        }
    }
}

final class ReadingTextView: UITextView {
    var anchorOffset = 0
    private var pendingOffset: Int?
    private var laidOutWidth: CGFloat = 0

    func replace(_ text: String, typography: ReaderTypography, at offset: Int) {
        anchorOffset = offset
        pendingOffset = offset

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
        paragraph.paragraphSpacing = max(4, typography.lineSpacing)
        tintColor = UIColor(typography.palette.accent)
        indicatorStyle = typography.palette == .night ? .white : .black
        attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(typography.palette.foreground),
            .paragraphStyle: paragraph
        ])
        setNeedsLayout()
    }

    var firstVisibleOffset: Int? {
        guard pendingOffset == nil, laidOutWidth == bounds.width, laidOutWidth > 0, textStorage.length > 0 else {
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
        if laidOutWidth > 0, laidOutWidth != bounds.width, pendingOffset == nil {
            pendingOffset = anchorOffset
        }
        super.layoutSubviews()

        laidOutWidth = bounds.width
        guard let offset = pendingOffset, bounds.width > 0, bounds.height > 0,
              textStorage.length > 0 else { return }
        if offset == 0 {
            setContentOffset(.zero, animated: false)
            pendingOffset = nil
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: min(offset, textStorage.length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let maxScroll = max(0, contentSize.height - bounds.height)
        setContentOffset(CGPoint(x: 0, y: min(line.minY, maxScroll)), animated: false)
        pendingOffset = nil
    }
}
#else
struct ReaderTextPane: View {
    let text: String
    let typography: ReaderTypography
    let initialOffset: Int
    let onOffset: (Int) -> Void

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
