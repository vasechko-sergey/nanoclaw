import SwiftUI
import UIKit

/// Thin wrapper over UIImagePickerController in `.camera` mode. Accepts both
/// stills and short clips (≤60s, .typeMedium quality). Returns either via a
/// single callback that distinguishes by the case payload.
struct CameraPicker: UIViewControllerRepresentable {
    enum Capture {
        case image(UIImage)
        case video(URL)
    }

    let onCapture: (Capture) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoMaximumDuration = 60
        picker.videoQuality = .typeMedium
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let mediaType = info[.mediaType] as? String, mediaType == "public.movie",
               let url = info[.mediaURL] as? URL {
                parent.onCapture(.video(url))
            } else if let img = info[.originalImage] as? UIImage {
                parent.onCapture(.image(img))
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
