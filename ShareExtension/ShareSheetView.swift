import SwiftUI
import UniformTypeIdentifiers

/// Loads the attachment(s) handed to us by the OS share sheet, then routes
/// to either the single-receipt flow (Shared/ReceiptSubmitView — live AI
/// extraction, unchanged) or the multi-receipt durable-first batch flow
/// (ExtensionBatchSubmitView), depending on how many usable items were
/// actually shared.
struct ShareSheetView: View {
    let onCancel: () -> Void
    let onComplete: () -> Void
    let extensionItems: [NSExtensionItem]
    /// Opens the main app via `extensionContext?.open(_:completionHandler:)`
    /// — a share extension has no `UIApplication.shared`, so this is the only
    /// sandbox-safe way back. See ShareViewController for the actual call.
    let onOpenMainApp: () -> Void

    @State private var attachment: SharedAttachment?
    @State private var batchAttachments: [SharedAttachment]?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let attachment {
                ReceiptSubmitView(attachment: attachment, onCancel: onCancel, onComplete: onComplete)
            } else if let batchAttachments {
                ExtensionBatchSubmitView(attachments: batchAttachments, onCancel: onCancel, onComplete: onComplete)
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
                    .navigationTitle("Receipts4Tax")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                        }
                    }
                }
            }
        }
        // A low-key way back for someone meeting this app for the first time
        // via the share sheet — they've never seen an AI-provider setup
        // screen or their receipt history, and nothing else in this extension
        // hints those exist. Sits below every state (loading, single-receipt,
        // batch) rather than inside any one of them, so it doesn't compete
        // with the actual submit flow and doesn't require touching
        // ReceiptSubmitView.
        .safeAreaInset(edge: .bottom) {
            Button(action: onOpenMainApp) {
                Text("Connect an AI provider or see all your receipts — open Receipts4Tax")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .onAppear(perform: loadAttachments)
    }

    // MARK: - Attachment loading

    /// Dispatches to the single- or multi-item loader based on how many
    /// providers actually conform to image or PDF (an item the OS offers but
    /// that's neither doesn't count toward "how many photos did the user
    /// pick"). Exactly 0 or 1 eligible providers keeps the original
    /// single-attachment code path byte-for-byte, so the single-receipt flow
    /// (and its exact error text) is unchanged.
    private func loadAttachments() {
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        let eligible = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
        }

        guard eligible.count > 1 else {
            loadSingleAttachment(providers: providers)
            return
        }

        loadBatchAttachments(providers: eligible)
    }

    /// Original (pre-multi-select) loading logic, unchanged: picks the first
    /// image provider, falling back to the first PDF provider, and ignores
    /// the rest. Kept as its own path (rather than routed through the
    /// TaskGroup batch loader below with a "batch of one" special case) so
    /// the single-receipt share flow is provably identical to what shipped
    /// before this feature.
    private func loadSingleAttachment(providers: [NSItemProvider]) {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                // `loadDataRepresentation`'s callback already runs off the
                // main thread, but the old code then explicitly hopped onto
                // it (`DispatchQueue.main.async`) to do the decode — full
                // resolution, just to build a thumbnail. Build the
                // thumbnail here, still off-main, and only hop over to
                // publish the result.
                guard let data else {
                    DispatchQueue.main.async { loadError = "Couldn't read the image." }
                    return
                }
                let thumbnail = AttachmentThumbnail.downsampled(from: data)
                DispatchQueue.main.async {
                    if thumbnail != nil {
                        attachment = SharedAttachment(kind: .image, data: data, thumbnail: thumbnail)
                    } else {
                        loadError = "Couldn't read the image."
                    }
                }
            }
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                guard let data else {
                    DispatchQueue.main.async { loadError = "Couldn't read the PDF." }
                    return
                }
                let thumbnail = pdfThumbnail(data)
                DispatchQueue.main.async {
                    attachment = SharedAttachment(kind: .pdf, data: data, thumbnail: thumbnail)
                }
            }
        } else {
            loadError = "No image or PDF found in the shared item."
        }
    }

    /// Loads every eligible provider in parallel. `loadDataRepresentation` is
    /// callback-based, so a `TaskGroup` bridges each provider's callback into
    /// an async task and collects results, updating state only once every
    /// one has settled. A provider that fails to load is skipped rather than
    /// aborting the whole batch — the count that actually lands in
    /// `batchAttachments` may end up smaller than what the user picked, but
    /// nothing about that is silent: it's exactly the count shown next in
    /// ExtensionBatchSubmitView.
    ///
    /// No thumbnails are generated here (`SharedAttachment.thumbnail: nil`)
    /// — see the plan's Memory section: holding several full-size decoded
    /// `UIImage`s at once alongside their raw `Data` is the likeliest crash
    /// source under the extension's tight memory budget, and the batch UI
    /// only ever displays a count, never a thumbnail.
    private func loadBatchAttachments(providers: [NSItemProvider]) {
        Task {
            let loaded = await withTaskGroup(of: SharedAttachment?.self) { group -> [SharedAttachment] in
                for provider in providers {
                    group.addTask { await Self.loadForBatch(provider: provider) }
                }
                var results: [SharedAttachment] = []
                for await result in group where result != nil {
                    results.append(result!)
                }
                return results
            }
            guard !loaded.isEmpty else {
                loadError = "Couldn't read any of the shared items."
                return
            }
            batchAttachments = loaded
        }
    }

    private static func loadForBatch(provider: NSItemProvider) async -> SharedAttachment? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            guard let data = await loadData(from: provider, typeIdentifier: UTType.image.identifier),
                  UIImage(data: data) != nil else { return nil }
            return SharedAttachment(kind: .image, data: data, thumbnail: nil)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            guard let data = await loadData(from: provider, typeIdentifier: UTType.pdf.identifier) else { return nil }
            return SharedAttachment(kind: .pdf, data: data, thumbnail: nil)
        }
        return nil
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
