import QuickLook
import SwiftUI

/// Full-screen preview of a saved receipt file (image or PDF) using iOS's
/// built-in Quick Look, so History rows can open the actual file with zoom,
/// share, and markup already supported for free. Accepts multiple URLs (a
/// primary receipt plus any extra attachments) — QuickLook shows these as a
/// swipeable gallery with a thumbnail strip, with no extra code needed.
struct ReceiptPreviewView: UIViewControllerRepresentable {
    let urls: [URL]

    init(url: URL) { self.urls = [url] }
    init(urls: [URL]) { self.urls = urls }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(urls: urls) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        init(urls: [URL]) { self.urls = urls }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}
