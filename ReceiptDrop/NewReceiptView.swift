import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Which capture method the user picked from the "New Receipt" menu.
enum NewReceiptSource: Identifiable {
    case camera
    case scanDocument
    case scanText
    case library
    case file
    case manual

    var id: Self { self }
}

/// Entry point for submitting a receipt directly from the main app. The
/// source (camera, library, or manual entry) is chosen up front by the
/// caller's menu; this view just drives that specific flow.
struct NewReceiptView: View {
    let source: NewReceiptSource
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showCamera = false
    @State private var showDocumentScanner = false
    @State private var showTextScanner = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showManualEntry = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var attachment: SharedAttachment?
    @State private var batchAttachments: [SharedAttachment]?
    @State private var scannedText: String?
    @State private var pendingBatchAttachments: [SharedAttachment] = []
    @State private var showBatchConfirm = false

    /// Hard cap passed to `PhotosPicker` itself — its own "N of 20 selected"
    /// UI stops the user from over-selecting in the first place. Was 0
    /// (PhotosPicker's documented value for "no limit"): a user could select
    /// e.g. 200 photos and every one would fire its own AI extraction call
    /// with no confirmation shown at any point.
    private static let photoPickerMaxSelection = 20
    /// Above this count, confirm before committing to the batch — matches
    /// the share extension's friendly limit (ExtensionBatchSubmitView) for
    /// consistency, though this path has no OS-level ceiling to work around
    /// and so just needs the one confirmation step, not two tiers.
    private static let batchConfirmThreshold = 5

    var body: some View {
        Group {
            if let batchAttachments {
                BatchReceiptSubmitView(
                    attachments: batchAttachments,
                    onCancel: { dismiss() },
                    onComplete: {
                        dismiss()
                        onComplete()
                    })
            } else if let attachment {
                ReceiptSubmitView(
                    attachment: attachment,
                    onCancel: { dismiss() },
                    onComplete: {
                        LocalReceiptStore.drainSpoolIntoDocuments()
                        dismiss()
                        onComplete()
                    })
            } else if let scannedText {
                ScannedTextSubmitView(
                    recognizedText: scannedText,
                    onCancel: { dismiss() },
                    onComplete: {
                        dismiss()
                        onComplete()
                    })
            } else {
                Color.clear
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                showCamera = false
                if let image, let jpeg = image.jpegData(compressionQuality: 0.85) {
                    attachment = SharedAttachment(kind: .image, data: jpeg, thumbnail: image)
                } else {
                    dismiss()
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showTextScanner) {
            LiveTextScanScreen(
                onInsert: { text in
                    showTextScanner = false
                    scannedText = text
                },
                onCancel: {
                    showTextScanner = false
                    dismiss()
                })
        }
        .fullScreenCover(isPresented: $showDocumentScanner) {
            DocumentScannerView { image in
                showDocumentScanner = false
                if let image, let jpeg = image.jpegData(compressionQuality: 0.85) {
                    attachment = SharedAttachment(kind: .image, data: jpeg, thumbnail: image)
                } else {
                    dismiss()
                }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItems,
                      maxSelectionCount: Self.photoPickerMaxSelection, matching: .images)
        .onChange(of: photoPickerItems) { items in
            guard !items.isEmpty else { return }
            Task {
                var loaded: [SharedAttachment] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        loaded.append(SharedAttachment(kind: .image, data: data, thumbnail: image))
                    }
                }
                guard !loaded.isEmpty else {
                    dismiss()
                    return
                }
                if loaded.count == 1 {
                    attachment = loaded[0]
                } else if loaded.count > Self.batchConfirmThreshold {
                    // Large-ish batch: confirm before committing, since each
                    // photo fires its own AI extraction call once
                    // BatchReceiptSubmitView's "Submit All" is tapped.
                    pendingBatchAttachments = loaded
                    showBatchConfirm = true
                } else {
                    batchAttachments = loaded
                }
            }
        }
        .alert("Submit \(pendingBatchAttachments.count) receipts?", isPresented: $showBatchConfirm) {
            Button("Cancel", role: .cancel) {
                pendingBatchAttachments = []
                dismiss()
            }
            Button("Continue") {
                batchAttachments = pendingBatchAttachments
                pendingBatchAttachments = []
            }
        } message: {
            Text("This will make \(pendingBatchAttachments.count) AI requests, one per photo.")
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image]) { result in
            switch result {
            case .success(let url):
                loadFile(at: url)
            case .failure:
                dismiss()
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualReceiptEntryView(
                onCancel: { dismiss() },
                onComplete: {
                    dismiss()
                    onComplete()
                })
        }
        .onAppear {
            switch source {
            case .camera: showCamera = true
            case .scanDocument: showDocumentScanner = true
            case .scanText: showTextScanner = true
            case .library: showPhotoPicker = true
            case .file: showFileImporter = true
            case .manual: showManualEntry = true
            }
        }
    }

    /// Loads a file picked from the Files app, keeping PDFs as documents and
    /// treating everything else as an image (re-encoded to JPEG downstream).
    private func loadFile(at url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            dismiss()
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            dismiss()
            return
        }

        if url.pathExtension.lowercased() == "pdf" {
            attachment = SharedAttachment(kind: .pdf, data: data, thumbnail: pdfThumbnail(data))
        } else if let image = UIImage(data: data) {
            attachment = SharedAttachment(kind: .image, data: data, thumbnail: image)
        } else {
            dismiss()
        }
    }
}

/// VisionKit's document scanner — auto-detects edges, crops, and corrects
/// perspective, giving a cleaner scan than a plain camera photo. Only the
/// first page is used (the app submits one receipt at a time).
struct DocumentScannerView: UIViewControllerRepresentable {
    let onScan: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: (UIImage?) -> Void
        init(onScan: @escaping (UIImage?) -> Void) { self.onScan = onScan }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let image = scan.pageCount > 0 ? scan.imageOfPage(at: 0) : nil
            onScan(image)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onScan(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onScan(nil)
        }
    }
}

/// UIKit camera wrapped for SwiftUI. iOS 16 has no SwiftUI-native camera API.
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void
        init(onCapture: @escaping (UIImage?) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
