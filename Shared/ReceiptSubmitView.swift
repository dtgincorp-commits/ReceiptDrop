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

    /// Set when the user picks "Continue Without AI" out of the
    /// `.offlineChoice` prompt below — an AI provider *is* configured, it
    /// just couldn't be reached, and the user has opted into the same
    /// deterministic OCR path as the no-AI case for this one submission.
    /// Every place that gates on `ExtractionSettings.aiConfigured` to decide
    /// "show manual fields / require them / submit manually" also has to
    /// check this, since aiConfigured itself must stay unchanged (other call
    /// sites depend on its original meaning of "is a provider set up at
    /// all").
    @State private var proceedWithoutAI = false

    /// True while on-device OCR (`prefillManualFieldsFromOCR`) is running,
    /// so the Details section can show a lightweight spinner instead of
    /// silently populating fields out from under someone who's already
    /// started typing.
    @State private var isPrefillingManualFields = false

    /// The just-saved entry whose date couldn't be read — held so the
    /// `.needsDate` nudge can update it once the user sets a date.
    @State private var pendingDateEntry: HistoryEntry?
    @State private var pickedDate = Date()

    /// The already-normalized bytes/kind/category from the `submit()` call
    /// that hit a connectivity-class failure, held so the `.offlineChoice`
    /// prompt's two actions ("Continue Without AI" / "Save for Later") can
    /// act on the exact same submission without re-deriving it (and without
    /// re-running the JPEG re-encode).
    private struct PendingSubmission {
        let data: Data
        let kind: ReceiptKind
        let category: String
        /// Why AI extraction couldn't run, carried so "Save for Later" files
        /// the queue entry under the actual reason ("Offline mode is on, so
        /// Claude ... is blocked") rather than a generic stand-in. The Retry
        /// Queue's detail screen shows this under "Why it failed", and it is
        /// the only place the user can still find out what to change.
        let reason: String
    }
    @State private var pendingOfflineSubmission: PendingSubmission?

    // Same App Group store + key SettingsView writes, so the symbol shown
    // here always matches whatever the user picked — shared with the share
    // extension since this view is too.
    @AppStorage(AppConstants.DefaultsKeys.appCurrency, store: UserDefaults(suiteName: AppConstants.appGroupID))
    private var appCurrency: AppCurrency = .auto

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
        /// AI extraction failed for a connectivity reason (see
        /// `ExtractionFailureClass`) — the receipt itself is fine, so
        /// instead of silently queuing it for later retry, offer the user
        /// a fallback right now. Carries the human-readable reason (the
        /// underlying error's description) to show inline, plus whether
        /// Apple's on-device model (`ExtractionSettings.appleOnDeviceReady`)
        /// can be offered as a real-AI alternative to the configured
        /// provider — false either because the device/OS can't run it, or
        /// because the configured provider *was* Apple On-Device and just
        /// failed, so offering it again would be pointless.
        case offlineChoice(reason: String, canUseAppleIntelligence: Bool)
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
        let needsManualFields = !ExtractionSettings.aiConfigured || proceedWithoutAI
        return !selectedCategory.isEmpty && (!needsManualFields || manualFieldsValid)
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

                if !ExtractionSettings.aiConfigured || proceedWithoutAI {
                    // Deliberately a visible banner, not just footer text —
                    // a caveat printed under four fields is easy to scroll
                    // past, and the whole point is that nothing here has
                    // been read by an AI, so every value needs a human's
                    // eyes before it becomes a tax record.
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                // Two different situations land here: no
                                // provider is set up at all, or one is
                                // configured but couldn't be reached (the
                                // user chose "Continue Without AI" off the
                                // offline prompt). "No AI connected" would be
                                // false in the second case — the provider
                                // *is* connected in Settings, it just isn't
                                // reachable right now — so pick the accurate
                                // heading for whichever situation this is.
                                Text(proceedWithoutAI
                                     ? "AI unreachable — please check these details"
                                     : "No AI connected — please check these details")
                                    .font(.subheadline.weight(.semibold))
                                Text("Nothing here was read by an AI. On-device text recognition (OCR) filled in what it could find below — it may be wrong, mismatched, or missing, so compare every field against the receipt before saving.")
                                    .font(.caption)
                                    // Red, not secondary grey. Verified against
                                    // a real Home Depot receipt: OCR prefilled
                                    // the slogan "How doers" as the vendor and
                                    // a loyalty year-to-date figure ($1,040.81)
                                    // as the total against a real total of
                                    // $145.17. Values that wrong, sitting in
                                    // filled-in fields, read as answers rather
                                    // than guesses — the warning has to carry
                                    // more weight than the fields it qualifies.
                                    .foregroundStyle(.red)
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
                            Text(appCurrency.symbol)
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
                        HStack {
                            Text("Details")
                            if isPrefillingManualFields {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    } footer: {
                        Text(proceedWithoutAI
                             ? "Continuing without AI for this receipt. Everything below is on-device only."
                             : "Connect an AI in Settings to read receipts automatically instead of entering them by hand.")
                    }
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
                            .foregroundStyle(submitState == .queued ? .red : .secondary)
                    }
                }
            }
            .navigationTitle("Receipts4Tax")
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
        .task {
            await prefillManualFieldsFromOCR()
        }
    }

    /// Runs on-device OCR (Vision — no network, no AI) and prefills the
    /// manual vendor/amount/date fields when no AI provider is configured.
    /// This is what makes the "on-device text recognition" warning above
    /// literally true instead of aspirational — previously these fields
    /// were simply left blank (see the bug this fixes: nothing ever ran
    /// Vision or the detectors for the no-AI path) even though the banner
    /// already claimed something had been read off the receipt.
    ///
    /// Best-effort throughout: any failure — an unreadable image, a PDF
    /// with no renderable first page, Vision finding no text at all — just
    /// leaves the corresponding field empty for the user to type by hand.
    /// This is a convenience prefill, never a requirement to submit, and
    /// must never block or crash the manual-entry path that exists
    /// precisely so people without any AI configured can still save a
    /// receipt.
    private func prefillManualFieldsFromOCR() async {
        guard !ExtractionSettings.aiConfigured || proceedWithoutAI else { return }

        // Vision reads still-image data. For a PDF, render its first page
        // to an image first — reusing the thumbnail helper below rather
        // than `FoundationModelsService.renderPDFPageToPNG`, which is
        // gated to iOS 26 + the FoundationModels framework and so isn't
        // available on every deployment target this view ships to.
        let imageData: Data?
        switch attachment.kind {
        case .image:
            imageData = attachment.data
        case .pdf:
            imageData = pdfThumbnail(attachment.data)?.pngData()
        }
        guard let imageData else { return }

        isPrefillingManualFields = true

        // Prefer layout-aware text over flat OCR. `VisionOCRService.recognizeText`
        // joins Vision's raw text observations with no positional information at
        // all — on a thermal receipt with a wide gap between a label and its
        // number ("TOTAL" ... "$145.17"), Vision frequently returns those as two
        // separate observations, so they land on two separate lines. Every
        // downstream parser that pairs a label with a *trailing* amount on the
        // same line (`BillTotalsParser`, in particular) then sees an empty
        // "TOTAL" line and falls through to "largest number on the receipt" —
        // which picks up loyalty/statement figures that print bigger than the
        // real total. `recognizeRowsViaRawOCR` reconstructs visual rows from
        // bounding boxes first and pairs each label with its trailing amount
        // itself, then `layoutString` renders that back to "LEFT    RIGHT" text,
        // restoring exactly the same-line pairing the flat path loses. It isn't
        // gated behind iOS 26/FoundationModels (unlike `recognizeRows`), so it's
        // usable at this file's iOS 16 deployment target.
        //
        // Falls back to the flat OCR text when the layout path finds nothing
        // (e.g. Vision's document/text request itself fails) so this can only
        // improve on the previous behavior, never regress it.
        var text: String?
        if let rows = try? await VisionLayoutService.recognizeRowsViaRawOCR(in: imageData), !rows.isEmpty {
            text = VisionLayoutService.layoutString(from: rows)
        }
        if text == nil || text?.isEmpty == true {
            text = try? await VisionOCRService.recognizeText(in: imageData)
        }
        isPrefillingManualFields = false

        guard let text, !text.isEmpty else { return }

        // Only fill in fields still at their untouched default — if a fast
        // typist has already started editing before OCR finishes, don't
        // stomp on what they typed.
        if manualAmount.isEmpty, let amount = ManualEntryOCRPrefill.likelyGrandTotal(in: text) {
            manualAmount = amount
        }
        if manualVendor.isEmpty, let vendor = ManualEntryOCRPrefill.likelyVendorLine(in: text) {
            manualVendor = vendor
        }
        if let date = ManualEntryOCRPrefill.likelyReceiptDate(in: text) {
            manualWorkDate = date
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
                    Text(appCurrency.symbol)
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
        case .offlineChoice(let reason, let canUseAppleIntelligence):
            // Follows the same inline-prompt convention as `.needsDate` /
            // `.needsAmount` above rather than a sheet or alert — the user
            // is already looking at this form, and every choice here
            // ("retry with the on-device model" / "fill in fields myself" /
            // "stash it and move on") is naturally expressed as buttons in
            // place, not as a separate screen.
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn't reach AI extraction", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if canUseAppleIntelligence {
                    // Explains *why* this is being offered — the configured
                    // provider needs the network and can't be reached, but
                    // Apple's on-device model never leaves the phone — and
                    // draws the line the user needs to see between this
                    // option and "Continue Without AI" below: this one is
                    // still a real model reading the receipt, just a
                    // different (offline-capable) one.
                    Text("Your configured AI provider needs the internet and can't be reached. Apple's on-device model runs entirely on this iPhone and can read the receipt right now instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        useAppleIntelligence()
                    } label: {
                        HStack { Spacer(); Text("Use Apple Intelligence").bold(); Spacer() }
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Or skip AI entirely and fill in the details yourself — on-device text matching only, not read by any AI, so it's often wrong.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The receipt itself is fine — you can fill in the details yourself using on-device text recognition, or save it to submit with AI later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if canUseAppleIntelligence {
                    Button {
                        continueWithoutAI()
                    } label: {
                        HStack { Spacer(); Text("Continue Without AI").bold(); Spacer() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        continueWithoutAI()
                    } label: {
                        HStack { Spacer(); Text("Continue Without AI").bold(); Spacer() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button {
                    saveOfflineSubmissionForLater()
                } label: {
                    HStack { Spacer(); Text("Save for Later").bold(); Spacer() }
                }
                .buttonStyle(.bordered)
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

    /// "Continue Without AI" out of the `.offlineChoice` prompt — switches
    /// this submission over to the exact same deterministic path the
    /// no-AI case already uses. Re-runs OCR prefill (it no-opped the first
    /// time, at `.task`, because `aiConfigured` was still true then) and
    /// returns `submitState` to `.idle` so the Details fields become
    /// editable and the Submit button reappears.
    private func continueWithoutAI() {
        proceedWithoutAI = true
        pendingOfflineSubmission = nil
        message = nil
        submitState = .idle
        Task {
            await prefillManualFieldsFromOCR()
        }
    }

    /// "Save for Later" out of the `.offlineChoice` prompt — the original
    /// Retry Queue behavior, just deferred until the user picks it instead
    /// of happening automatically.
    private func saveOfflineSubmissionForLater() {
        guard let pending = pendingOfflineSubmission else { submitState = .idle; return }
        SubmissionStore.enqueue(data: pending.data, category: pending.category, kind: pending.kind,
                                error: pending.reason)
        pendingOfflineSubmission = nil
        message = "Saved to the retry queue in the app."
        submitState = .queued
    }

    /// "Use Apple Intelligence" out of the `.offlineChoice` prompt — retries
    /// the same submission through `SubmissionPipeline`, forcing the
    /// on-device extractor for this one call via `forcedProvider` (see
    /// `SubmissionPipeline.run`) instead of touching the user's persisted
    /// `ExtractionSettings.provider`. Deliberately routed through the exact
    /// same success/duplicate/`.needsDate`/`.needsAmount` handling `submit()`
    /// uses below, not a simplified parallel path — a receipt read by the
    /// on-device model can come back needing a date or amount fix just like
    /// one read by the cloud provider would.
    ///
    /// If this attempt *also* fails, don't loop back to offering Apple
    /// Intelligence again — the on-device model just failed on this exact
    /// receipt, so retrying it a second time isn't a real option. Fall
    /// through to `.offlineChoice` with `canUseAppleIntelligence: false`,
    /// which renders as the original Continue Without AI / Save for Later
    /// pair with the new error.
    private func useAppleIntelligence() {
        guard let pending = pendingOfflineSubmission else { submitState = .idle; return }
        message = nil
        submitState = .running
        statusText = SubmissionPipeline.Stage.reading.statusText

        Task {
            do {
                let entry = try await SubmissionPipeline().run(
                    data: pending.data, kind: pending.kind, category: pending.category,
                    forcedProvider: .appleOnDevice) { stage in
                    statusText = stage.statusText
                }
                pendingOfflineSubmission = nil
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
                pendingOfflineSubmission = nil
                message = duplicate.localizedDescription
                submitState = .success
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                onComplete()
            } catch {
                // Don't offer Apple Intelligence again — it just failed on
                // this receipt. Keep the same pending bytes so Continue
                // Without AI / Save for Later can still act on them.
                pendingOfflineSubmission = PendingSubmission(
                    data: pending.data, kind: pending.kind, category: pending.category,
                    reason: error.localizedDescription)
                submitState = .offlineChoice(reason: error.localizedDescription, canUseAppleIntelligence: false)
            }
        }
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

        guard ExtractionSettings.aiConfigured && !proceedWithoutAI else {
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
                if ExtractionFailureClass.classify(error) == .connectivity {
                    // AI just couldn't be reached — the receipt itself is
                    // fine. Don't queue it silently; offer a fallback right
                    // now instead of forcing a trip to Settings. Apple
                    // Intelligence is only worth offering if it's actually
                    // usable on this device *and* it isn't the same provider
                    // that just failed (offering to retry the thing that
                    // just failed, unchanged, would be a dead end).
                    pendingOfflineSubmission = PendingSubmission(
                        data: data, kind: kind, category: category,
                        reason: error.localizedDescription)
                    let canUseAppleIntelligence = ExtractionSettings.provider != .appleOnDevice
                        && ExtractionSettings.appleOnDeviceReady
                    submitState = .offlineChoice(reason: error.localizedDescription,
                                                  canUseAppleIntelligence: canUseAppleIntelligence)
                } else {
                    // Park the bytes + a queue entry so the main app can retry.
                    SubmissionStore.enqueue(data: data, category: category, kind: kind,
                                            error: error.localizedDescription)
                    message = "Couldn't submit — saved to the retry queue in the app. \(error.localizedDescription)"
                    submitState = .queued
                }
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
