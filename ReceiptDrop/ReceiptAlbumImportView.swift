import Photos
import SwiftUI
import UIKit

/// The review tray for the "Receipts Only" album: shows what the user has
/// dropped in there, lets them pick which ones to file, and submits the
/// chosen ones through the normal pipeline.
///
/// Nothing is extracted, saved, or charged to the user's API key until they
/// tap Import. That is the whole reason this screen exists rather than the
/// album feeding `SubmissionPipeline` directly: an auto-submit would spend
/// real money on whatever happened to be in the album and would write tax
/// records nobody confirmed — the failure `b711974` and `3220a4f` exist to
/// prevent. One tap is the price of never doing that.
struct ReceiptAlbumImportView: View {
    let onDone: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var selectedCategory: String = ""
    @State private var items: [Item] = []
    @State private var selection: Set<String> = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var progress = ""
    @State private var importedCount: Int?

    private struct Item: Identifiable {
        let asset: PHAsset
        let thumbnail: UIImage?
        var id: String { asset.localIdentifier }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Reading album…")
                } else if let importedCount {
                    doneView(count: importedCount)
                } else if items.isEmpty {
                    emptyView
                } else {
                    listView
                }
            }
            .navigationTitle(ReceiptAlbumService.albumTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone).disabled(isImporting)
                }
            }
        }
        .task { await load() }
    }

    private var listView: some View {
        Form {
            Section {
                Picker("Category", selection: $selectedCategory) {
                    ForEach(categoryStore.categories, id: \.self) { Text($0) }
                }
                .adaptiveCategoryPickerStyle(count: categoryStore.categories.count)
                .disabled(isImporting)
            } footer: {
                Text("Every receipt in this import is filed under one category. Import them in groups if they belong in different ones.")
            }

            Section {
                ForEach(items) { item in
                    Button {
                        toggle(item.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(item.id) ? Color.accentColor : .secondary)
                            if let thumbnail = item.thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dateText(item.asset))
                                    .font(.subheadline)
                                Text("Not yet filed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isImporting)
                }
            } header: {
                HStack {
                    Text("\(items.count) waiting")
                    Spacer()
                    Button(selection.count == items.count ? "Select None" : "Select All") {
                        selection = selection.count == items.count ? [] : Set(items.map(\.id))
                    }
                    .font(.caption)
                    .disabled(isImporting)
                }
            }

            Section {
                if isImporting {
                    HStack {
                        ProgressView()
                        Text(progress).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await importSelected() }
                    } label: {
                        HStack {
                            Spacer()
                            Text(selection.isEmpty ? "Select receipts to import"
                                 : "Import \(selection.count)").bold()
                            Spacer()
                        }
                    }
                    .disabled(selection.isEmpty || selectedCategory.isEmpty)
                }
            } footer: {
                Text("Imported photos are read by your AI provider and filed as receipts, then removed from the album. They stay in your photo library.")
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Nothing waiting")
                .font(.headline)
            Text("Add receipt photos to the \"\(ReceiptAlbumService.albumTitle)\" album in Photos, and they'll show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func doneView(count: Int) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("\(count) sent for reading")
                .font(.headline)
            // Deliberately not "saved": the pipeline runs in the background
            // and a receipt can still fail extraction and land in the retry
            // queue. Claiming success here would be a lie roughly as often as
            // extraction fails.
            Text("They're being read now and will appear in Receipts as they finish. Anything that fails goes to the retry queue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func dateText(_ asset: PHAsset) -> String {
        guard let date = asset.creationDate else { return "Unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func load() async {
        if selectedCategory.isEmpty {
            selectedCategory = categoryStore.categories.first ?? ""
        }
        let assets = ReceiptAlbumService.pendingAssets()
        var loaded: [Item] = []
        for asset in assets {
            loaded.append(Item(asset: asset, thumbnail: await thumbnail(for: asset)))
        }
        items = loaded
        // Pre-selected: the user already curated this album by hand, so
        // everything in it is presumed wanted. The checkboxes are there to
        // *deselect* a mistake, not to make them pick twice.
        selection = Set(loaded.map(\.id))
        isLoading = false
    }

    private func thumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            // Thumbnails only, and local-only: this runs for every asset in
            // the album, and pulling originals from iCloud just to draw a
            // 44pt square would be slow and expensive on cellular. The full
            // image is fetched later, for the few actually imported.
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 200, height: 200),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Files the selected photos, then takes them out of the album.
    ///
    /// The ledger is written *before* submission, not after: a receipt whose
    /// extraction fails is still a receipt that was offered and acted on, and
    /// it lands in the retry queue where the user can see it. Marking it only
    /// on success would re-offer it here on the next scan while a copy sat in
    /// the queue — the same photo waiting in two places.
    private func importSelected() async {
        isImporting = true
        defer { isImporting = false }

        let chosen = items.filter { selection.contains($0.id) }
        var attachments: [SharedAttachment] = []
        for (index, item) in chosen.enumerated() {
            progress = "Reading \(index + 1) of \(chosen.count)…"
            guard let data = await ReceiptAlbumService.imageData(for: item.asset) else { continue }
            attachments.append(SharedAttachment(kind: .image, data: data, thumbnail: item.thumbnail))
        }

        guard !attachments.isEmpty else {
            importedCount = 0
            return
        }

        ImportedAssetLedger.markFiled(chosen.map(\.id))
        BatchSubmissionRunner.submit(attachments: attachments, category: selectedCategory)
        await ReceiptAlbumService.removeFromAlbum(chosen.map(\.asset))
        importedCount = attachments.count
    }
}
