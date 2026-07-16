import SwiftUI
import UniformTypeIdentifiers

/// Loads the attachment handed to us by the OS share sheet, then delegates
/// the category-picker/submit UI to Shared/ReceiptSubmitView.
struct ShareSheetView: View {
    let onCancel: () -> Void
    let onComplete: () -> Void
    let extensionItems: [NSExtensionItem]

    @State private var attachment: SharedAttachment?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let attachment {
                ReceiptSubmitView(attachment: attachment, onCancel: onCancel, onComplete: onComplete)
            } else {
                NavigationStack {
                    Group {
                        if let loadError {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        } else {
                            ProgressView("Loading receipt…")
                        }
                    }
                    .navigationTitle("ReceiptDrop")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                        }
                    }
                }
            }
        }
        .onAppear(perform: loadAttachment)
    }

    // MARK: - Attachment loading

    private func loadAttachment() {
        let providers = extensionItems.flatMap { $0.attachments ?? [] }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                DispatchQueue.main.async {
                    if let data, let image = UIImage(data: data) {
                        attachment = SharedAttachment(kind: .image, data: data, thumbnail: image)
                    } else {
                        loadError = "Couldn't read the image."
                    }
                }
            }
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                DispatchQueue.main.async {
                    if let data {
                        attachment = SharedAttachment(kind: .pdf, data: data, thumbnail: pdfThumbnail(data))
                    } else {
                        loadError = "Couldn't read the PDF."
                    }
                }
            }
        } else {
            loadError = "No image or PDF found in the shared item."
        }
    }
}
