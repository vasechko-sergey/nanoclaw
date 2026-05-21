import SwiftUI
import UIKit

struct FullScreenImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.background.ignoresSafeArea()
            ZoomableScrollView(image: image)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Theme.scaled(32)))
                    .foregroundStyle(Theme.accent)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .frame(width: Theme.minTapSize, height: Theme.minTapSize)
                    .padding(Theme.hPadding)
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> FitScrollView {
        let sv = FitScrollView(image: image)
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 6
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator = false
        sv.backgroundColor = .black
        sv.delegate = context.coordinator
        sv.contentInsetAdjustmentBehavior = .never

        let iv = UIImageView(image: image)
        iv.contentMode = .scaleToFill
        sv.addSubview(iv)
        sv.imageView = iv
        context.coordinator.scrollView = sv

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        sv.addGestureRecognizer(doubleTap)

        return sv
    }

    func updateUIView(_ sv: FitScrollView, context: Context) {
        sv.setNeedsLayout()
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: FitScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? FitScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let iv = (scrollView as? FitScrollView)?.imageView else { return }
            let bounds = scrollView.bounds.size
            let x = max((bounds.width  - iv.frame.width)  / 2, 0)
            let y = max((bounds.height - iv.frame.height) / 2, 0)
            iv.frame.origin = CGPoint(x: x, y: y)
        }

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard let sv = scrollView else { return }
            if sv.zoomScale > 1 {
                sv.setZoomScale(1, animated: true)
            } else {
                let pt = gr.location(in: sv.imageView)
                let rect = CGRect(x: pt.x - 50, y: pt.y - 50, width: 100, height: 100)
                sv.zoom(to: rect, animated: true)
            }
        }
    }
}

// Custom UIScrollView that fits the image to its bounds in layoutSubviews
final class FitScrollView: UIScrollView {
    var imageView: UIImageView?
    private let sourceImage: UIImage

    init(image: UIImage) {
        self.sourceImage = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let iv = imageView else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let imgSize = sourceImage.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }

        let scale = min(size.width / imgSize.width, size.height / imgSize.height)
        let fw = imgSize.width  * scale
        let fh = imgSize.height * scale
        let x  = (size.width  - fw) / 2
        let y  = (size.height - fh) / 2

        // Only reset frame if not currently zoomed (avoid fighting with scroll view)
        if zoomScale == 1 {
            iv.frame = CGRect(x: x, y: y, width: fw, height: fh)
            contentSize = size
        }
    }
}
