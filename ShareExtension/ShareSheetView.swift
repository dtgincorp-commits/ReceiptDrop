import SwiftUI
import UniformTypeIdentifiers

/// The share extension's whole interface: one question, two answers.
///
/// "Read now" or "Read overnight" is the only decision worth interrupting
/// someone for at the moment they are sharing — everything else the old sheet
/// asked (which category, which submit button, are you sure) has an answer
/// the app can supply or defer. The category is shown rather than asked,
/// seeded from `LastUsedCategoryStore`, and is one tap away if wrong.
///
/// "Now" means different things by count, and the copy says so rather than
/// pretending otherwise:
///
/// - **One receipt** is extracted here, in the sheet, result and all — a
///   single AI round-trip is safe to hold because there is nothing else in
///   flight to lose if iOS kills this process.
/// - **Several receipts** are queued and read the next time the app opens.
///   Running N round-trips inside an extension is exactly the failure
///   SHARE_EXTENSION_MULTI_RECEIPT_PLAN.md's "critical constraint" describes:
///   the process can be suspended after `completeRequest`, and photo 3 of 5
///   would vanish mid-extraction with nothing saved and no error shown.
struct ShareSheetView: View {
    let onCancel: () -> Void
    let onComplete: () -> Void
    let extensionItems: [NSExtensionItem]
    /// Opens the main app via `extensionContext?.open(_:completionHandler:)`
    /// — a share extension has no `UIApplication.shared`, so this is the only
    /// sandbox-safe way back. See ShareViewController for the actual call.
    let onOpenMainApp: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var attachment: SharedAttachment?
    @State private var batchAttachments: [SharedAttachment]?
    @State private var loadError: String?
    @State private var category = LastUsedCategoryStore.current
    @State private var showCategoryPicker = false
    /// Set once the user picks "Read now" for a single receipt — hands off to
    /// the full submit flow, which is unchanged.
    @State private var submitNow = false
    @State private var parked: ParkResult?

    private enum ParkResult: Equatable {
        case now(Int)
        case overnight(Int)
    }

    var body: some View {
        Group {
            if submitNow, let attachment {
                ReceiptSubmitView(attachment: attachment, onCancel: onCancel,
                                  onComplete: onComplete, initialCategory: category)
            } else {
                NavigationStack {
                    Group {
                        if let loadError {
                            Label(loadError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        } else if let parked {
                            confirmation(parked)
                        } else if attachment != nil || batchAttachments != nil {
                            choices
                        } else {
                            ProgressView("Loading receipt…")
                        }
                    }
                    .navigationTitle("Receipts4Tax")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                                .disabled(parked != nil)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // A low-key way back for someone meeting this app for the first
            // time via the share sheet — they've never seen an AI-provider
            // setup screen or their receipt history, and nothing else in this
            // extension hints those exist.
            Button(action: onOpenMainApp) {
                Text("Connect an AI provider or see all your receipts — open Receipts4Tax")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .sheet(isPresented: $showCategoryPicker) {
            categoryPicker
        }
        .onAppear(perform: loadAttachments)
    }

    private var count: Int { batchAttachments?.count ?? (attachment == nil ? 0 : 1) }
    private var isSingle: Bool { count == 1 }

    private var choices: some View {
        Form {
            Section {
                Button {
                    showCategoryPicker = true
                } label: {
                    HStack {
                        Text("Filing under")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(category).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text(count == 1 ? "1 receipt" : "\(count) receipts")
            }

            Section {
                Button {
                    readNow()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read Now").bold()
                        Text(isSingle
                             ? "Reads it here and shows you the result."
                             : "Queued now, read the next time you open Receipts4Tax.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    readOvernight()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read Overnight")
                        // Honest about the one thing iOS will not promise:
                        // background runs are granted at the system's
                        // discretion, so the app falls back to reading held
                        // receipts on next open after a day.
                        Text("Saved now, read tonight — or next time you open the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Either way your receipts are saved on this phone straight away.")
            }
        }
    }

    @ViewBuilder
    private func confirmation(_ result: ParkResult) -> some View {
        VStack(spacing: 10) {
            switch result {
            case .now(let n):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34)).foregroundStyle(.green)
                Text("\(n) receipt\(n == 1 ? "" : "s") saved")
                    .font(.headline)
                Text("They'll be read the next time you open Receipts4Tax.")
                    .font(.caption).foregroundStyle(.secondary)
            case .overnight(let n):
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 34)).foregroundStyle(.indigo)
                Text("\(n) receipt\(n == 1 ? "" : "s") saved for tonight")
                    .font(.headline)
                Text("They'll be read overnight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private var categoryPicker: some View {
        NavigationStack {
            List(categoryStore.categories, id: \.self) { name in
                Button {
                    category = name
                    showCategoryPicker = false
                } label: {
                    HStack {
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        if name == category {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showCategoryPicker = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func readNow() {
        // One receipt is safe to extract in-process; several are not. See
        // this type's doc comment.
        if isSingle, attachment != nil {
            submitNow = true
            return
        }
        park(held: false)
    }

    private func readOvernight() {
        park(held: true)
    }

    /// Writes every attachment durably before anything that could end this
    /// view's lifetime, then confirms. All local file writes, no network, so
    /// by the time the confirmation shows, the receipts are already safe.
    private func park(held: Bool) {
        let items = batchAttachments ?? [attachment].compactMap { $0 }
        for item in items {
            let kind: ReceiptKind = item.kind == .image ? .image : .pdf
            let data: Data
            if item.kind == .image, let jpeg = UIImage(data: item.data)?.jpegData(compressionQuality: 0.85) {
                data = jpeg
            } else {
                data = item.data
            }
            if held {
                SubmissionStore.enqueueHeld(data: data, category: category, kind: kind)
            } else {
                SubmissionStore.enqueuePending(data: data, category: category, kind: kind)
            }
        }
        // Remember the choice for next time — the user picking a category
        // here is as strong a signal as filing one in the app.
        LastUsedCategoryStore.record(category)
        parked = held ? .overnight(items.count) : .now(items.count)
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            onComplete()
        }
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
