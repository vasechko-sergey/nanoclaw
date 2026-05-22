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
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 5, matching: .images)
            .onChange(of: photoItems) { loadPhotos() }
            .sheet(isPresented: $showCamera) {
                CameraPicker { img in
                    if let d = DraftAttachment.image(img, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg") {
                        drafts.append(d)
                        Theme.hapticSend()
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
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let img = UIImage(data: data) else { return }
                let name = "photo-\(Int(Date().timeIntervalSince1970)).jpg"
                await MainActor.run {
                    if let d = DraftAttachment.image(img, name: name) { drafts.append(d) }
                }
            }
        }
        if !items.isEmpty { Theme.hapticSend() }
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
                if let img = att.image {
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
}
