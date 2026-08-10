import SwiftUI

/// Lists suspected duplicate receipts (see `DuplicateDetectionService`) two
/// at a time, side by side, so a human can look at the actual photos and
/// decide — never auto-deletes anything. Reached after a category merge,
/// which is exactly where a duplicate is likeliest to have gone unnoticed:
/// the submit-time check in `SubmissionPipeline.run` only compares within
/// one category, so a case-mismatched split (the bug category-merge exists
/// to clean up) could hide a real duplicate from it entirely.
struct DuplicateReviewView: View {
    /// A binding, not a copy — deleting a pair here needs to be visible to
    /// whatever badge/count the presenting screen shows (e.g. "Review 2
    /// Possible Duplicates"), and a `Binding` keeps that in sync for free
    /// instead of needing a separate callback to stay accurate.
    @Binding var pairs: [DuplicateDetectionService.Pair]
    /// Entries currently being deleted — drives the per-row spinner. Deletion
    /// runs through `NSFileCoordinator` (rewriting the CSV), which can
    /// genuinely stall for a few seconds if something else has a claim on
    /// that file (e.g. the Files app browsing the same folder); without this,
    /// a slow delete looked identical to a broken one.
    @State private var deletingIDs: Set<UUID> = []
    @State private var editingEntry: HistoryEntry?

    var body: some View {
        Group {
            if pairs.isEmpty {
                ContentUnavailableCompatView(
                    title: "No Duplicates Left",
                    message: "Every suspected duplicate on this screen has been resolved.")
            } else {
                List {
                    ForEach(pairs) { pair in
                        Section {
                            row(for: pair.first)
                            row(for: pair.second)
                        } header: {
                            Text(pair.confidence.rawValue)
                                .foregroundStyle(pair.confidence == .likely ? .red : .orange)
                        }
                    }
                }
            }
        }
        .navigationTitle("Possible Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingEntry) { entry in
            EditReceiptView(
                entry: entry,
                onCancel: { editingEntry = nil },
                onComplete: {
                    editingEntry = nil
                    // Same refresh mechanism the delete path already uses —
                    // any presenting screen bound to a live (non-snapshot)
                    // `pairs` source (the main Receipts screen's duplicates
                    // banner) will recompute and drop this pair if the edit
                    // fixed whatever made it look like a duplicate.
                    NotificationCenter.default.post(name: .receiptDropDidUpdateHistory, object: nil)
                })
        }
    }

    @ViewBuilder
    private func row(for entry: HistoryEntry) -> some View {
        Button {
            editingEntry = entry
        } label: {
            HStack(spacing: 12) {
                thumbnail(for: entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.vendor.isEmpty ? "(no vendor)" : entry.vendor)
                        .font(.subheadline.weight(.semibold))
                    Text("\(entry.workDate.isEmpty ? "no date" : entry.workDate) · $\(entry.amount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.category)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if deletingIDs.contains(entry.id) {
                    ProgressView()
                } else {
                    Button(role: .destructive) {
                        delete(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Loads the file synchronously on the main thread — same tradeoff
    /// `EditReceiptView.existingImage` already makes for a single photo;
    /// acceptable here too since duplicate pairs are expected to be rare,
    /// not a long scrolling gallery.
    @ViewBuilder
    private func thumbnail(for entry: HistoryEntry) -> some View {
        if let url = LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink),
           let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
        }
    }

    /// Runs off the main thread — `LocalReceiptStore.deleteEntry` rewrites
    /// the category's CSV through `NSFileCoordinator`, which can block for
    /// real seconds under contention. Calling it directly from the button
    /// action (as this used to) froze the whole screen with no feedback for
    /// however long that took, which read as "did nothing" or "is broken."
    private func delete(_ entry: HistoryEntry) {
        guard !deletingIDs.contains(entry.id) else { return }
        deletingIDs.insert(entry.id)
        Task {
            SubmissionStore.removeHistory(entry)
            try? LocalReceiptStore.deleteEntry(
                category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
                amount: entry.amount, receiptFilename: entry.receiptLink, extraFiles: entry.extraFiles)
            await MainActor.run {
                deletingIDs.remove(entry.id)
                // Drop every remaining pair that referenced this entry — a
                // pair is only meaningful while both sides still exist.
                pairs.removeAll { $0.first.id == entry.id || $0.second.id == entry.id }
                // The delete itself already succeeded by this point — this
                // is what tells the Receipts screen (a different view up the
                // navigation stack) to actually reload. Without it, that
                // screen's own `.onAppear` doesn't reliably refire when
                // popping back from a pushed view, so it kept showing the
                // deleted entry until something else (e.g. a tab switch)
                // happened to force a refresh — looked exactly like a slow
                // or "lazy" delete, when the data was already gone.
                NotificationCenter.default.post(name: .receiptDropDidUpdateHistory, object: nil)
            }
        }
    }
}
