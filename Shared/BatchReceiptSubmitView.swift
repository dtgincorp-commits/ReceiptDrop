import SwiftUI

/// Submits several photos picked at once from the library. One category
/// applies to the whole batch (typical case: a stack of receipts from the
/// same trip/vendor visit); each photo is still run through
/// `SubmissionPipeline` independently — same success/duplicate/failure
/// handling as a single submission, just looped, so a bad photo in the
/// middle of a batch doesn't block the rest.
struct BatchReceiptSubmitView: View {
    let attachments: [SharedAttachment]
    let onCancel: () -> Void
    let onComplete: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var selectedCategory: String = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case confirmed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Text("\(attachments.count) photos selected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                Section("Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categoryStore.categories, id: \.self) { Text($0) }
                    }
                    .adaptiveCategoryPickerStyle(count: categoryStore.categories.count)
                    .disabled(phase != .idle)
                }

                Section {
                    content
                }
            }
            .navigationTitle("Receipts4Tax")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(phase != .idle)
                }
            }
        }
        .onAppear {
            if selectedCategory.isEmpty {
                selectedCategory = categoryStore.categories.first ?? ""
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            Button {
                submitAll()
            } label: {
                HStack { Spacer(); Text("Submit All").bold(); Spacer() }
            }
            .disabled(selectedCategory.isEmpty)
        case .confirmed:
            HStack {
                Spacer()
                Label("\(attachments.count) receipts submitted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
            }
        }
    }

    /// Kicks off the batch on a detached task (survives this view being
    /// dismissed) and shows a brief confirmation before closing — no "N of M"
    /// progress screen. Any receipt that fails or needs review still surfaces
    /// afterward via the existing needs-review banner / Retry Queue tab.
    private func submitAll() {
        BatchSubmissionRunner.submit(attachments: attachments, category: selectedCategory)
        phase = .confirmed
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            onComplete()
        }
    }
}
