import SwiftUI
import UIKit

/// One home for everything category-related: the editable category list
/// (moved out of Settings) and per-category maintenance. Reached from
/// Settings ("Categories ›") and from the Receipts screen's sort menu
/// ("Manage Categories…").
struct CategoriesView: View {
    @StateObject private var categoryStore = CategoryStore.shared
    @State private var newCategory = ""

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
    }

    private func receiptCount(for category: String) -> Int {
        SubmissionStore.loadHistory().filter { $0.category == category }.count
    }
}

/// Per-category detail: receipt count, a jump to the CSV in the Files app,
/// and the rebuild-log maintenance action.
struct CategoryDetailView: View {
    let category: String

    @State private var showRebuildConfirm = false
    @State private var rebuildMessage: String?
    @State private var missingCSVAlert = false

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
                Button {
                    openCSV()
                } label: {
                    Label("Open CSV in Files", systemImage: "folder")
                }
            } footer: {
                Text("Opens \(category)_log.csv in the Files app.")
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
}
