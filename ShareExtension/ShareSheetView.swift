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

        var isOvernight: Bool {
            if case .overnight = self { return true }
            return false
        }
    }

    private var count: Int { batchAttachments?.count ?? (attachment == nil ? 0 : 1) }
    private var isSingle: Bool { count == 1 }

    var body: some View {
        Group {
            if submitNow, let attachment {
                ReceiptSubmitView(attachment: attachment, onCancel: onCancel,
                                  onComplete: onComplete, initialCategory: category)
            } else {
                card
            }
        }
        .sheet(isPresented: $showCategoryPicker) {
            categoryPicker
        }
        .onAppear(perform: loadAttachments)
    }

    /// The extension's own look, deliberately unlike the app's: a single dark
    /// card floating over whatever the user was doing, rather than another
    /// Form that reads as "you are now in Receipts4Tax". The point is that
    /// this is a passing interruption — glance, tap, gone — and it should not
    /// feel like arriving somewhere.
    private var card: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 18) {
                header
                if let loadError {
                    Text(loadError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                } else if let parked {
                    confirmation(parked)
                } else if attachment != nil || batchAttachments != nil {
                    choices
                    categoryChip
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(height: 96)
                }
                firstRunLink
            }
            .padding(20)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        // Transparent so the card reads as an overlay on the user's photos
        // rather than a screen that replaced them.
        .background(Color.clear)
    }

    private var cardBackground: some View {
        LinearGradient(
            colors: [Color(red: 0.11, green: 0.13, blue: 0.28),
                     Color(red: 0.06, green: 0.07, blue: 0.16)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Title centred in the card, close button overlaid at the trailing
    /// edge. A ZStack rather than an HStack with a Spacer: the latter centres
    /// the title in the space *left over* beside the button, which puts it
    /// visibly off-centre in a card this narrow.
    private var header: some View {
        ZStack {
            Text(count == 1 ? "Process 1 receipt" : "Process \(count) receipts")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                // Keeps a long count clear of the close button rather than
                // sliding under it.
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(7)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .disabled(parked != nil)
                .accessibilityLabel("Cancel")
            }
        }
    }

    /// Two tiles, side by side, no explanatory text under either.
    ///
    /// The wording carries the whole difference — "Now" against "Tonight" —
    /// because anything longer is something to read, and this screen exists
    /// to be answered without reading. What each one does precisely is in the
    /// app's queue, where the user can act on it; here it would only slow the
    /// tap down.
    private var choices: some View {
        HStack(spacing: 12) {
            choiceTile(title: "Now", icon: "bolt.fill",
                       tint: Color(red: 0.30, green: 0.72, blue: 1.0),
                       action: readNow)
            choiceTile(title: "Tonight", icon: "moon.stars.fill",
                       tint: Color(red: 0.62, green: 0.55, blue: 1.0),
                       action: readOvernight)
        }
    }

    private func choiceTile(title: String, icon: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                Text(title)
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(tint.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The category, small and quiet. Visible so a receipt is never silently
    /// misfiled, tappable so it can be fixed, and sized so nobody feels
    /// obliged to think about it.
    private var categoryChip: some View {
        Button {
            showCategoryPicker = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").font(.caption2)
                Text(category)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Only for someone who has never set up a provider — otherwise this is a
    /// line of text on every share, for a trip into the app they do not need
    /// to make. Read straight from the App Group defaults rather than through
    /// ConnectAIView, which lives in the app target.
    @ViewBuilder
    private var firstRunLink: some View {
        if !hasCompletedAISetup {
            Button(action: onOpenMainApp) {
                Text("Set up Receipts4Tax to read these")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
    }

    private var hasCompletedAISetup: Bool {
        UserDefaults(suiteName: AppConstants.appGroupID)?
            .bool(forKey: AppConstants.DefaultsKeys.hasCompletedAISetup) ?? false
    }

    @ViewBuilder
    private func confirmation(_ result: ParkResult) -> some View {
        // Asked of the value rather than compared against
        // `.overnight(count)`: the parked count is whatever actually got
        // written, which can be smaller than the number shared if a provider
        // failed to load.
        let isOvernight = result.isOvernight
        VStack(spacing: 10) {
            // The same pair the app's Receipts banner and Pending list
            // use (QueuedIcons), so what the user is shown here is what they
            // will recognise in the app a moment later. Both cases are
            // queued — neither has been read yet — so both keep the clock;
            // only the moon differs.
            QueuedIcons(includesDeferred: isOvernight)
                .font(.system(size: 30))
                .foregroundStyle(isOvernight
                                 ? Color(red: 0.62, green: 0.55, blue: 1.0)
                                 : Color(red: 0.30, green: 0.85, blue: 0.55))
            Text(isOvernight ? "Saved for tonight" : "Saved")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .frame(height: 96)
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
