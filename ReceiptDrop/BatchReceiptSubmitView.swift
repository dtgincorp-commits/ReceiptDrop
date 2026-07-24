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
    @State private var currentIndex = 0
    @State private var submitted = 0
    @State private var duplicates = 0
    @State private var queued = 0

    private enum Phase: Equatable {
        case idle
        case running
        case done
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
                    .pickerStyle(.segmented)
                    .disabled(phase != .idle)
                }

                Section {
                    content
                }
            }
            .navigationTitle("ReceiptDrop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(phase == .running)
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
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(currentIndex), total: Double(attachments.count))
                Text("Submitting \(currentIndex + 1) of \(attachments.count)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: 8) {
                Label("\(submitted) submitted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if duplicates > 0 {
                    Label("\(duplicates) already recorded, skipped", systemImage: "doc.on.doc")
                        .foregroundStyle(.secondary)
                }
                if queued > 0 {
                    Label("\(queued) couldn't submit — saved to the retry queue", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button {
                    onComplete()
                } label: {
                    HStack { Spacer(); Text("Done").bold(); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
    }

    private func submitAll() {
        let category = selectedCategory
        phase = .running
        currentIndex = 0

        Task {
            for (index, attachment) in attachments.enumerated() {
                currentIndex = index
                let kind: ReceiptKind = attachment.kind == .image ? .image : .pdf
                let data: Data
                if attachment.kind == .image, let jpeg = UIImage(data: attachment.data)?.jpegData(compressionQuality: 0.85) {
                    data = jpeg
                } else {
                    data = attachment.data
                }

                do {
                    _ = try await SubmissionPipeline().run(data: data, kind: kind, category: category) { _ in }
                    submitted += 1
                } catch is SubmissionError {
                    duplicates += 1
                } catch {
                    SubmissionStore.enqueue(data: data, category: category, kind: kind,
                                            error: error.localizedDescription)
                    queued += 1
                }
            }
            LocalReceiptStore.drainSpoolIntoDocuments()
            phase = .done
        }
    }
}
