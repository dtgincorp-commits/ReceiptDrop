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

extension ReceiptPreviewSheet {
    /// Primary file first, then any extras, skipping any that can't be found
    /// (e.g. moved or deleted outside the app) rather than failing the whole
    /// preview. Shared so every screen that opens a receipt resolves its
    /// files the same way — the Receipts list, Edit, and duplicate review
    /// all need exactly this and had no business each having their own copy.
    static func urls(for entry: HistoryEntry) -> [URL] {
        var urls: [URL] = []
        if let primary = LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink) {
            urls.append(primary)
        }
        for extra in entry.extraFiles {
            if let url = LocalReceiptStore.existingFileURL(category: entry.category, filename: extra) {
                urls.append(url)
            }
        }
        return urls
    }
}

/// Wraps the Quick Look preview with a fixed bottom bar that summarizes the
/// receipt (category, vendor, date, amount) and gives an always-visible Done
/// button — Quick Look on its own doesn't reliably show a way out when it's
/// presented in a sheet, which made these previews hard to dismiss.
struct ReceiptPreviewSheet: View {
    let entry: HistoryEntry
    let urls: [URL]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ReceiptPreviewView(urls: urls)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.category)
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.skyBlueBright)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        Text(entry.vendor.isEmpty ? "Unknown vendor" : entry.vendor)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        if !entry.workDate.isEmpty {
                            Label(entry.workDate, systemImage: "calendar")
                        }
                        if !entry.amount.isEmpty {
                            Label("$\(entry.amount)", systemImage: "dollarsign.circle")
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.skyBlue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }
}
