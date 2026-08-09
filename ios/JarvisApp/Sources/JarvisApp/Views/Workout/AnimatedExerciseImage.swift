import SwiftUI
import UIKit
import ImageIO

/// Pure format/animation helpers for exercise images — unit-tested without a view.
enum ExerciseImageFormat {
    /// GIF magic ("GIF8") detected by bytes, NOT extension — the cache always
    /// names files `.jpg` regardless of the real format served by the runner.
    static func isAnimatedGIF(at url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = h.readData(ofLength: 4)
        return head.elementsEqual([0x47, 0x49, 0x46, 0x38])  // G I F 8
    }

    /// Build an animated UIImage (frames + per-frame delays) from a GIF file.
    /// Returns nil if it isn't a decodable multi-frame GIF.
    static func animatedUIImage(at url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return nil }
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            total += gifDelay(src, i)
            frames.append(UIImage(cgImage: cg))
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: total > 0 ? total : Double(frames.count) / 20)
    }

    /// Size an exercise image into the frame the parent proposes rather than its
    /// own (possibly portrait) intrinsic size. A concrete, finite proposed
    /// dimension wins; an unspecified/infinite one falls back to intrinsic. Pure
    /// so the sizing contract is unit-testable without a live representable.
    static func fittedSize(proposalWidth: CGFloat?, proposalHeight: CGFloat?, intrinsic: CGSize) -> CGSize {
        func dim(_ v: CGFloat?, _ fallback: CGFloat) -> CGFloat {
            guard let v, v.isFinite else { return fallback }
            return v
        }
        return CGSize(width: dim(proposalWidth, intrinsic.width),
                      height: dim(proposalHeight, intrinsic.height))
    }

    private static func gifDelay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}

/// Renders an exercise image file, animating it when the bytes are a GIF.
/// SwiftUI.Image can't play an animated UIImage, so wrap UIImageView.
struct AnimatedExerciseImage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if ExerciseImageFormat.isAnimatedGIF(at: url), let animated = ExerciseImageFormat.animatedUIImage(at: url) {
            v.image = animated
        } else {
            v.image = UIImage(contentsOfFile: url.path)
        }
    }

    /// Honor the frame the parent proposes instead of the image's intrinsic size.
    /// A UIImageView keeps default (required) compression resistance, so a tall
    /// PORTRAIT image otherwise refuses to shrink into the 16:9 hero the card /
    /// runner impose — it overflows, and in the runner (a non-scrolling VStack)
    /// it shoves the set-logging card + toolbar off-screen entirely. Returning
    /// the proposed size lets `scaleAspectFill` + `clipsToBounds` crop the image
    /// into whatever box the layout gives it. Falls back to the image's own size
    /// only for an unspecified/infinite dimension.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        ExerciseImageFormat.fittedSize(
            proposalWidth: proposal.width, proposalHeight: proposal.height,
            intrinsic: uiView.image?.size ?? uiView.intrinsicContentSize)
    }
}
