import SwiftUI

/// Shown after the Live Text scanner recognizes text: pick a category, review
/// the recognized text, and submit — Claude reads the text directly
/// (`SubmissionPipeline.runTextOnly`), no photo is saved.
struct ScannedTextSubmitView: View {
    let recognizedText: String
    let onCancel: () -> Void
    let onComplete: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var selectedCategory: String = ""
    @State private var submitState: SubmitState = .idle
    @State private var statusText: String = ""
    @State private var message: String?

    @State private var pendingDateEntry: HistoryEntry?
    @State private var pickedDate = Date()

    /// Suffix common to both review-reason variants `ExtractedReceipt.build`
    /// writes when the date couldn't be parsed (see `ReceiptSubmitView`'s
    /// matching constant for the full explanation) — matching it lets us
    /// prompt for a date instead of keeping today's.
    private static let unreadableDateReasonSuffix = "defaulted to today"

    private enum SubmitState: Equatable {
        case idle
        case running
        case success
        case needsDate
    }

    private var controlsDisabled: Bool {
        if case .idle = submitState { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recognized Text") {
                    Text(recognizedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }

                Section("Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categoryStore.categories, id: \.self) { Text($0) }
                    }
                    .adaptiveCategoryPickerStyle(count: categoryStore.categories.count)
                    .disabled(controlsDisabled)
                }

                Section {
                    submitContent
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Scanned Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(controlsDisabled)
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
    private var submitContent: some View {
        switch submitState {
        case .idle:
            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    Text("Submit").bold()
                    Spacer()
                }
            }
            .disabled(selectedCategory.isEmpty)
        case .running:
            HStack {
                Spacer()
                ProgressView()
                Text(statusText).foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
        case .success:
            HStack {
                Spacer()
                Label("Submitted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
            }
        case .needsDate:
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn't read the date on this receipt", systemImage: "calendar.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Please set the correct date — it hasn't been guessed. Everything else was saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("Receipt Date", selection: $pickedDate, displayedComponents: .date)
                Button {
                    saveDateAndFinish()
                } label: {
                    HStack { Spacer(); Text("Save Date").bold(); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                Button("Skip for now — it stays flagged for review") {
                    onComplete()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Applies the user-picked date to the just-saved entry, then finishes.
    private func saveDateAndFinish() {
        guard let entry = pendingDateEntry else { onComplete(); return }
        // Comments live in the CSV, not on HistoryEntry — read them back so the
        // date-only update doesn't wipe them.
        let existingComments = LocalReceiptStore.comments(
            category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
            amount: entry.amount, receiptFilename: entry.receiptLink)
        _ = try? SubmissionPipeline.updateEntry(
            old: entry,
            newCategory: entry.category, newVendor: entry.vendor,
            newWorkDate: LocalReceiptStore.dateString(pickedDate),
            newAmount: entry.amount, newComments: existingComments,
            newVendorType: entry.vendorType)
        onComplete()
    }

    private func submit() {
        guard !selectedCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Please pick a category before saving."
            return
        }

        message = nil
        submitState = .running
        statusText = SubmissionPipeline.Stage.reading.statusText

        Task {
            do {
                let entry = try await SubmissionPipeline().runTextOnly(
                    ocrText: recognizedText, category: selectedCategory
                ) { stage in
                    statusText = stage.statusText
                }
                // Ask for the date rather than keeping today's if it couldn't
                // be read — consistent with the photo/PDF submit flow.
                if entry.verificationStatus == .needsReview,
                   entry.reviewReason.hasSuffix(Self.unreadableDateReasonSuffix) {
                    pendingDateEntry = entry
                    pickedDate = Date()
                    submitState = .needsDate
                } else {
                    submitState = .success
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    onComplete()
                }
            } catch let duplicate as SubmissionError {
                message = duplicate.localizedDescription
                submitState = .success
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                onComplete()
            } catch {
                message = error.localizedDescription
                submitState = .idle
            }
        }
    }
}
