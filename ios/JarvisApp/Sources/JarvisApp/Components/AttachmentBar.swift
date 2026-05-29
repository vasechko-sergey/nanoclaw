import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: – Reusable picker plumbing

/// Hosts the photo / camera / document pickers and appends results to `drafts`.
/// Driven by three external Bool triggers so callers can present each picker
/// from any affordance (menu item, satellite orb, …). Attach via `.attachmentPickers(...)`.
struct AttachmentPickers: ViewModifier {
    @Binding var drafts: [DraftAttachment]
    @Binding var showPhotos: Bool
    @Binding var showCamera: Bool
    @Binding var showDoc: Bool

    @State private var photoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 5,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { loadPhotos() }
            .sheet(isPresented: $showCamera) {
                CameraPicker { capture in
                    switch capture {
                    case .image(let img):
                        if let d = DraftAttachment.image(img, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg") {
                            drafts.append(d)
                            Theme.hapticSend()
                        }
                    case .video(let url):
                        Task {
                            do {
                                let draft = try await DraftAttachment.video(from: url)
                                await MainActor.run {
                                    drafts.append(draft)
                                    Theme.hapticSend()
                                }
                            } catch {
                                await MainActor.run { surfaceVideoError(error) }
                            }
                        }
                    }
                }
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showDoc, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                handleDocs(result)
            }
    }

    private func loadPhotos() {
        let items = photoItems
        photoItems = []
        for item in items {
            Task {
                // Try image first; if not an image, attempt video as a Movie transferable.
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    let name = "photo-\(Int(Date().timeIntervalSince1970)).jpg"
                    await MainActor.run {
                        if let d = DraftAttachment.image(img, name: name) { drafts.append(d) }
                    }
                    return
                }
                // Video path: write the picker transferable to a temp file, then load.
                if let movieURL = (try? await item.loadTransferable(type: VideoTransferable.self))?.url {
                    do {
                        let draft = try await DraftAttachment.video(from: movieURL)
                        await MainActor.run { drafts.append(draft) }
                    } catch {
                        await MainActor.run { surfaceVideoError(error) }
                    }
                }
            }
        }
        if !items.isEmpty { Theme.hapticSend() }
    }

    private func surfaceVideoError(_ error: Error) {
        // Toast-style error surface isn't built; for v1 just log. Future:
        // pipe to AppCoordinator.onMessageReceived-equivalent for inline UI.
        Log.warn(.app, "[AttachmentBar] video load failed: \(error)")
    }

    private func handleDocs(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            drafts.append(.file(data: data, name: url.lastPathComponent, mimeType: mime))
        }
        if !urls.isEmpty { Theme.hapticSend() }
    }
}

extension View {
    func attachmentPickers(drafts: Binding<[DraftAttachment]>,
                           showPhotos: Binding<Bool>,
                           showCamera: Binding<Bool>,
                           showDoc: Binding<Bool>) -> some View {
        modifier(AttachmentPickers(drafts: drafts, showPhotos: showPhotos, showCamera: showCamera, showDoc: showDoc))
    }
}

var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

// MARK: – Plus menu (classic input bar)

/// The "+" affordance with a Camera / Photo / Document menu. Used in classic InputBar.
struct AttachmentMenuButton: View {
    @Binding var drafts: [DraftAttachment]
    var isDisabled: Bool = false

    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showDoc = false

    var body: some View {
        Menu {
            if cameraAvailable {
                Button { showCamera = true } label: { Label("Камера", systemImage: "camera") }
            }
            Button { showPhotos = true } label: { Label("Фото", systemImage: "photo") }
            Button { showDoc = true } label: { Label("Документ", systemImage: "doc") }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: Theme.scaled(28)))
                .foregroundStyle(Theme.accentMedium)
                .frame(width: Theme.minTapSize, height: Theme.minTapSize)
        }
        .disabled(isDisabled)
        .accessibilityLabel("Прикрепить")
        .attachmentPickers(drafts: $drafts, showPhotos: $showPhotos, showCamera: $showCamera, showDoc: $showDoc)
    }
}

// MARK: – Preview chips

/// Horizontal row of pending-attachment chips with a remove button each.
/// Rendered above the input when `drafts` is non-empty.
struct AttachmentChips: View {
    @Binding var drafts: [DraftAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.scaled(8)) {
                ForEach(drafts) { att in
                    chip(att)
                }
            }
            .padding(.horizontal, Theme.scaled(12))
            .padding(.vertical, Theme.scaled(6))
        }
    }

    @ViewBuilder
    private func chip(_ att: DraftAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if att.kind == .video, let thumb = att.thumbnail {
                    ZStack(alignment: .bottomLeading) {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: Theme.scaled(56), height: Theme.scaled(56))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))

                        Image(systemName: "play.fill")
                            .font(.system(size: Theme.scaled(14)))
                            .foregroundStyle(.white)
                            .padding(Theme.scaled(4))
                            .background(Color.black.opacity(0.45), in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                        if let dur = att.duration {
                            Text(formatDuration(dur))
                                .font(.system(size: 9, design: .monospaced))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.black.opacity(0.6),
                                            in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.white)
                                .padding(Theme.scaled(4))
                        }
                    }
                    .frame(width: Theme.scaled(56), height: Theme.scaled(56))
                } else if let img = att.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Theme.scaled(56), height: Theme.scaled(56))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: Theme.scaled(18)))
                            .foregroundStyle(Theme.accent)
                        Text(att.name)
                            .font(.system(size: Theme.scaled(9)))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: Theme.scaled(50))
                    }
                    .frame(width: Theme.scaled(56), height: Theme.scaled(56))
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.chipRadius)
                            .stroke(Theme.surfaceBorder, lineWidth: 0.5)
                    )
                }
            }

            Button {
                drafts.removeAll { $0.id == att.id }
                Theme.hapticSend()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Theme.scaled(18)))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .offset(x: Theme.scaled(6), y: -Theme.scaled(6))
            .accessibilityLabel("Удалить вложение")
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Minimal `Transferable` wrapper used to receive a movie file from
/// PhotosPickerItem and expose its temporary URL so the async loader can read it.
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let copy = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoTransferable(url: copy)
        }
    }
}
