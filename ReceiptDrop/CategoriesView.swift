import SwiftUI
import UIKit

/// One home for everything category-related: the editable category list
/// (moved out of Settings) and per-category maintenance. Reached from
/// Settings ("Categories ›") and from the Receipts screen's sort menu
/// ("Categories").
struct CategoriesView: View {
    /// True when reached via "Add Category" (rather than "Categories") —
    /// the new-category field gets keyboard focus immediately so the user
    /// can start typing without an extra tap.
    var focusNewCategoryOnAppear: Bool = false

    /// Lets a presenter turn the detail screen's Receipts row into a jump to
    /// a filtered Receipts list instead of a dead label. Receipts' own
    /// "Categories" sheet wires this straight to its local
    /// `filterCategory` + dismiss; Settings → Categories (which has no
    /// Receipts list of its own underneath it) wires it through
    /// `ReceiptsNavigator` to jump tabs instead. Defaulted to nil rather than
    /// required so any future caller with genuinely nothing to jump to can
    /// still opt out and get the plain inert label.
    var onShowReceipts: ((String) -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var categoryStore = CategoryStore.shared
    /// Loaded once (not re-read per row) and kept fresh the same way
    /// `ReceiptsView` keeps its own copy fresh: on appear, on foreground, and
    /// on `.receiptDropDidUpdateHistory` (posted below after delete-with-
    /// receipts, and by `CategoryDetailView` after merge/rename). Before this,
    /// every row called `SubmissionStore.loadHistory()` — a UserDefaults read
    /// + full JSON decode — once per category, on every body evaluation.
    @State private var history: [HistoryEntry] = []
    @State private var newCategory = ""
    @State private var addCategoryError: String?
    @FocusState private var newCategoryFieldFocused: Bool
    /// Long-form text moved out of the section footer — see
    /// `SettingsInfoLink`. The footer keeps one sentence; the detail lives here.
    @State private var infoTopic: SettingsInfoTopic?

    /// Set when a swipe-to-delete lands on a category that still has
    /// receipts — deletion then goes through a confirmation offering both
    /// meanings of "delete a category" (drop the label, or destroy the
    /// receipts too) instead of silently picking one. Empty categories skip
    /// all of this and delete immediately; there's nothing to warn about.
    @State private var pendingDelete: (name: String, receiptCount: Int)?
    @State private var showDeleteOptions = false
    @State private var isDeletingCategory = false
    @State private var deleteMessage: String?
    @State private var deleteError: String?

    var body: some View {
        Form {
            Section {
                ForEach(categoryStore.categories, id: \.self) { category in
                    NavigationLink {
                        CategoryDetailView(category: category, onShowReceipts: onShowReceipts)
                    } label: {
                        HStack {
                            Text(category)
                            Spacer()
                            Text("\(receiptCount(for: category))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: confirmDelete)

                HStack {
                    TextField("New category", text: $newCategory)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($newCategoryFieldFocused)
                        .onSubmit(addCategory)
                    Button(action: addCategory) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Add Category")
                    .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let addCategoryError {
                    Text(addCategoryError).font(.caption).foregroundStyle(.red)
                }
                if isDeletingCategory {
                    HStack { ProgressView(); Text("Backing up, then deleting…").font(.caption) }
                        .accessibilityElement(children: .combine)
                }
                if let deleteMessage {
                    Text(deleteMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let deleteError {
                    Text(deleteError).font(.caption).foregroundStyle(.red)
                }

                SettingsInfoButton(
                    title: "Categories",
                    detail: """
                        Every category gets its own folder, under Files → On My iPhone → Receipts4Tax. A category named "Office Supplies" gets a folder at Receipts4Tax/Office Supplies.

                        That folder holds one CSV log named Office Supplies_log.csv, plus the receipt image and PDF files themselves — all sitting right alongside the log, not tucked away elsewhere.

                        These are ordinary files: open, copy, or back them up yourself anytime, no proprietary format required.

                        Swipe left on a category to delete it.

                        Tap a category to see its receipt count and maintenance actions — rename, merge, rebuild its log, or open its CSV.
                        """,
                    topic: $infoTopic)
            } header: {
                Text("Categories")
            } footer: {
                Text("Each category gets its own folder and CSV log in the Files app.")
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .settingsInfoSheet(topic: $infoTopic)
        .onAppear {
            reloadHistory()
            if focusNewCategoryOnAppear {
                newCategoryFieldFocused = true
            }
        }
        .onChange(of: scenePhase) { if $0 == .active { reloadHistory() } }
        .onReceive(NotificationCenter.default.publisher(for: .receiptDropDidUpdateHistory)) { _ in
            reloadHistory()
        }
        .onChange(of: newCategory) { _ in addCategoryError = nil }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "")?",
            isPresented: $showDeleteOptions,
            titleVisibility: .visible
        ) {
            if let pendingDelete {
                Button("Delete Category and \(pendingDelete.receiptCount) Receipt\(pendingDelete.receiptCount == 1 ? "" : "s")", role: .destructive) {
                    deleteWithReceipts(pendingDelete.name)
                }
                Button("Delete Category Only") {
                    deleteCategoryOnly(pendingDelete.name)
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let pendingDelete {
                Text("""
                    \(pendingDelete.name) has \(pendingDelete.receiptCount) receipt\(pendingDelete.receiptCount == 1 ? "" : "s").

                    Delete Category Only removes just the label — the receipts stay in your history and still show under All, but with no filter for this category.

                    Deleting the receipts too can't be undone except by restoring the full backup that's made first.
                    """)
            }
        }
    }

    /// Categories with no receipts delete straight away — the confirmation
    /// exists to disambiguate what should happen to receipts, so with none
    /// there's nothing to ask about.
    private func confirmDelete(at offsets: IndexSet) {
        deleteMessage = nil
        deleteError = nil
        guard let index = offsets.first else { return }
        let name = categoryStore.categories[index]
        let count = receiptCount(for: name)
        guard count > 0 else {
            categoryStore.remove(at: offsets)
            return
        }
        pendingDelete = (name: name, receiptCount: count)
        showDeleteOptions = true
    }

    private func deleteCategoryOnly(_ name: String) {
        categoryStore.remove(named: name)
        deleteMessage = "Removed \(name) from the list. Its receipts are still in your history, under All."
        pendingDelete = nil
    }

    private func deleteWithReceipts(_ name: String) {
        isDeletingCategory = true
        Task {
            do {
                let summary = try CategoryDeleteService.deleteWithReceipts(name)
                await MainActor.run {
                    isDeletingCategory = false
                    pendingDelete = nil
                    deleteMessage = "Backed up to Files → On My iPhone → Receipts4Tax → Backups → \(summary.backupFilename). Deleted \(name) and \(summary.receiptsDeleted) receipt\(summary.receiptsDeleted == 1 ? "" : "s")."
                    // Refreshes this screen's own cached history immediately
                    // (rather than waiting for the next appear/foreground)
                    // and lets any other observer — Receipts underneath this
                    // sheet, a still-open CategoryDetailView — pick up the
                    // deletion too.
                    reloadHistory()
                    NotificationCenter.default.post(name: .receiptDropDidUpdateHistory, object: nil)
                }
            } catch {
                await MainActor.run {
                    isDeletingCategory = false
                    pendingDelete = nil
                    deleteError = "Backup failed, so nothing was deleted: \(error.localizedDescription)"
                }
            }
        }
    }

    private func addCategory() {
        let trimmed = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if categoryStore.add(trimmed) {
            newCategory = ""
            addCategoryError = nil
        } else {
            addCategoryError = "\"\(trimmed.uppercased())\" already exists."
        }
    }

    private func reloadHistory() {
        history = SubmissionStore.loadHistory()
    }

    /// Case-insensitive, matching the Receipts screen's category filter and
    /// the merge/rename/delete services. Matters more than cosmetically
    /// here: this count decides whether a swipe-to-delete asks about
    /// receipts at all, so undercounting mixed-case ones would silently
    /// orphan exactly the receipts the confirmation exists to protect.
    ///
    /// Derives from the cached `history` array rather than re-reading —
    /// see `history`'s doc comment. `Self.receiptCount(for:in:)` is the pure
    /// half, split out so it's testable without a live SubmissionStore.
    private func receiptCount(for category: String) -> Int {
        Self.receiptCount(for: category, in: history)
    }

    static func receiptCount(for category: String, in history: [HistoryEntry]) -> Int {
        history.filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }.count
    }
}

/// Per-category detail: receipt count, a jump to the CSV in the Files app,
/// and the rebuild-log maintenance action.
struct CategoryDetailView: View {
    let category: String

    /// See `CategoriesView.onShowReceipts`. Both current entry points
    /// (Receipts' own sheet, Settings → Categories) supply this; nil stays
    /// supported so a hypothetical future caller with nothing to jump to
    /// gets a plain label instead.
    var onShowReceipts: ((String) -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var categoryStore = CategoryStore.shared
    /// Loaded once and kept fresh on appear/foreground/notification, same
    /// reasoning as `CategoriesView.history` — this screen's `entries` used
    /// to call `SubmissionStore.loadHistory()` on every body evaluation
    /// (every alert message, every keystroke in the description field).
    @State private var history: [HistoryEntry] = []
    @State private var descriptionInput: String
    @State private var showRebuildConfirm = false
    @State private var rebuildMessage: String?
    @State private var missingCSVAlert = false

    @State private var mergeDestination: String?
    @State private var showMergeConfirm = false
    @State private var isMerging = false
    @State private var mergeMessage: String?
    @State private var mergeError: String?
    @State private var duplicateGroups: [DuplicateDetectionService.Group] = []

    @State private var renameInput = ""
    @State private var showRenameConfirm = false
    @State private var isRenaming = false
    @State private var renameError: String?
    /// Separate from `showRenameConfirm`: tapping the title is a quick path
    /// that combines "type the new name" and "confirm" into one alert
    /// (matching the Files/Photos app "Rename" pattern), rather than
    /// scrolling to the Rename section's own text field first. Both paths
    /// share `renameInput` and `rename()` — this is a second entry point
    /// into the same flow, not a separate one.
    @State private var showQuickRenameAlert = false

    /// Long-form text moved out of the section footers — see
    /// `SettingsInfoLink`. Footers keep one sentence; the detail lives here.
    @State private var infoTopic: SettingsInfoTopic?

    @Environment(\.dismiss) private var dismiss

    init(category: String, onShowReceipts: ((String) -> Void)? = nil) {
        self.category = category
        self.onShowReceipts = onShowReceipts
        _descriptionInput = State(initialValue: CategoryStore.shared.description(for: category))
        _renameInput = State(initialValue: category)
    }

    /// Case-insensitive, matching `CategoriesView.receiptCount` and the
    /// merge/rename services — this count appears in the rename and merge
    /// confirmations, which would otherwise understate how much is about to
    /// move. Derived from the cached `history` array — see its doc comment.
    private var entries: [HistoryEntry] {
        history.filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }
    }

    private func reloadHistory() {
        history = SubmissionStore.loadHistory()
    }

    var body: some View {
        Form {
            Section {
                if let onShowReceipts {
                    Button {
                        onShowReceipts(category)
                    } label: {
                        HStack {
                            Text("Receipts").foregroundStyle(.primary)
                            Spacer()
                            Text("\(entries.count)").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                } else {
                    HStack {
                        Text("Receipts")
                        Spacer()
                        Text("\(entries.count)").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                TextField("e.g. Expenses for my IT company", text: $descriptionInput, axis: .vertical)
                    .lineLimit(2...4)
                    .onSubmit { categoryStore.setDescription(descriptionInput, for: category) }

                SettingsInfoButton(
                    title: "Category Description",
                    detail: "Optional, but helps the AI write better Comments and flag receipts that look like they don't belong here. Saved automatically as you leave the field.",
                    topic: $infoTopic)
            } header: {
                Text("Category Description")
            } footer: {
                Text("Optional — helps the AI write better Comments.")
            }
            .onChange(of: descriptionInput) { newValue in
                categoryStore.setDescription(newValue, for: category)
            }

            Section {
                Button {
                    openCSV()
                } label: {
                    // Spreadsheet glyph ties both CSV actions together visually, distinct from the folder action below.
                    Label("View CSV in the Files app", systemImage: "tablecells")
                }
                Button {
                    editInNumbers()
                } label: {
                    // Hand-off arrow signals this leaves the app — the one action with a real consequence (Numbers keeps its own copy).
                    Label("Edit CSV in Numbers App", systemImage: "arrow.up.forward.app")
                }

                SettingsInfoButton(
                    title: "CSV and Files",
                    detail: "\"Edit CSV in Numbers\" hands \(category)_log.csv to the Numbers app via the system Open In menu — Numbers keeps its own copy, so edits there don't change the file the app writes to. \"Open \(category) folder\" shows every file in this category, including receipt photos and any extra attachments not listed in the CSV.",
                    topic: $infoTopic)
            } footer: {
                Text("Open or edit this category's CSV.")
            }

            Section {
                Button {
                    openCategoryFolder()
                } label: {
                    Label("Open \(category) folder in Files", systemImage: "folder")
                }
            } footer: {
                Text("Browse every file in this category, including receipt photos.")
            }

            Section {
                Button(role: .destructive) {
                    showRebuildConfirm = true
                } label: {
                    Label("Rebuild Log", systemImage: "arrow.triangle.2.circlepath")
                }
                if let rebuildMessage {
                    Text(rebuildMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsInfoButton(
                    title: "Maintenance",
                    detail: "Wipes and regenerates \(category)'s CSV log strictly from what's shown on the Receipts screen — fixes stray or duplicate rows. Comments on existing rows come back blank (they're only stored in the CSV); new receipts keep their Comments as usual. Other categories aren't affected.",
                    topic: $infoTopic)
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Rebuilds \(category)'s CSV log from what's on the Receipts screen.")
            }

            Section {
                TextField("Category name", text: $renameInput)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .disabled(isRenaming)
                Button {
                    showRenameConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        // The spinner replaces "Rename" entirely while the
                        // rename is in flight, so it needs its own label —
                        // otherwise the button silently goes from
                        // "Rename" to unlabeled while it's actually busy.
                        if isRenaming { ProgressView().accessibilityLabel("Renaming category") } else { Text("Rename") }
                        Spacer()
                    }
                }
                .disabled(isRenaming || renameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || renameInput.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(category) == .orderedSame)
                if let renameError {
                    Text(renameError).font(.caption).foregroundStyle(.red)
                }

                SettingsInfoButton(
                    title: "Rename",
                    detail: "Renames \(category) and moves its files to match — a full backup is made first. To combine it into an existing category instead, use Merge below. You can also rename by tapping \(category) at the top of this screen.",
                    topic: $infoTopic)
            } header: {
                Text("Rename")
            } footer: {
                Text("Renames \(category) and moves its files to match.")
            }

            if otherCategories.count > 0 {
                Section {
                    Picker("Merge Into", selection: $mergeDestination) {
                        Text("Select a category").tag(String?.none)
                        ForEach(otherCategories, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Button(role: .destructive) {
                        showMergeConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if isMerging { ProgressView().accessibilityLabel("Merging categories") } else { Text("Merge \(category) In…") }
                            Spacer()
                        }
                    }
                    .disabled(isMerging || mergeDestination == nil)
                    if let mergeMessage {
                        Label(mergeMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    if !duplicateGroups.isEmpty {
                        NavigationLink {
                            DuplicateReviewView(groups: $duplicateGroups)
                        } label: {
                            Label("Review \(duplicateGroups.count) Possible Duplicate\(duplicateGroups.count == 1 ? "" : "s")",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let mergeError {
                        Text(mergeError).font(.caption).foregroundStyle(.red)
                    }

                    SettingsInfoButton(
                        title: "Merge",
                        detail: "Moves every receipt (photos and Comments included) from \(category) into the category you pick, then removes \(category) from the list. A full backup is made first. Useful for cleaning up an accidental duplicate — e.g. two categories that differ only in capitalization.",
                        topic: $infoTopic)
                } header: {
                    Text("Merge")
                } footer: {
                    Text("Moves every receipt into another category, then removes this one.")
                }
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
        .settingsInfoSheet(topic: $infoTopic)
        .onAppear(perform: reloadHistory)
        .onChange(of: scenePhase) { if $0 == .active { reloadHistory() } }
        .onReceive(NotificationCenter.default.publisher(for: .receiptDropDidUpdateHistory)) { _ in
            reloadHistory()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    renameInput = category
                    showQuickRenameAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Text(category).font(.headline).foregroundStyle(.primary)
                        Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .disabled(isRenaming)
                // The category name alone doesn't say this is tappable —
                // that's carried visually by the (now-hidden) pencil glyph.
                .accessibilityHint("Rename category")
            }
        }
        .alert("Rename Category", isPresented: $showQuickRenameAlert) {
            TextField("Category name", text: $renameInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
                .disabled(renameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || renameInput.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(category) == .orderedSame)
        } message: {
            Text("Moves all \(entries.count) receipt\(entries.count == 1 ? "" : "s") in \(category) to the new name. A full backup is made first.")
        }
        .alert("Rebuild \(category)'s log?", isPresented: $showRebuildConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Rebuild", role: .destructive) { rebuild() }
        } message: {
            Text("This replaces \(category)'s CSV file with a fresh one matching the Receipts screen. Comments on existing rows will be lost.")
        }
        .alert("CSV not found", isPresented: $missingCSVAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No log file yet for \(category) — submit a receipt (or rebuild the log) first.")
        }
        .alert("Merge \(category) into \(mergeDestination ?? "")?", isPresented: $showMergeConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Back Up, Then Merge", role: .destructive) {
                if let mergeDestination { merge(into: mergeDestination) }
            }
        } message: {
            Text("A full backup will be made first. Then all \(entries.count) receipt\(entries.count == 1 ? "" : "s") in \(category) will move into \(mergeDestination ?? ""), and \(category) will be removed from your category list. This can only be undone by restoring that backup.")
        }
        .alert("Rename \(category)?", isPresented: $showRenameConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Back Up, Then Rename", role: .destructive) { rename() }
        } message: {
            Text("A full backup will be made first. Then all \(entries.count) receipt\(entries.count == 1 ? "" : "s") in \(category) will move to \(renameInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()). This can only be undone by restoring that backup.")
        }
    }

    private var otherCategories: [String] {
        categoryStore.categories.filter { $0 != category }
    }

    private func merge(into destination: String) {
        mergeMessage = nil
        mergeError = nil
        isMerging = true
        Task {
            do {
                let summary = try CategoryMergeService.merge(from: category, into: destination)
                await MainActor.run {
                    isMerging = false
                    duplicateGroups = summary.duplicateGroups
                    var message = "Backed up to Files → On My iPhone → Receipts4Tax → Backups → \(summary.backupFilename). Moved \(summary.receiptsMoved) receipt\(summary.receiptsMoved == 1 ? "" : "s") into \(destination)."
                    if !summary.duplicateGroups.isEmpty {
                        message += " Found \(summary.duplicateGroups.count) possible duplicate\(summary.duplicateGroups.count == 1 ? "" : "s") — see below."
                    }
                    mergeMessage = message
                    // `entries` (this category) just emptied out and
                    // `destination`'s grew — refresh so this screen and any
                    // other observer (the category list underneath, Receipts
                    // if visible) stop showing pre-merge counts.
                    reloadHistory()
                    NotificationCenter.default.post(name: .receiptDropDidUpdateHistory, object: nil)
                }
            } catch {
                await MainActor.run {
                    isMerging = false
                    mergeError = "Backup failed, so nothing was merged: \(error.localizedDescription)"
                }
            }
        }
    }

    /// On success, pops back to the category list rather than staying on
    /// this screen under a stale title — `category` is a `let` set once at
    /// init, so this view has no way to reflect the new name in place, and
    /// the category no longer exists under the old one once the rename
    /// completes.
    private func rename() {
        renameError = nil
        isRenaming = true
        let target = renameInput
        Task {
            do {
                _ = try CategoryRenameService.rename(category, to: target)
                await MainActor.run {
                    // Posted before `dismiss()` so the category list this
                    // pops back to (its cache still keyed to the old name)
                    // reloads and picks up the new one under the new label.
                    NotificationCenter.default.post(name: .receiptDropDidUpdateHistory, object: nil)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isRenaming = false
                    renameError = error.localizedDescription
                }
            }
        }
    }

    private func rebuild() {
        let categoryEntries = entries
        do {
            try LocalReceiptStore.rebuildLog(category: category, entries: categoryEntries)
            rebuildMessage = "Rebuilt \(category)'s log (\(categoryEntries.count) row\(categoryEntries.count == 1 ? "" : "s"))."
        } catch {
            rebuildMessage = "Couldn't rebuild: \(error.localizedDescription)"
        }
    }

    private func openCSV() {
        guard let fileURL = LocalReceiptStore.documentsLogFileURL(category: category),
              FileManager.default.fileExists(atPath: fileURL.path),
              let filesURL = URL(string: fileURL.absoluteString
                  .replacingOccurrences(of: "file://", with: "shareddocuments://")) else {
            missingCSVAlert = true
            return
        }
        UIApplication.shared.open(filesURL)
    }

    /// Deep-links into the Files app at this category's own folder — where
    /// every receipt file (primary and extras) actually lives, since extras
    /// aren't listed in the CSV and have no other way to be browsed from
    /// outside the app.
    private func openCategoryFolder() {
        guard let folderURL = LocalReceiptStore.documentsCategoryFolderURL(category: category),
              FileManager.default.fileExists(atPath: folderURL.path),
              let filesURL = URL(string: folderURL.absoluteString
                  .replacingOccurrences(of: "file://", with: "shareddocuments://")) else {
            missingCSVAlert = true
            return
        }
        UIApplication.shared.open(filesURL)
    }

    /// Presents the system "Open In" menu (via UIDocumentInteractionController)
    /// so the user can hand the CSV to Numbers for editing — Numbers imports
    /// its own copy, matching the "Copy to Numbers" behavior the user already
    /// hit organically when sharing the file manually.
    private func editInNumbers() {
        guard let fileURL = LocalReceiptStore.documentsLogFileURL(category: category),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            missingCSVAlert = true
            return
        }
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first?.rootViewController else { return }
        DocumentInteractionPresenter.shared.present(fileURL: fileURL, from: topmostViewController(from: root))
    }

    /// Walks the presented-view-controller chain to find whichever screen is
    /// actually on top — this view lives inside a modal sheet (Categories),
    /// so presenting from the window's root (covered by that sheet) silently
    /// no-ops instead of showing the Open In menu.
    private func topmostViewController(from viewController: UIViewController) -> UIViewController {
        if let presented = viewController.presentedViewController {
            return topmostViewController(from: presented)
        }
        return viewController
    }
}

/// Thin retained wrapper around `UIDocumentInteractionController` — it isn't
/// retained by whoever presents it, so a dropped reference dismisses the menu
/// before the user can tap anything. Held as a singleton for the app's
/// lifetime, which is fine since only one "Open In" menu is ever shown at once.
private final class DocumentInteractionPresenter: NSObject, UIDocumentInteractionControllerDelegate {
    static let shared = DocumentInteractionPresenter()
    private var controller: UIDocumentInteractionController?

    func present(fileURL: URL, from viewController: UIViewController) {
        let controller = UIDocumentInteractionController(url: fileURL)
        controller.delegate = self
        // Declared explicitly (rather than left to infer from ".csv") so iOS
        // reliably matches it against Numbers' declared imported types —
        // without this, some iOS versions fall back to the generic "Save to
        // Files" flow instead of listing compatible apps like Numbers.
        controller.uti = "public.comma-separated-values-text"
        self.controller = controller
        controller.presentOpenInMenu(from: viewController.view.bounds, in: viewController.view, animated: true)
    }
}
