import SwiftUI

/// "Try it with a sample receipt" — TODO.md item 9. Lets someone see the
/// real scanning pipeline work in seconds, with no camera permission and no
/// receipt in hand.
///
/// Deliberately NOT `ReceiptSubmitView`. That view's `submit()` /
/// `submitManually()` / `saveDateAndFinish()` / `saveAmountAndFinish()` /
/// `useAppleIntelligence()` all end by calling `SubmissionPipeline`'s real
/// save functions (`run`, `saveWithoutExtraction`, `updateEntry`) or
/// `SubmissionStore.enqueue` unconditionally — every one of those call sites
/// would need its own "unless this is a demo" branch to stop a fake
/// "Riverbend Hardware" receipt from landing in the user's real history and
/// CSV. That is exactly the flag-threaded-through-real-save-code mess
/// TODO.md item 9 warns against building.
///
/// Instead this is a dedicated, much simpler screen that calls the same
/// underlying extraction building blocks `ReceiptSubmitView` and
/// `SubmissionPipeline` use — `ExtractionSettings.currentExtractor()` when an
/// AI provider is configured (the real Claude/OpenAI/Gemini/Apple On-Device
/// call), or the same on-device Vision OCR + `ManualEntryOCRPrefill` guesses
/// `ReceiptSubmitView.prefillManualFieldsFromOCR` uses when none is — and
/// stops there. It never references `SubmissionStore`, `LocalReceiptStore`,
/// or any `SubmissionPipeline` save function, so there is no save call
/// anywhere in this file that a future edit could accidentally leave enabled.
struct SampleReceiptDemoView: View {
    /// The presenter owns the sheet flag — same pattern `ConnectAIView`
    /// and `ReceiptSubmitView` use, so dismissing this can never be
    /// mistaken for completing a real submission.
    let onDone: () -> Void

    @State private var image: UIImage?
    @State private var isExtracting = true
    @State private var vendor = ""
    @State private var amount = ""
    @State private var workDate = ""
    @State private var comments = ""
    @State private var usedAI = false
    @State private var note: String?

    // Same App Group key SettingsView/ReceiptSubmitView read, purely so the
    // currency symbol shown here matches the rest of the app — this view
    // never writes anything back.
    @AppStorage(AppConstants.DefaultsKeys.appCurrency, store: UserDefaults(suiteName: AppConstants.appGroupID))
    private var appCurrency: AppCurrency = .auto

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Preview only — this is not saved", systemImage: "eye")
                        .font(.subheadline.weight(.semibold))
                } footer: {
                    Text("This receipt is made up and generated right on your iPhone, just to show how scanning works. Nothing here is added to your real receipts.")
                }

                Section {
                    HStack {
                        Spacer()
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 260)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Spacer()
                    }
                }

                Section {
                    if isExtracting {
                        HStack {
                            Spacer()
                            ProgressView()
                            Text("Reading receipt…").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        LabeledContent("Vendor", value: vendor.isEmpty ? "—" : vendor)
                        LabeledContent("Date", value: workDate.isEmpty ? "—" : workDate)
                        LabeledContent("Amount", value: amount.isEmpty ? "—" : "\(appCurrency.symbol)\(amount)")
                        if !comments.isEmpty {
                            LabeledContent("Notes", value: comments)
                        }
                    }
                } header: {
                    Text("What the pipeline read")
                } footer: {
                    if !isExtracting {
                        Text(usedAI
                             ? "Read automatically using your configured AI, exactly like a real scan would be."
                             : "Read using on-device text recognition, since no AI is configured yet — connect one in Settings for automatic reads.")
                    }
                    if let note {
                        Text(note).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Sample Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .task {
            await runDemo()
        }
    }

    /// Generates the fabricated receipt and runs it through the real
    /// extraction path, then stops — no category picker, no Submit button,
    /// nothing downstream that could persist it.
    private func runDemo() async {
        let generated = SyntheticReceiptGenerator.generateImage()
        image = generated
        defer { isExtracting = false }

        guard let data = generated.pngData() else {
            note = "Couldn't render the sample image."
            return
        }

        guard ExtractionSettings.aiConfigured else {
            await runOCRFallback(data: data)
            return
        }

        do {
            let categoryContext = CategoryStore.shared.description(
                for: CategoryStore.shared.categories.first ?? "")
            let extracted = try await ExtractionSettings.currentExtractor()
                .extract(data: data, kind: .image, categoryContext: categoryContext)
            vendor = extracted.vendor
            amount = extracted.amount
            workDate = extracted.workDate
            comments = extracted.comments
            usedAI = true
        } catch {
            // Best-effort, like the rest of this preview: fall back to the
            // same on-device OCR path a real submission would if AI couldn't
            // be reached, rather than showing a dead end for what's only a
            // demo.
            note = "AI extraction couldn't be reached for this preview — showing the on-device text recognition fallback instead."
            await runOCRFallback(data: data)
        }
    }

    /// Mirrors `ReceiptSubmitView.prefillManualFieldsFromOCR`'s no-AI path:
    /// layout-aware OCR first, flat OCR text as a fallback, then the same
    /// deterministic guesses used to prefill manual entry.
    private func runOCRFallback(data: Data) async {
        var text: String?
        if let rows = try? await VisionLayoutService.recognizeRowsViaRawOCR(in: data), !rows.isEmpty {
            text = VisionLayoutService.layoutString(from: rows)
        }
        if text == nil || text?.isEmpty == true {
            text = try? await VisionOCRService.recognizeText(in: data)
        }
        guard let text, !text.isEmpty else {
            note = "On-device text recognition couldn't read the sample image."
            return
        }

        amount = ManualEntryOCRPrefill.likelyGrandTotal(in: text) ?? ""
        vendor = ManualEntryOCRPrefill.likelyVendorLine(in: text) ?? ""
        if let date = ManualEntryOCRPrefill.likelyReceiptDate(in: text) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            workDate = formatter.string(from: date)
        }
    }
}
