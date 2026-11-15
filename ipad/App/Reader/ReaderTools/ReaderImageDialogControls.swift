import SwiftUI
import UIKit

struct ReaderImagePromptEditor: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        view.text = text
        view.accessibilityLabel = "可编辑的图片提示词"
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        view.isEditable = isEditable
        if view.text != text {
            view.text = text
            let cursor = NSRange(location: text.utf16.count, length: 0)
            view.selectedRange = cursor
            view.scrollRangeToVisible(cursor)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

struct ReaderZoomableImage: UIViewRepresentable {
    let image: CGImage

    func makeUIView(context: Context) -> ZoomView {
        ZoomView(image: UIImage(cgImage: image))
    }

    func updateUIView(_ view: ZoomView, context: Context) {}

    final class ZoomView: UIScrollView, UIScrollViewDelegate {
        private let picture: UIImageView
        private var fittedBounds: CGSize = .zero

        init(image: UIImage) {
            picture = UIImageView(image: image)
            super.init(frame: .zero)
            picture.contentMode = .scaleAspectFit
            picture.isAccessibilityElement = true
            picture.accessibilityLabel = "生成的图片"
            addSubview(picture)

            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 4
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard fittedBounds != bounds.size, bounds.width > 0, bounds.height > 0,
                  let image = picture.image, image.size.width > 0, image.size.height > 0 else { return }
            fittedBounds = bounds.size
            setZoomScale(minimumZoomScale, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fit = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            picture.frame = CGRect(origin: .zero, size: fit)
            contentSize = fit
            centerPicture()
            setContentOffset(CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPicture() }

        private func centerPicture() {
            let x = max(0, (bounds.width - contentSize.width) / 2)
            let y = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
            if zoomScale > minimumZoomScale {
                setZoomScale(minimumZoomScale, animated: true)
                return
            }
            let point = gesture.location(in: picture)
            let width = bounds.width / 2.5
            let height = bounds.height / 2.5
            zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
        }
    }
}
