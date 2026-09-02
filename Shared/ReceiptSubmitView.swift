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

    /// Drives the full-screen zoomable viewer, reached by tapping the
    /// thumbnail below — see `zoomablePhotoData`. This is the screen where
    /// verifying every field against the receipt matters most (it's the
    /// only path with no AI to double-check the OCR prefill), so the same
    /// pinch-zoom viewer `QueueEntryDetailView` uses in ContentView.swift is
    /// reused here rather than leaving the user stuck with a ~220pt-tall
    /// static thumbnail too small to read a total off.
    @State private var showPhotoViewer = false

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
    ///
    /// Seeded from `startInManualMode` at init (see below) for the Retry
    /// Queue's "Continue Without AI" entry point — that caller already
    /// knows AI extraction just failed for this exact bytes/category, so
    /// this view should open straight into the manual-entry fields instead
    /// of attempting the AI pipeline again first.
    @State private var proceedWithoutAI = false

    /// True only for the Retry Queue's "Continue Without AI" flow, which
    /// constructs this view already knowing extraction failed — see the
    /// `init` below and `proceedWithoutAI` above.
    private let startInManualMode: Bool

    init(attachment: SharedAttachment, onCancel: @escaping () -> Void, onComplete: @escaping () -> Void,
         startInManualMode: Bool = false) {
        self.attachment = attachment
        self.onCancel = onCancel
        self.onComplete = onComplete
        self.startInManualMode = startInManualMode
        _proceedWithoutAI = State(initialValue: startInManualMode)
    }

    /// True while on-device OCR (`prefillManualFieldsFromOCR`) is running,
    /// so the Details section can show a lightweight spinner instead of
    /// silently populating fields out from under someone who's already
    /// started typing.
    @State private var isPrefillingManualFields = false

    /// What the deterministic on-device date read concluded, for the
    /// manual-entry (no-AI / "Continue Without AI") path — see
    /// `ManualEntryOCRPrefill.resolveDate`. `nil` until OCR prefill has run,
    /// which `needsDateConfirmation` treats the same as "couldn't read it":
    /// either way nothing has read a date off this receipt yet.
    @State private var dateResolution: ManualEntryOCRPrefill.DateResolution?

    /// True once the user has moved the Receipt Date picker themselves. A
    /// date a human chose is never a silent fallback, so it's never
    /// second-guessed by the confirmation prompt below — the prompt exists
    /// only for dates nobody looked at.
    @State private var userEditedDate = false

    /// The user asked, before submitting, for this receipt to land in the
    /// Receipts list already flagged — "file it now, I'll look at it later".
    ///
    /// Deliberately a pre-submit intent rather than a post-save action: the
    /// moment a receipt is worth setting aside is the moment it's being
    /// dropped in (a bill with no total on it, a photo taken in a hurry, a
    /// stack being cleared in one sitting), and the share extension has no
    /// list to go back to afterwards. The Receipts list gets its own
    /// "Review Later" swipe action for entries already saved.
    @State private var setAsideForReview = false

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

    /// The normalized bytes/kind/category of a manual-entry save paused on
    /// the `.confirmDate` prompt, held so confirming (or correcting) the
    /// date completes that exact save without re-deriving it — same pattern
    /// as `PendingSubmission` above.
    private struct PendingManualSave {
        let data: Data
        let kind: ReceiptKind
        let category: String
    }
    @State private var pendingManualSave: PendingManualSave?

    /// Held only while `.duplicate` is on screen — everything `saveDuplicateAnyway()`
    /// needs to redo the exact save that was just blocked, this time with
    /// `allowDuplicate: true`. A closure would be a simpler way to carry
    /// "what to retry", but `SubmitState` (below) has to stay a plain,
    /// inspectable enum the same way `.offlineChoice` already is — so the
    /// retry's data lives here, keyed off which of the three save paths in
    /// this file (`SubmissionPipeline.run`, forced or not, vs.
    /// `saveWithoutExtraction`) actually threw the duplicate.
    private enum PendingDuplicateRetry {
        case run(data: Data, kind: ReceiptKind, category: String, forcedProvider: ExtractionProvider?)
        case saveWithoutExtraction(data: Data, kind: ReceiptKind, category: String,
                                    vendor: String, workDate: String, amount: String, comments: String,
                                    needsReview: Bool, reviewReason: String)
    }
    @State private var pendingDuplicateRetry: PendingDuplicateRetry?

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
    ///
    /// Not `Equatable` — one case below (`.duplicate`) would need
    /// `HistoryEntry: Equatable` for that, and nothing here actually
    /// compares whole `SubmitState` values; every check either pattern-matches
    /// a single case (`controlsDisabled`, `isOfflineChoicePrompt`) or, for the
    /// one place that used to write `submitState == .queued`, pattern-matches
    /// too now (see the message color logic below).
    private enum SubmitState {
        case idle
        case running
        case success
        case queued
        case needsDate
        case needsAmount
        /// The manual-entry path is about to save with today's date only
        /// because nothing read a date off the receipt (see
        /// `ManualEntryOCRPrefill.needsDateConfirmation`). Shown *before* the
        /// save, unlike `.needsDate` — the manual path knows its date is a
        /// fallback up front, where the AI path only finds out from the
        /// entry it already saved. Carries the resolution so the copy can
        /// name which of the three ways the read failed (nil = OCR hadn't
        /// finished, treated as "couldn't read it").
        case confirmDate(ManualEntryOCRPrefill.DateResolution?)
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
        /// A save was blocked because a history entry already matches this
        /// receipt's category/date/amount (see `SubmissionError.duplicate`).
        /// Deliberately its own case rather than reusing `.success` — the
        /// save didn't actually happen, and the old behavior (showing the
        /// green "Submitted" checkmark, which never even reads `message`)
        /// was actively misleading. Carries the *existing* entry so the UI
        /// can show what it matched against, and stays on screen — no
        /// auto-dismiss timer — until the user picks "Save Anyway" or
        /// "Discard".
        case duplicate(existing: HistoryEntry)
    }

    private var controlsDisabled: Bool {
        if case .idle = submitState { return false }
        return true
    }

    /// True only in the pre-submit state — the one state whose Submit button
    /// lives in the toolbar (see the `.confirmationAction` item in `body`).
    /// Inverse of `controlsDisabled`, but named for what the toolbar actually
    /// asks ("are we still waiting for the user to submit?") rather than for
    /// whether the form's fields happen to be editable.
    private var isIdle: Bool { !controlsDisabled }

    /// True while the `.offlineChoice` prompt is on screen — used to shrink
    /// the receipt thumbnail so its buttons stay reachable without scrolling
    /// (reported on an iPhone with a Dynamic Island, not just small screens).
    private var isOfflineChoicePrompt: Bool {
        if case .offlineChoice = submitState { return true }
        return false
    }

    /// True when the queued-for-retry message should read as an error (red)
    /// rather than a routine status note. Was `submitState == .queued`
    /// before `SubmitState` dropped `Equatable` (see that enum's comment).
    private var isQueuedState: Bool {
        if case .queued = submitState { return true }
        return false
    }

    /// The bytes handed to `BillPhotoViewerView`, which only accepts raw
    /// image data (see `QueueEntryDetailView`'s call site) — not a PDF. For
    /// an image attachment that's the original capture, full quality. For a
    /// PDF there's no "original photo" to fall back to, so this renders the
    /// first page the same way the OCR prefill above already does
    /// (`pdfThumbnail`) rather than adding a second, higher-fidelity PDF
    /// renderer just for this viewer.
    private var zoomablePhotoData: Data? {
        switch attachment.kind {
        case .image: return attachment.data
        case .pdf: return pdfThumbnail(attachment.data)?.pngData()
        }
    }

    /// Vendor is deliberately NOT part of this — an empty vendor no longer
    /// blocks Submit (see `submitManually`, which falls back to
    /// "Unknown Vendor" and flags the entry for review instead). Amount is
    /// different: a wrong or placeholder *number* silently sitting in a tax
    /// record is worse than an obviously-fake vendor name, since totals get
    /// summed and nobody re-reads every line. So amount still has to parse
    /// before Submit enables — but unlike before, `blockedSubmitReason`
    /// below makes sure the button explains why instead of just sitting
    /// disabled.
    private var manualAmountValid: Bool {
        Double(manualAmount.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private var canSubmit: Bool {
        let needsManualFields = !ExtractionSettings.aiConfigured || proceedWithoutAI
        return !selectedCategory.isEmpty && (!needsManualFields || manualAmountValid)
    }

    /// Human-readable reason Submit is currently disabled, or nil when it
    /// isn't. `canSubmit` used to just disable the button with nothing
    /// explaining why — see TODO.md item 1, "Never block the save" — so
    /// this is shown whenever something still blocks it, rather than leaving
    /// a silently-dead control. Since Submit moved to the toolbar (it was
    /// being clipped as the Form's last row in the share extension's short
    /// sheet), this text no longer sits directly under the button. It renders
    /// twice instead: as the Category section's footer, which is high enough
    /// to survive that same short sheet and sits against the control that
    /// most often triggers it, and again in the Section where the button used
    /// to be, which is where the eye lands on the main app's taller screen.
    /// Duplication is intentional — see the footer's comment in `body`.
    private var blockedSubmitReason: String? {
        guard !canSubmit else { return nil }
        if selectedCategory.isEmpty {
            return "Pick a category above to save this receipt."
        }
        let needsManualFields = !ExtractionSettings.aiConfigured || proceedWithoutAI
        if needsManualFields && !manualAmountValid {
            return manualAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter an amount to save this receipt — unlike the vendor, a missing or wrong dollar amount can't be safely guessed for a tax record."
                : "\"\(manualAmount)\" isn't a valid amount — enter a number like 42.10 to save this receipt."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        if let thumb = attachment.thumbnail {
                            // Tappable for the same reason as the Retry Queue's
                            // photo (ContentView.swift's QueueEntryDetailView):
                            // a small static thumbnail can't show a receipt
                            // total legibly, and this screen is the one that
                            // explicitly asks the user to verify every field
                            // against the paper when there's no AI to trust.
                            Button {
                                showPhotoViewer = true
                            } label: {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFit()
                                    // Shrunk only for the offline-choice prompt below —
                                    // by the time that prompt is showing the user has
                                    // already seen the photo, and the buttons that
                                    // decide what happens next need to fit on screen
                                    // without scrolling more than the thumbnail needs
                                    // full size.
                                    .frame(maxHeight: isOfflineChoicePrompt ? 100 : 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(zoomablePhotoData == nil)
                            .accessibilityLabel("View full receipt photo")
                        } else {
                            Label("PDF attached", systemImage: "doc.fill")
                        }
                        Spacer()
                    }
                } footer: {
                    if zoomablePhotoData != nil {
                        Text("Tap the photo to zoom in.")
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
                                .accessibilityHidden(true)
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
                        // Bound through a setter rather than directly to
                        // `$manualWorkDate` so touching the picker records
                        // that a human chose this date (`userEditedDate`),
                        // which is what suppresses the `.confirmDate` prompt
                        // below. `.onChange` would also fire when OCR prefill
                        // writes a date into the field, which is exactly the
                        // case the prompt must still cover.
                        DatePicker("Receipt Date", selection: Binding(
                            get: { manualWorkDate },
                            set: { manualWorkDate = $0; userEditedDate = true }
                        ), displayedComponents: .date)
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
                        .accessibilityElement(children: .combine)
                    } footer: {
                        Text(proceedWithoutAI
                             ? "Continuing without AI for this receipt. Everything below is on-device only."
                             : "Connect an AI in Settings to read receipts automatically instead of entering them by hand.")
                    }
                }

                Section {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categoryStore.categories, id: \.self) { Text($0) }
                    }
                    .adaptiveCategoryPickerStyle(count: categoryStore.categories.count)
                    .disabled(controlsDisabled)
                } header: {
                    Text("Category")
                } footer: {
                    // The same `blockedSubmitReason` shown further down, hoisted
                    // to sit against the control that most often causes it.
                    // Moving Submit to the toolbar made the *button* immune to
                    // the share extension's short sheet, but not this
                    // explanation: it stayed where the button used to be, at the
                    // bottom of the Form, i.e. below exactly the fold that
                    // clipped the button in the first place. A disabled Submit
                    // that can't say why is the thing TODO.md item 1 ("Never
                    // block the save") exists to prevent, so the reason has to
                    // live above the fold too — and this footer is the highest
                    // point in the Form that's still adjacent to its cause.
                    // Deliberately duplicated rather than moved: on the main
                    // app's tall screen the copy next to Submit's old position
                    // is the one in the user's eyeline.
                    if let blockedSubmitReason {
                        Text(blockedSubmitReason)
                            // Red is this file's error tone (see the no-AI
                            // banner and the in-body copy of this same text).
                            // No `.font(.caption)` — footers already render at
                            // caption size, so setting it again would be a
                            // no-op modifier.
                            .foregroundStyle(.red)
                    }
                }

                // Only pre-submit: every later state either already carries a
                // flag or offers its own "leave it flagged" exit (the
                // `.needsDate` / `.needsAmount` Skip buttons), so a toggle
                // there would be a second control for a decision already made.
                if isIdle {
                    Section {
                        Toggle("Review Later", isOn: $setAsideForReview)
                    } footer: {
                        Text("Saves the receipt as normal and flags it, so it shows up under \"needs review\" in Receipts for you to come back to.")
                    }
                }

                // Rendered only when it has something in it. In the `.idle`
                // state `submitContent` is now just the blocked-submit
                // explanation (the Submit button itself moved to the toolbar),
                // so with nothing blocking Submit and no status message this
                // Section would otherwise draw as an empty grey block under
                // the Category picker.
                if !isIdle || blockedSubmitReason != nil || message != nil {
                    Section {
                        submitContent
                        if let message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(isQueuedState ? .red : .secondary)
                        }
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
                // Submit lives here, not at the bottom of the Form, because
                // the share extension presents this view in a short,
                // height-constrained sheet: as the Form's last row the button
                // fell below the fold and was clipped in half by the sheet's
                // bottom edge, with the extension's "open Receipts4Tax" footer
                // overlapping what was left of it. In the toolbar it's always
                // visible whatever the sheet height or scroll position, and it
                // pairs with Cancel in the standard iOS Cancel-left /
                // confirm-right idiom. Only shown while `.idle` — every other
                // state has its own inline controls in `submitContent`
                // (progress, Save Anyway/Discard, the offline choices), and
                // leaving a live Submit in the toolbar beside them would let
                // the user re-fire a pipeline that's already running or done.
                if isIdle {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Submit", action: submit)
                            .bold()
                            .disabled(!canSubmit)
                    }
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
        .fullScreenCover(isPresented: $showPhotoViewer) {
            if let data = zoomablePhotoData {
                BillPhotoViewerView(photoData: data, onDone: { showPhotoViewer = false })
            }
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
        guard let imageData else {
            // Nothing renderable to OCR at all (unreadable bytes, a PDF with
            // no first page) — no text, so no date. Same standing as OCR
            // returning nothing.
            dateResolution = .noTextRecognized
            return
        }

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

        // Recorded even when there's no text — `.noTextRecognized` is a
        // distinct, reportable outcome, not the absence of one.
        dateResolution = ManualEntryOCRPrefill.resolveDate(in: text)

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
        // Same "don't stomp on what the user typed" rule as the two fields
        // above — a date the user already set outranks the OCR guess.
        if case .found(let date) = dateResolution, !userEditedDate {
            manualWorkDate = date
        }
    }

    // MARK: - Submit

    @ViewBuilder
    private var submitContent: some View {
        switch submitState {
        case .idle:
            // The Submit button itself is in the toolbar (see `body`) so the
            // share extension's short sheet can't clip it. What stays here is
            // the reason it's disabled: never a silently-dead button — see
            // `blockedSubmitReason`. Keeping this in the form body rather than
            // in the toolbar is deliberate; it's a full sentence naming the
            // field to fix, and it sits directly under the Category picker
            // that most often causes it.
            if let blockedSubmitReason {
                Text(blockedSubmitReason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
                // A real button rather than the grey caption this used to
                // be. It is the only way off this screen: the toolbar's
                // Cancel is disabled here, because `controlsDisabled`
                // covers every state but `.idle`, so an escape hatch
                // styled as fine print reads as a form the user is stuck
                // in. `.bordered` against Save's `.borderedProminent`
                // keeps the primary action the obvious one, which is why
                // the disable rule itself is left alone.
                Button {
                    onComplete()
                } label: {
                    HStack {
                        Spacer()
                        Text("Skip for now — it stays flagged for review")
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        case .confirmDate(let resolution):
            // Same inline-prompt shape as `.needsDate` / `.offlineChoice`
            // rather than an alert: the user is already looking at this form,
            // an alert can't hold a date picker, and the share extension's
            // short sheet makes anything modal riskier than a few rows in
            // place. Every button here ends in a save — see
            // `blockedSubmitReason` and TODO.md item 1, "Never block the
            // save": this prompt changes *what date* is written, never
            // whether the receipt can be saved.
            VStack(alignment: .leading, spacing: 12) {
                Label(Self.dateConfirmTitle(for: resolution), systemImage: "calendar.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(Self.dateConfirmMessage(for: resolution))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("Receipt Date", selection: $pickedDate, displayedComponents: .date)
                // One button, not two: whatever the picker shows is what
                // gets saved. Its title just names which of the two that is,
                // so "use today" stays a single tap (the common case) while
                // correcting the date is the same tap after scrolling the
                // picker — no way to pick a date and then not have it used.
                Button {
                    confirmDateAndSave(resolution: resolution)
                } label: {
                    HStack {
                        Spacer()
                        Text(Calendar.current.isDateInToday(pickedDate)
                             ? "Use Today's Date"
                             : "Save with This Date").bold()
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Back to the details") {
                    pendingManualSave = nil
                    submitState = .idle
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
                // A real button rather than the grey caption this used to
                // be. It is the only way off this screen: the toolbar's
                // Cancel is disabled here, because `controlsDisabled`
                // covers every state but `.idle`, so an escape hatch
                // styled as fine print reads as a form the user is stuck
                // in. `.bordered` against Save's `.borderedProminent`
                // keeps the primary action the obvious one, which is why
                // the disable rule itself is left alone.
                Button {
                    onComplete()
                } label: {
                    HStack {
                        Spacer()
                        Text("Skip for now — it stays flagged for review")
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
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
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if canUseAppleIntelligence {
                    // One line carries the distinction that used to take two
                    // paragraphs: Apple Intelligence is a real model reading
                    // the receipt on-device, "Continue Without AI" below is
                    // just on-device text matching and is often wrong. Kept
                    // short so the buttons stay on screen without scrolling.
                    Text("Apple Intelligence reads the receipt on this iPhone; Continue Without AI just text-matches and is often wrong.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        useAppleIntelligence()
                    } label: {
                        HStack { Spacer(); Text("Use Apple Intelligence").bold(); Spacer() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("The receipt itself is fine — fill in the details yourself, or save it to submit with AI later.")
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
                // Last and least prominent of the choices — discards the
                // capture entirely. Reuses `onCancel`, the exact same
                // dismissal the toolbar Cancel button uses (see the
                // `.toolbar` above), rather than a second path that might
                // drift from it. Plain-style + destructive role instead of
                // `.bordered`/`.borderedProminent` like its siblings, since
                // "discard" shouldn't visually compete with the two ways
                // forward above it.
                Button(role: .destructive, action: onCancel) {
                    HStack { Spacer(); Text("Discard Receipt"); Spacer() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        case .duplicate(let existing):
            // Info-colored (blue), not green — this is explicitly not a
            // "Submitted" confirmation. The match that triggered this only
            // checks category/date/amount, not vendor, so it's a real
            // false-positive risk (a repeat coffee order, a flat fee
            // charged twice); showing the existing entry's details is what
            // lets the user actually judge whether that's what happened.
            VStack(alignment: .leading, spacing: 12) {
                Label("Already Saved", systemImage: "checkmark.circle.badge.questionmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Text("A receipt already matches this category, date, and amount:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(existing.vendor.isEmpty ? "this vendor" : existing.vendor) — \(existing.workDate) — $\(existing.amount)")
                    .font(.caption.weight(.medium))
                Text("If this is a different receipt, save it anyway. Otherwise, discard this one — nothing further needs to happen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    saveDuplicateAnyway()
                } label: {
                    HStack { Spacer(); Text("Save Anyway").bold(); Spacer() }
                }
                .buttonStyle(.borderedProminent)
                // "Discard" mirrors the old default behavior (this receipt
                // was already treated as done), just chosen explicitly by
                // the user now instead of assumed on their behalf after a
                // timer. `onComplete()`, not `onCancel()`, since every call
                // site's `onComplete` is what actually closes out this
                // submission (removing a retry-queue entry, draining the
                // spool, dismissing the sheet) — the same cleanup that ran
                // automatically before this fix.
                Button(role: .destructive, action: onComplete) {
                    HStack { Spacer(); Text("Discard"); Spacer() }
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
        let updated = try? SubmissionPipeline.updateEntry(
            old: entry,
            newCategory: entry.category, newVendor: entry.vendor,
            newWorkDate: LocalReceiptStore.dateString(pickedDate),
            newAmount: entry.amount, newComments: existingComments,
            newVendorType: entry.vendorType)
        reapplyReviewFlagIfSetAside(updated)
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
        let updated = try? SubmissionPipeline.updateEntry(
            old: entry,
            newCategory: entry.category, newVendor: entry.vendor,
            newWorkDate: entry.workDate,
            newAmount: normalizedAmount, newComments: existingComments,
            newVendorType: entry.vendorType)
        reapplyReviewFlagIfSetAside(updated)
        onComplete()
    }

    /// Re-flags an entry that `updateEntry` just marked `.verified`.
    ///
    /// `updateEntry` clearing the HITL flag is right for the Edit screen,
    /// where saving *is* the review. It's wrong for the two prompts that
    /// call it here: the user supplied one field they were asked for, which
    /// isn't the same as having looked the receipt over — and if they'd
    /// asked for it to be set aside, that request would silently undo
    /// itself. A no-op when the toggle is off, or when the update failed
    /// (the entry then keeps the flag it already had).
    private func reapplyReviewFlagIfSetAside(_ entry: HistoryEntry?) {
        guard setAsideForReview, let entry else { return }
        SubmissionPipeline.flagForReview(entry)
    }

    /// Shared "what to show next" after a successful `SubmissionPipeline.run`
    /// — used by `submit()`, `useAppleIntelligence()`, and the AI-extraction
    /// branch of `saveDuplicateAnyway()`, all three of which run the same
    /// pipeline call and need the same needsDate/needsAmount/success fork
    /// (previously duplicated three ways; a fourth copy for Save Anyway was
    /// the reason to pull it out).
    private func finishAfterSave(_ saved: HistoryEntry) async {
        // Applied here rather than at each of the three call sites because
        // this is the one funnel they all pass through. `flagForReview`
        // leaves an entry that a guardrail already flagged exactly as it
        // was, so the two `.needsReview` checks below still see the
        // pipeline's own reason and still raise the date/amount prompts —
        // "review later" adds a flag, it never masks one.
        let entry = setAsideForReview ? SubmissionPipeline.flagForReview(saved) : saved
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
            // The one unambiguous "it worked" in the app. Fired here rather
            // than at each call site because this is the shared funnel — see
            // this function's comment.
            Haptics.success()
            submitState = .success
            try? await Task.sleep(nanoseconds: 800_000_000)
            onComplete()
        }
    }

    /// "Save Anyway" out of the `.duplicate` prompt — reruns the exact save
    /// that was just blocked, this time with `allowDuplicate: true` so
    /// `SubmissionPipeline` skips its category+date+amount match entirely.
    /// This is the one place in the app that ever passes `allowDuplicate: true`
    /// — an explicit, user-initiated retry of a save the user has already
    /// been shown was flagged as a possible duplicate, not a blanket bypass.
    private func saveDuplicateAnyway() {
        guard let retry = pendingDuplicateRetry else { onComplete(); return }
        pendingDuplicateRetry = nil
        message = nil
        submitState = .running

        Task {
            do {
                switch retry {
                case .run(let data, let kind, let category, let forcedProvider):
                    statusText = SubmissionPipeline.Stage.reading.statusText
                    let entry = try await SubmissionPipeline().run(
                        data: data, kind: kind, category: category,
                        forcedProvider: forcedProvider, allowDuplicate: true) { stage in
                        statusText = stage.statusText
                    }
                    await finishAfterSave(entry)
                case .saveWithoutExtraction(let data, let kind, let category, let vendor, let workDate,
                                             let amount, let comments, let needsReview, let reviewReason):
                    statusText = SubmissionPipeline.Stage.saving.statusText
                    _ = try SubmissionPipeline.saveWithoutExtraction(
                        data: data, kind: kind, category: category,
                        vendor: vendor, workDate: workDate, amount: amount, comments: comments,
                        needsReview: needsReview, reviewReason: reviewReason, allowDuplicate: true)
                    submitState = .success
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    onComplete()
                }
            } catch {
                // `allowDuplicate: true` means this can't throw `.duplicate`
                // again — only a real save failure (disk, etc.) lands here.
                message = "Couldn't save: \(error.localizedDescription)"
                submitState = .idle
            }
        }
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
                await finishAfterSave(entry)
            } catch SubmissionError.duplicate(let existing) {
                pendingOfflineSubmission = nil
                // See `SubmitState.duplicate` — held so "Save Anyway" can
                // redo this exact forced-provider save with the bypass.
                pendingDuplicateRetry = .run(data: pending.data, kind: pending.kind,
                                              category: pending.category, forcedProvider: .appleOnDevice)
                Haptics.warning()
                submitState = .duplicate(existing: existing)
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
            // Nothing read a date off this receipt, so `manualWorkDate` is
            // still just "today" — the silent fallback that put a pile of
            // receipts in the wrong tax year. Confirm it (or correct it)
            // before writing it, instead of after.
            if ManualEntryOCRPrefill.needsDateConfirmation(resolution: dateResolution,
                                                            userEditedDate: userEditedDate) {
                pendingManualSave = PendingManualSave(data: data, kind: kind, category: category)
                pickedDate = manualWorkDate
                submitState = .confirmDate(dateResolution)
                return
            }
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
                await finishAfterSave(entry)
            } catch SubmissionError.duplicate(let existing) {
                // Already recorded by category/date/amount — but that match
                // doesn't check vendor, so this could genuinely be a
                // different receipt. Hold what's needed to redo this exact
                // save with the bypass if the user says so via "Save Anyway".
                pendingDuplicateRetry = .run(data: data, kind: kind, category: category, forcedProvider: nil)
                Haptics.warning()
                submitState = .duplicate(existing: existing)
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

    /// Fallback vendor written when the user submits with the Vendor field
    /// still blank — happens whenever OCR prefill deliberately returned
    /// nothing rather than guess (see `ManualEntryOCRPrefill.likelyVendorLine`)
    /// and the user didn't type one in either. Saving still proceeds (see
    /// TODO.md item 1, "Never block the save") — a missing name is easy to
    /// spot and fix later from the Receipts list; refusing to save the
    /// receipt at all is the actual harm.
    static let unknownVendorPlaceholder = "Unknown Vendor"

    /// Heading for the `.confirmDate` prompt. Each `DateResolution` failure
    /// gets its own wording because they mean materially different things to
    /// someone holding the receipt: "no date is printed here" is routine,
    /// "there are dates here and I couldn't read them" means the right date
    /// is probably on the paper in front of them, and "I couldn't read this
    /// photo at all" says the problem is the photo, not the receipt.
    static func dateConfirmTitle(for resolution: ManualEntryOCRPrefill.DateResolution?) -> String {
        switch resolution {
        case .noDatePrinted:
            return "No date found on this receipt"
        case .ambiguous:
            return "Couldn't read the date on this receipt"
        case .noTextRecognized, .none:
            return "Couldn't read this receipt"
        case .found:
            // Never shown — a found date doesn't prompt. Worded as the
            // general case rather than trapping, since a prompt with no
            // heading would be worse than a slightly generic one.
            return "Check this receipt's date"
        }
    }

    /// Body copy for the `.confirmDate` prompt. Every variant states the same
    /// two facts — today's date is about to be used, and a wrong date lands
    /// the expense in the wrong tax year — because that consequence is the
    /// entire reason this prompt exists and is not obvious from "couldn't
    /// read the date."
    static func dateConfirmMessage(for resolution: ManualEntryOCRPrefill.DateResolution?) -> String {
        let consequence = "A wrong date can put this expense in the wrong tax year, so it's worth a look."
        switch resolution {
        case .noDatePrinted:
            return "Nothing on this receipt looked like a date. Today's date will be used unless you set the right one below. \(consequence)"
        case .ambiguous(let printedDates):
            let count = printedDates == 1 ? "A date is printed" : "\(printedDates) dates are printed"
            return "\(count) on this receipt, but it wasn't clear which one is the purchase date. Today's date will be used unless you set the right one below. \(consequence)"
        case .noTextRecognized, .none:
            return "No text could be read off this photo, so no date was found. Today's date will be used unless you set the right one below. \(consequence)"
        case .found:
            return "Set the date printed on the receipt. \(consequence)"
        }
    }

    /// Review reason recorded when the user confirms today's date rather than
    /// setting one — see `confirmDateAndSave`. Deliberately still flags the
    /// entry `.needsReview`: the user confirmed a *guess*, not a date they
    /// read off the paper, so it stays in the Receipts list's "needs review"
    /// group (and one tap from "Looks Good") until someone checks it against
    /// the receipt. This is exactly the pile of scan-dated receipts that
    /// motivated the prompt — a confirmation makes them intentional, not
    /// verified. Ends in "used today's date", deliberately *not* the AI
    /// path's "defaulted to today" suffix, which `finishAfterSave` and
    /// `ScannedTextSubmitView` match on to raise their own post-save date
    /// prompt — this date has already been confirmed, so re-prompting for it
    /// would be a loop.
    static func confirmedTodayReviewReason(for resolution: ManualEntryOCRPrefill.DateResolution?) -> String {
        switch resolution {
        case .noDatePrinted:
            return "No date printed on the receipt — confirmed, used today's date"
        case .ambiguous:
            return "Date on the receipt couldn't be read — confirmed, used today's date"
        case .noTextRecognized, .none, .found:
            return "No text could be read off this receipt — confirmed, used today's date"
        }
    }

    /// Folds however many independent review reasons a single save collected
    /// (a missing vendor, an unconfirmable date) into the one
    /// `reviewReason` string `HistoryEntry` carries. Any non-empty reason
    /// means the entry needs review; the Receipts list shows the whole
    /// string, so both causes stay visible rather than the first one
    /// silently winning.
    static func combineReviewReasons(_ reasons: [String]) -> (needsReview: Bool, reason: String) {
        let kept = reasons.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (!kept.isEmpty, kept.joined(separator: " · "))
    }

    /// "Use Today's Date" / "Save with This Date" out of the `.confirmDate`
    /// prompt — completes the paused manual save with whatever date the
    /// picker ended on. Picking a date the user read off the receipt saves
    /// clean (a human supplied it); keeping today's saves flagged, per
    /// `confirmedTodayReviewReason`.
    private func confirmDateAndSave(resolution: ManualEntryOCRPrefill.DateResolution?) {
        guard let pending = pendingManualSave else { submitState = .idle; return }
        pendingManualSave = nil
        manualWorkDate = pickedDate
        // The user has now made this date their own either way, so the prompt
        // must not fire again if this save fails and they hit Submit a second
        // time.
        userEditedDate = true
        let dateReviewReason = Calendar.current.isDateInToday(pickedDate)
            ? Self.confirmedTodayReviewReason(for: resolution)
            : ""
        submitState = .running
        submitManually(data: pending.data, kind: pending.kind, category: pending.category,
                       dateReviewReason: dateReviewReason)
    }

    /// Resolves what to actually save for Vendor from what the user typed —
    /// pulled out of `submitManually` as its own static function so the
    /// substitution (blank input still saves, as `unknownVendorPlaceholder`,
    /// flagged for review) is unit-testable without standing up the view.
    static func resolveManualVendor(_ raw: String) -> (vendor: String, needsReview: Bool, reviewReason: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return (trimmed, false, "") }
        return (unknownVendorPlaceholder, true, "Vendor name missing")
    }

    /// No AI provider configured — saves the photo/PDF with the hand-typed
    /// fields instead of running extraction. Not routed through the retry
    /// queue on failure: retries there always re-run AI extraction
    /// (`SubmissionPipeline.run`), which would ignore what the user typed —
    /// simpler to just let them hit Submit again.
    ///
    /// Vendor is allowed to be empty here (see `canSubmit`, which no longer
    /// requires it) — it's substituted with `unknownVendorPlaceholder` and
    /// the saved entry is flagged `.needsReview`, the same mechanism
    /// `ExtractedReceipt.build` already uses for an AI-read receipt with a
    /// blank vendor. Amount is not handled this way: `canSubmit` still
    /// requires it to parse before this function ever runs, so by the time
    /// we're here `normalizedAmount` is always a real number the user
    /// confirmed, not a placeholder.
    private func submitManually(data: Data, kind: ReceiptKind, category: String,
                                dateReviewReason: String = "") {
        statusText = SubmissionPipeline.Stage.saving.statusText
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        let normalizedAmount = Double(manualAmount.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { String($0) } ?? manualAmount
        let (vendor, _, vendorReviewReason) = Self.resolveManualVendor(manualVendor)
        // Vendor and date can each independently need review; keep both
        // reasons rather than letting one overwrite the other.
        // The user's own flag goes last so an automatic reason, which names
        // the field to fix, leads the combined string shown under the row.
        let (needsReview, reviewReason) = Self.combineReviewReasons(
            [vendorReviewReason, dateReviewReason,
             setAsideForReview ? userFlaggedReviewReason : ""])
        let workDate = formatter.string(from: manualWorkDate)
        let comments = manualComments.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                _ = try SubmissionPipeline.saveWithoutExtraction(
                    data: data, kind: kind, category: category,
                    vendor: vendor, workDate: workDate, amount: normalizedAmount, comments: comments,
                    needsReview: needsReview, reviewReason: reviewReason)
                submitState = .success
                try? await Task.sleep(nanoseconds: 800_000_000)
                onComplete()
            } catch SubmissionError.duplicate(let existing) {
                // Hold everything needed to redo this exact hand-typed save
                // with the bypass — including the resolved vendor/needsReview
                // values (not the raw `manualVendor` text), so "Save Anyway"
                // writes the identical entry this attempt would have.
                pendingDuplicateRetry = .saveWithoutExtraction(
                    data: data, kind: kind, category: category,
                    vendor: vendor, workDate: workDate, amount: normalizedAmount, comments: comments,
                    needsReview: needsReview, reviewReason: reviewReason)
                Haptics.warning()
                submitState = .duplicate(existing: existing)
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
