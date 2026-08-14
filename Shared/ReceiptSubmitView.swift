import PDFKit
import SwiftUI

/// An attachment ready to submit, normalized to raw data. Built by the share
/// extension (from an NSItemProvider) or by the main app (from the camera or
/// photo picker).
struct SharedAttachment {
    enum Kind { case image, pdf }
    let kind: Kind
    let data: Data
    let thumbnail: UIImage?
}

/// The category picker + submit/progress UI, shared by the share extension
/// and the main app's in-app "New Receipt" flow so there's one copy of the
/// Claude/Drive/Sheets submission UI logic.
struct ReceiptSubmitView: View {
    let attachment: SharedAttachment
    let onCancel: () -> Void
    let onComplete: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var selectedCategory: String = ""
    @State private var submitState: SubmitState = .idle
    @State private var statusText: String = ""
    @State private var message: String?

    /// Shown instead of running AI extraction when no provider is configured
    /// (see `ExtractionSettings.aiConfigured`) — the photo is still saved,
    /// just with hand-typed fields instead of an automatic read.
    @State private var manualVendor: String = ""
    @State private var manualAmount: String = ""
    @State private var manualWorkDate: Date = Date()
    @State private var manualComments: String = ""

    /// The just-saved entry whose date couldn't be read — held so the
    /// `.needsDate` nudge can update it once the user sets a date.
    @State private var pendingDateEntry: HistoryEntry?
    @State private var pickedDate = Date()

    /// The just-saved entry whose amount didn't match anything printed on
    /// the receipt — held so the `.needsAmount` nudge can update it.
    @State private var pendingAmountEntry: HistoryEntry?
    @State private var pickedAmount: String = ""

    /// Suffix common to both review-reason variants `ExtractedReceipt.build`
    /// writes when the date couldn't be parsed — "Date unreadable, defaulted
    /// to today" (nothing was returned) and "Couldn't parse date: \"...\" —
    /// defaulted to today" (something was returned but didn't match a known
    /// format). Matching the suffix (not the whole string) catches both, so
    /// we can prompt for a date instead of silently keeping today's — matters
    /// for library images, where retaking a photo isn't an option.
    private static let unreadableDateReasonSuffix = "defaulted to today"

    /// Marker substring of the review reason `ExtractedReceipt.build` writes
    /// when the reported amount doesn't appear anywhere on the receipt (see
    /// `ReceiptAmountDetector`) — matched the same way as the date suffix
    /// above, so this stays correct if the exact wording ever changes.
    private static let amountNotPrintedMarker = "isn't printed on this receipt"

    /// Drives the Submit section's UI while the pipeline runs.
    private enum SubmitState: Equatable {
        case idle
        case running
        case success
        case queued
        case needsDate
        case needsAmount
    }

    private var controlsDisabled: Bool {
        if case .idle = submitState { return false }
        return true
    }

    private var manualFieldsValid: Bool {
        !manualVendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Double(manualAmount.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private var canSubmit: Bool {
        !selectedCategory.isEmpty && (ExtractionSettings.aiConfigured || manualFieldsValid)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        if let thumb = attachment.thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Label("PDF attached", systemImage: "doc.fill")
                        }
                        Spacer()
                    }
                }

                if !ExtractionSettings.aiConfigured {
                    // Deliberately a visible banner, not just footer text —
                    // a caveat printed under four fields is easy to scroll
                    // past, and the whole point is that nothing here has
                    // been read by an AI, so every value needs a human's
                    // eyes before it becomes a tax record.
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No AI connected — please check these details")
                                    .font(.subheadline.weight(.semibold))
                                Text("Nothing here was read by an AI. Anything filled in below was found by simple on-device text matching and may be wrong or missing — compare it against the receipt before saving.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        TextField("Merchant / Vendor", text: $manualVendor)
                            .disabled(controlsDisabled)
                        HStack {
                            Text("$")
                            TextField("Amount", text: $manualAmount)
                                .keyboardType(.decimalPad)
                                .disabled(controlsDisabled)
                        }
                        DatePicker("Work Date", selection: $manualWorkDate, displayedComponents: .date)
                            .disabled(controlsDisabled)
                        TextField("Comments", text: $manualComments, axis: .vertical)
                            .lineLimit(2...4)
                            .disabled(controlsDisabled)
                    } header: {
                        Text("Details")
                    } footer: {
                        Text("Connect an AI in Settings to read receipts automatically instead of entering them by hand.")
                    }
                }

                Section("Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categoryStore.categories, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(controlsDisabled)
                }

