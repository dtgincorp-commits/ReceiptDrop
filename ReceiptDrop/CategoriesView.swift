import SwiftUI
import UIKit

/// One home for everything category-related: the editable category list
/// (moved out of Settings) and per-category maintenance. Reached from
/// Settings ("Categories ›") and from the Receipts screen's sort menu
/// ("Manage Categories…").
struct CategoriesView: View {
    /// True when reached via "Add Category" (rather than "Manage
    /// Categories…") — the new-category field gets keyboard focus
    /// immediately so the user can start typing without an extra tap.
    var focusNewCategoryOnAppear: Bool = false

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var newCategory = ""
    @FocusState private var newCategoryFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                ForEach(categoryStore.categories, id: \.self) { category in
                    NavigationLink {
                        CategoryDetailView(category: category)
                    } label: {
                        HStack {
                            Text(category)
                            Spacer()
                            Text("\(receiptCount(for: category))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { categoryStore.remove(at: $0) }

                HStack {
                    TextField("New category", text: $newCategory)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($newCategoryFieldFocused)
                        .onSubmit {
                            categoryStore.add(newCategory)
                            newCategory = ""
                        }
                    Button {
                        categoryStore.add(newCategory)
                        newCategory = ""
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Each category gets its own folder and CSV log under Files > On My iPhone > Receipt Drop. Swipe left to delete a category; tap one for its receipt count and maintenance actions.")
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if focusNewCategoryOnAppear {
                newCategoryFieldFocused = true
            }
        }
    }

    private func receiptCount(for category: String) -> Int {
        SubmissionStore.loadHistory().filter { $0.category == category }.count
    }
}

/// Per-category detail: receipt count, a jump to the CSV in the Files app,
/// and the rebuild-log maintenance action.
struct CategoryDetailView: View {
    let category: String

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var descriptionInput: String
    @State private var showRebuildConfirm = false
    @State private var rebuildMessage: String?
    @State private var missingCSVAlert = false

    @State private var mergeDestination: String?
    @State private var showMergeConfirm = false
    @State private var isMerging = false
    @State private var mergeMessage: String?
    @State private var mergeError: String?
    @State private var duplicatePairs: [DuplicateDetectionService.Pair] = []

    init(category: String) {
        self.category = category
        _descriptionInput = State(initialValue: CategoryStore.shared.description(for: category))
    }

    private var entries: [HistoryEntry] {
        SubmissionStore.loadHistory().filter { $0.category == category }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Receipts")
                    Spacer()
                    Text("\(entries.count)").foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("e.g. Expenses for my IT company", text: $descriptionInput, axis: .vertical)
                    .lineLimit(2...4)
                    .onSubmit { categoryStore.setDescription(descriptionInput, for: category) }
            } header: {
                Text("Category Description for \(category) (Better AI decisioning)")
            } footer: {
                Text("Optional, but helps the AI write better Comments and flag receipts that look like they don't belong here. Saved automatically as you leave the field.")
            }
            .onChange(of: descriptionInput) { newValue in
                categoryStore.setDescription(newValue, for: category)
            }

            Section {
                Button {
                    openCSV()
                } label: {
                    Label("View CSV in the Files app", systemImage: "folder")
                }
                Button {
                    editInNumbers()
                } label: {
                    Label("Edit CSV in Numbers App", systemImage: "square.and.pencil")
                }
                Button {
                    openCategoryFolder()
                } label: {
                    Label("Open \(category) folder in Files", systemImage: "folder.fill")
                }
            } footer: {
                Text("\"Edit CSV in Numbers\" hands \(category)_log.csv to the Numbers app via the system Open In menu — Numbers keeps its own copy, so edits there don't change the file the app writes to. \"Open \(category) folder\" shows every file in this category, including receipt photos and any extra attachments not listed in the CSV.")
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
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Wipes and regenerates \(category)'s CSV log strictly from what's shown on the Receipts screen — fixes stray or duplicate rows. Comments on existing rows come back blank (they're only stored in the CSV); new receipts keep their Comments as usual. Other categories aren't affected.")
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
                            if isMerging { ProgressView() } else { Text("Merge \(category) In…") }
                            Spacer()
                        }
                    }
                    .disabled(isMerging || mergeDestination == nil)
                    if let mergeMessage {
                        Label(mergeMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    if !duplicatePairs.isEmpty {
                        NavigationLink {
                            DuplicateReviewView(pairs: $duplicatePairs)
                        } label: {
                            Label("Review \(duplicatePairs.count) Possible Duplicate\(duplicatePairs.count == 1 ? "" : "s")",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let mergeError {
                        Text(mergeError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Merge")
                } footer: {
                    Text("Moves every receipt (photos and Comments included) from \(category) into the category you pick, then removes \(category) from the list. A full backup is made first. Useful for cleaning up an accidental duplicate — e.g. two categories that differ only in capitalization.")
                }
            }
        }
        .navigationTitle(category)
        .navigationBarTitleDisplayMode(.inline)
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
                    duplicatePairs = summary.duplicatePairs
                    var message = "Backed up to Files → On My iPhone → Receipt Drop → Backups → \(summary.backupFilename). Moved \(summary.receiptsMoved) receipt\(summary.receiptsMoved == 1 ? "" : "s") into \(destination)."
                    if !summary.duplicatePairs.isEmpty {
                        message += " Found \(summary.duplicatePairs.count) possible duplicate\(summary.duplicatePairs.count == 1 ? "" : "s") — see below."
                    }
                    mergeMessage = message
                }
            } catch {
                await MainActor.run {
                    isMerging = false
                    mergeError = "Backup failed, so nothing was merged: \(error.localizedDescription)"
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
