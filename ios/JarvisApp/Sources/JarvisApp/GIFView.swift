import SwiftUI
import UIKit
import ImageIO

private func loadGIF(named name: String) -> UIImage? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "gif"),
          let data = try? Data(contentsOf: url) else { return nil }
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let count = CGImageSourceGetCount(source)
    var images: [UIImage] = []
    var duration = 0.0
    for i in 0..<count {
        guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
        images.append(UIImage(cgImage: cg))
        let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
        let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
        duration += (gif?[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
    }
    return UIImage.animatedImage(with: images, duration: duration)
}

struct GIFView: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> UIImageView {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.image = loadGIF(named: name)
        iv.backgroundColor = .clear
        return iv
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}