                Section {
                    submitContent
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(submitState == .queued ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("ReceiptDrop")
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

    // MARK: - Submit

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
            .disabled(!canSubmit)
        case .running:
            HStack {
                Spacer()
                ProgressView()
                Text(statusText).foregroundStyle(.secondary)
                Spacer()
            }
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
        case .needsAmount:
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn't read the amount on this receipt", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("The amount saved doesn't appear on the receipt. Check it below, or take a clearer photo — Scan Receipt usually reads far better than Take Photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("$")
                    TextField("Amount", text: $pickedAmount)
                        .keyboardType(.decimalPad)
                }
                Button {
                    saveAmountAndFinish()
                } label: {
                    HStack { Spacer(); Text("Save Amount").bold(); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(Double(pickedAmount.trimmingCharacters(in: .whitespaces)) == nil)
                Button("Skip for now — it stays flagged for review") {
                    onComplete()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .queued:
            Button {
                onComplete()
            } label: {
                HStack {
                    Spacer()
                    Text("Done").bold()
                    Spacer()
                }
            }
        }
    }

    /// Applies the user-picked date to the just-saved entry (updates the CSV
    /// log + history in place), then finishes. If the in-place update fails,
    /// the entry is already saved and flagged for review, so the app's Edit
    /// screen can still correct it — we don't block the user here.
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

    /// Applies the user-corrected amount to the just-saved entry, same
    /// pattern as `saveDateAndFinish()`.
    private func saveAmountAndFinish() {
        guard let entry = pendingAmountEntry else { onComplete(); return }
        let existingComments = LocalReceiptStore.comments(
            category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
            amount: entry.amount, receiptFilename: entry.receiptLink)
        let normalizedAmount = Double(pickedAmount.trimmingCharacters(in: .whitespaces))
            .map { String($0) } ?? entry.amount
        _ = try? SubmissionPipeline.updateEntry(
            old: entry,
            newCategory: entry.category, newVendor: entry.vendor,
            newWorkDate: entry.workDate,
            newAmount: normalizedAmount, newComments: existingComments,
            newVendorType: entry.vendorType)
        onComplete()
    }

    private func submit() {
        let kind: ReceiptKind = attachment.kind == .image ? .image : .pdf
        // Re-encode images to JPEG so the bytes, Claude media_type, and Drive
        // MIME type all agree (the source image could be PNG/HEIC).
        let data: Data
        if attachment.kind == .image, let jpeg = UIImage(data: attachment.data)?.jpegData(compressionQuality: 0.85) {
            data = jpeg
        } else {
            data = attachment.data
        }
        let category = selectedCategory

        message = nil
        submitState = .running

        guard ExtractionSettings.aiConfigured else {
            submitManually(data: data, kind: kind, category: category)
            return
        }

        statusText = SubmissionPipeline.Stage.reading.statusText

        Task {
            do {
                let entry = try await SubmissionPipeline().run(data: data, kind: kind, category: category) { stage in
                    statusText = stage.statusText
                }
                // If the date couldn't be read, don't quietly keep today's date
                // — stop and ask the user to set it (works for library images
                // too, where retaking a photo isn't possible).
                if entry.verificationStatus == .needsReview,
                   entry.reviewReason.hasSuffix(Self.unreadableDateReasonSuffix) {
                    pendingDateEntry = entry
                    pickedDate = Date()
                    submitState = .needsDate
                } else if entry.verificationStatus == .needsReview,
                          entry.reviewReason.contains(Self.amountNotPrintedMarker) {
                    pendingAmountEntry = entry
                    pickedAmount = entry.amount
                    submitState = .needsAmount
                } else {
                    submitState = .success
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    onComplete()
                }
            } catch let duplicate as SubmissionError {
                // Already recorded — nothing to save, nothing to retry.
                message = duplicate.localizedDescription
                submitState = .success
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                onComplete()
            } catch {
                // Park the bytes + a queue entry so the main app can retry.
                SubmissionStore.enqueue(data: data, category: category, kind: kind,
                                        error: error.localizedDescription)
                message = "Couldn't submit — saved to the retry queue in the app. \(error.localizedDescription)"
                submitState = .queued
            }
        }
    }

    /// No AI provider configured — saves the photo/PDF with the hand-typed
    /// fields instead of running extraction. Not routed through the retry
    /// queue on failure: retries there always re-run AI extraction
    /// (`SubmissionPipeline.run`), which would ignore what the user typed —
    /// simpler to just let them hit Submit again.
    private func submitManually(data: Data, kind: ReceiptKind, category: String) {
        statusText = SubmissionPipeline.Stage.saving.statusText
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        let normalizedAmount = Double(manualAmount.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { String($0) } ?? manualAmount
        let vendor = manualVendor.trimmingCharacters(in: .whitespacesAndNewlines)
        let workDate = formatter.string(from: manualWorkDate)
        let comments = manualComments.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                _ = try SubmissionPipeline.saveWithoutExtraction(
                    data: data, kind: kind, category: category,
                    vendor: vendor, workDate: workDate, amount: normalizedAmount, comments: comments)
                submitState = .success
                try? await Task.sleep(nanoseconds: 800_000_000)
                onComplete()
            } catch let duplicate as SubmissionError {
                message = duplicate.localizedDescription
                submitState = .success
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                onComplete()
            } catch {
                message = "Couldn't save: \(error.localizedDescription)"
                submitState = .idle
            }
        }
    }
}

/// Renders a PDF's first page as a thumbnail image, used by both the extension's
/// NSItemProvider loading and any future in-app PDF source.
func pdfThumbnail(_ data: Data) -> UIImage? {
    guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
    return page.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox)
}
