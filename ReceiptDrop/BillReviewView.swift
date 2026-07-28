import Contacts
import ContactsUI
import MessageUI
import SwiftUI

/// Shows the itemized breakdown from a captured bill — numbered, large type,
/// with a local arithmetic check against the printed subtotal/total (catches
/// padded bills for free, no AI cost) and any lines the model couldn't read.
/// Ephemeral by default (Done just discards); "Save to Receipts" bridges into
/// the normal archival pipeline if the bill turns out to matter after all.
@MainActor
struct BillReviewView: View {
    let photoData: Data
    let onDone: () -> Void
    let onScanNew: () -> Void

    @State private var state: LoadState = .loading
    @State private var textScale: CGFloat = 1
    @State private var showContactPicker = false
    @State private var messageRecipients: [String]?
    @State private var messageAttachments: [(data: Data, filename: String)] = []
    @State private var showSaveToReceipts = false
    /// Items the user has tapped to mark as comped (e.g. "the restaurant said
    /// this was free") — purely a local, ephemeral display/math adjustment;
    /// never sent to the AI, never persisted. Resets each time a bill is
    /// freshly captured, same as everything else on this screen.
    @State private var compedItemIDs: Set<UUID> = []
    @State private var showPhotoViewer = false
    /// Tips only make sense for a fraction of what Check a Bill scans
    /// (restaurant bills, not medical/travel/retail receipts) — showing the
    /// calculation only when asked avoids irrelevant noise on every other
    /// kind of bill.
    @State private var showTipSuggestions = false

    private enum LoadState {
        case loading
        case loaded(ExtractedBill)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Reading the bill…").foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(message)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Try Again") { load() }
                    }
                case .loaded(let bill):
                    breakdown(for: bill)
                }
            }
            .navigationTitle("Bill Breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .onAppear { load() }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerView { name, phoneNumber in
                QuickSendContactStore.save(name: name, phoneNumber: phoneNumber)
                startMessage(to: phoneNumber)
            }
        }
        .sheet(isPresented: Binding(
            get: { messageRecipients != nil },
            set: { if !$0 { messageRecipients = nil } }
        )) {
            if let recipients = messageRecipients, !messageAttachments.isEmpty {
                MessageComposeView(recipients: recipients, attachments: messageAttachments) {
                    messageRecipients = nil
                    messageAttachments = []
                }
            }
        }
        .sheet(isPresented: $showSaveToReceipts) {
            if let image = UIImage(data: photoData) {
                ReceiptSubmitView(
                    attachment: SharedAttachment(kind: .image, data: photoData, thumbnail: image),
                    onCancel: { showSaveToReceipts = false },
                    onComplete: {
                        LocalReceiptStore.drainSpoolIntoDocuments()
                        showSaveToReceipts = false
                        onDone()
                    })
            }
        }
        .fullScreenCover(isPresented: $showPhotoViewer) {
            BillPhotoViewerView(photoData: photoData, onDone: { showPhotoViewer = false })
        }
    }

    private func load() {
        // Defensive check before ever calling an AI provider — if the photo
        // is empty or doesn't decode as a real image, say so honestly
        // instead of sending garbage bytes and surfacing a cryptic
        // provider-side error (e.g. Claude's "image cannot be empty").
        guard !photoData.isEmpty, UIImage(data: photoData) != nil else {
            state = .failed("No photo came through — please retake it.")
            return
        }
        state = .loading
        Task {
            do {
                let bill = try await BillItemizationService.itemize(data: photoData)
                state = .loaded(bill)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func breakdown(for bill: ExtractedBill) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    if !bill.vendor.isEmpty {
                        Text(bill.vendor)
                            .font(.title2.bold())
                    }
                    Spacer()
                    receiptThumbnail
                }

                if compedAdjustedMismatch(bill) {
                    mismatchBanner(bill)
                }
                if bill.unreadableLineCount > 0 {
                    unreadableBanner(bill)
                }

                if bill.items.isEmpty {
                    noItemsNotice
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(bill.items.enumerated()), id: \.element.id) { index, item in
                            let isComped = compedItemIDs.contains(item.id)
                            HStack(alignment: .top) {
                                Text("\(index + 1).")
                                    .font(.system(size: 20 * textScale, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, alignment: .leading)
                                Text(item.name)
                                    .font(.system(size: 20 * textScale, weight: .semibold))
                                    .strikethrough(isComped)
                                    .foregroundStyle(isComped ? .secondary : .primary)
                                if item.quantity > 1 {
                                    quantityBadge(item.quantity)
                                }
                                if isComped {
                                    compedBadge
                                }
                                Spacer()
                                Text(currency(item.price))
                                    .font(.system(size: 20 * textScale, weight: .semibold, design: .rounded))
                                    .strikethrough(isComped)
                                    .foregroundStyle(isComped ? .secondary : .primary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isComped {
                                    compedItemIDs.remove(item.id)
                                } else {
                                    compedItemIDs.insert(item.id)
                                }
                            }
                        }
                    }
                    Text("Tap an item to mark it comped/free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !compedItemIDs.isEmpty {
                    compedComparisonBanner(bill)
                }
                if let service = bill.serviceCharge, service > 0 {
                    gratuityBanner(service)
                }

                Divider()

                totalsBlock(bill)

                if bill.serviceCharge == nil || bill.serviceCharge == 0 {
                    if showTipSuggestions {
                        tipSuggestions(bill)
                    } else {
                        Button("Show Suggested Tip") {
                            withAnimation { showTipSuggestions = true }
                        }
                        .font(.subheadline)
                    }
                }

                textSizeControl

                actionButtons(bill)
            }
            .padding()
        }
    }

    /// Flags a doubled (or more) item at a glance — "was this really ordered
    /// twice?" is exactly the kind of thing worth a second look at the table,
    /// so it needs to stand out from a plain "×2" in the same font as the name.
    private func quantityBadge(_ quantity: Int) -> some View {
        Text("×\(quantity)")
            .font(.system(size: 16 * textScale, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange, in: Capsule())
    }

    /// Printed subtotal is the right baseline to check items against — it's
    /// pre-tax, same as the item list. Falls back to the grand total only
    /// when no subtotal was printed at all.
    private func printedBaseline(_ bill: ExtractedBill) -> Double {
        bill.subtotal ?? bill.total ?? bill.itemsSum
    }

    /// Sum of items, excluding anything marked comped — the number that
    /// should match the printed subtotal if a comp was actually honored.
    private func compedAdjustedItemsSum(_ bill: ExtractedBill) -> Double {
        bill.items.reduce(0) { sum, item in
            compedItemIDs.contains(item.id) ? sum : sum + item.price
        }
    }

    /// Same arithmetic check as `ExtractedBill.hasArithmeticMismatch`, but
    /// aware of comped items — a gap fully explained by a comp isn't an
    /// error, so it shouldn't also trigger the generic "items don't add up"
    /// warning (which is confusing next to the comp banner explaining the
    /// very same gap).
    private func compedAdjustedMismatch(_ bill: ExtractedBill) -> Bool {
        guard !bill.items.isEmpty else { return false }
        return abs(compedAdjustedItemsSum(bill) - printedBaseline(bill)) > 0.05
    }

    @ViewBuilder
    private func mismatchBanner(_ bill: ExtractedBill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Items don't add up", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Items total \(currency(compedAdjustedItemsSum(bill))), but the bill shows \(currency(printedBaseline(bill))).")
                .font(.subheadline)
        }
        .padding()
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func unreadableBanner(_ bill: ExtractedBill) -> some View {
        Label("\(bill.unreadableLineCount) line\(bill.unreadableLineCount == 1 ? "" : "s") couldn't be read clearly",
              systemImage: "questionmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
            .padding()
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Shown instead of a silent empty gap when the photographed page has no
    /// printed line items — e.g. a signed merchant copy with only
    /// Subtotal/Tip/Total, rather than the itemized guest check. Without
    /// this, an empty item list looks like the app lost the items rather
    /// than the page genuinely not having any.
    private var noItemsNotice: some View {
        Text("No itemized lines found on this page — just the totals below. If you have the itemized receipt, try capturing that one instead.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Lets the user check the AI-read breakdown against the actual paper —
    /// tap to open a full-screen zoomable viewer of the same photo.
    @ViewBuilder
    private var receiptThumbnail: some View {
        Button {
            showPhotoViewer = true
        } label: {
            if let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                    )
            }
        }
    }

    private var compedBadge: some View {
        Text("Comped")
            .font(.system(size: 14 * textScale, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green, in: Capsule())
    }

    /// Checks whether a comp you were promised actually made it onto the
    /// bill — not "what you owe" (you may have already signed for the full
    /// printed amount), but a flag worth raising with the table before you
    /// sign, if the printed subtotal doesn't reflect the comp. Uses the same
    /// pre-tax subtotal baseline as the mismatch check above — comparing a
    /// pre-tax item sum against the tax-inclusive grand total would compare
    /// the wrong two numbers and give a false "not reflected" reading.
    @ViewBuilder
    private func compedComparisonBanner(_ bill: ExtractedBill) -> some View {
        let expected = compedAdjustedItemsSum(bill)
        let printed = printedBaseline(bill)
        let honored = abs(expected - printed) < 0.05

        VStack(alignment: .leading, spacing: 4) {
            Label(honored ? "Comp reflected on the bill" : "Comp not reflected on the bill",
                  systemImage: honored ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(honored ? .green : .red)
            Text("Expected if comped: \(currency(expected)) — printed subtotal: \(currency(printed)).")
                .font(.subheadline)
            if !honored {
                Text("Worth mentioning to your server before you sign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background((honored ? Color.green : Color.red).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A service charge/gratuity already baked into the total is easy to
    /// miss on a blank "Tip" line meant for you to fill in by hand — this is
    /// a far more common trap than a one-off comp, and costs nothing extra
    /// to surface since the field is already extracted for every bill.
    @ViewBuilder
    private func gratuityBanner(_ serviceCharge: Double) -> some View {
        Label("A \(currency(serviceCharge)) service charge/gratuity is already included — check before adding another tip.",
              systemImage: "exclamationmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(.blue)
            .padding()
            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func totalsBlock(_ bill: ExtractedBill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let subtotal = bill.subtotal {
                totalRow("Subtotal", subtotal)
            }
            if let tax = bill.tax {
                totalRow("Tax", tax)
            }
            if let service = bill.serviceCharge {
                totalRow("Service / Tip", service)
            }
            if let total = bill.total {
                HStack {
                    Text("Total").font(.system(size: 24 * textScale, weight: .bold))
                    Spacer()
                    Text(currency(total)).font(.system(size: 30 * textScale, weight: .bold, design: .rounded))
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func totalRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label).font(.system(size: 18 * textScale))
            Spacer()
            Text(currency(value)).font(.system(size: 18 * textScale, design: .rounded))
        }
        .foregroundStyle(.secondary)
    }

    /// Standard tipping etiquette bases the tip on the pre-tax subtotal, not
    /// the tax-inclusive total. If anything's marked comped, tip on what was
    /// actually paid for rather than the freebie.
    private func tipBase(_ bill: ExtractedBill) -> Double {
        compedItemIDs.isEmpty ? (bill.subtotal ?? bill.itemsSum) : compedAdjustedItemsSum(bill)
    }

    @ViewBuilder
    private func tipSuggestions(_ bill: ExtractedBill) -> some View {
        let base = tipBase(bill)
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested Tip (on \(currency(base)))")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach([15, 18, 20], id: \.self) { percent in
                    VStack(spacing: 2) {
                        Text("\(percent)%")
                            .font(.system(size: 14 * textScale, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(currency(base * Double(percent) / 100))
                            .font(.system(size: 17 * textScale, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            (Text("For restaurant bills").foregroundColor(.red)
                + Text(" — Check a Bill also works for medical, travel, retail, and other receipts, but tipping obviously doesn't apply there.")
                .foregroundColor(.secondary))
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var textSizeControl: some View {
        HStack {
            Label("Text Size", systemImage: "textformat.size")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                textScale = max(0.8, textScale - 0.15)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            Button {
                textScale = min(2.0, textScale + 0.15)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func actionButtons(_ bill: ExtractedBill) -> some View {
        VStack(spacing: 12) {
            if MFMessageComposeViewController.canSendText() {
                Button {
                    if let phone = QuickSendContactStore.phoneNumber {
                        startMessage(to: phone)
                    } else {
                        showContactPicker = true
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label(quickSendLabel, systemImage: "paperplane.fill")
                            .bold()
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            ShareLink(items: shareImages(for: bill)) { image in
                SharePreview("Bill Breakdown", image: image)
            } label: {
                HStack {
                    Spacer()
                    Label("Share…", systemImage: "square.and.arrow.up")
                    Spacer()
                }
            }
            .buttonStyle(.bordered)

            Button {
                showSaveToReceipts = true
            } label: {
                HStack {
                    Spacer()
                    Text("Save to Receipts")
                    Spacer()
                }
            }
            .buttonStyle(.bordered)

            Button {
                onScanNew()
            } label: {
                HStack {
                    Spacer()
                    Label("Scan a New Bill", systemImage: "camera")
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 8)
    }

    private var quickSendLabel: String {
        if let name = QuickSendContactStore.name {
            return "Send to \(name)"
        }
        return "Send to…"
    }

    /// Attaches both the rendered breakdown and the receipt photo to the
    /// same message — lets the recipient tap through both images in the
    /// thread rather than only seeing a flattened summary. The photo is
    /// cropped to just the receipt when detection is confident, so a
    /// friend/spouse isn't looking at the table/hand/background around it.
    private func startMessage(to phoneNumber: String) {
        guard case .loaded(let bill) = state else { return }
        let vendorLabel = bill.vendor.isEmpty ? "Receipt" : bill.vendor
        var attachments: [(data: Data, filename: String)] = []
        if let breakdownData = renderUIImage(for: bill).jpegData(compressionQuality: 0.9) {
            attachments.append((breakdownData, "Bill – \(vendorLabel).jpg"))
        }
        attachments.append((receiptDataForSharing(), "Original Receipt – \(vendorLabel).jpg"))
        guard !attachments.isEmpty else { return }
        messageAttachments = attachments
        messageRecipients = [phoneNumber]
    }

    /// Renders the breakdown to a shareable image file with fonts baked in,
    /// so formatting survives on the recipient's phone regardless of their
    /// own text-size settings.
    private func renderImage(for bill: ExtractedBill) -> Image {
        Image(uiImage: renderUIImage(for: bill))
    }

    /// Both images for the general share sheet (AirDrop, Mail, etc.) — same
    /// pairing (breakdown + cropped-if-confident receipt photo) as the
    /// quick-send Messages path, so the recipient can flip between them
    /// regardless of which share method was used.
    private func shareImages(for bill: ExtractedBill) -> [Image] {
        var images = [renderImage(for: bill)]
        if let receipt = UIImage(data: receiptDataForSharing()) {
            images.append(Image(uiImage: receipt))
        }
        return images
    }

    /// Crops the receipt out of its background when `ReceiptCropService` is
    /// confident it found the real edges; falls back to the original,
    /// uncropped photo otherwise — never guesses at a crop that might clip
    /// real content (e.g. a long receipt's total near the bottom edge).
    private func receiptDataForSharing() -> Data {
        guard let original = UIImage(data: photoData),
              let cropped = ReceiptCropService.crop(original),
              let jpeg = cropped.jpegData(compressionQuality: 0.9) else {
            return photoData
        }
        return jpeg
    }

    private func renderUIImage(for bill: ExtractedBill) -> UIImage {
        let content = BillShareImageContent(bill: bill)
        let renderer = ImageRenderer(content: content)
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage ?? UIImage()
    }

    private func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

/// A static, self-contained layout used only for rendering the shared image
/// (not shown on screen) — larger fixed sizes since it's read on a different
/// phone, not scaled by this device's text-size control.
private struct BillShareImageContent: View {
    let bill: ExtractedBill

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !bill.vendor.isEmpty {
                Text(bill.vendor).font(.system(size: 26, weight: .bold))
            }
            ForEach(Array(bill.items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top) {
                    Text("\(index + 1).").font(.system(size: 20, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Text(item.name)
                        .font(.system(size: 20, weight: .semibold))
                    if item.quantity > 1 {
                        Text("×\(item.quantity)")
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange, in: Capsule())
                    }
                    Spacer(minLength: 20)
                    Text(String(format: "$%.2f", item.price)).font(.system(size: 20, weight: .semibold, design: .rounded))
                }
            }
            Divider()
            if let total = bill.total {
                HStack {
                    Text("Total").font(.system(size: 24, weight: .bold))
                    Spacer()
                    Text(String(format: "$%.2f", total)).font(.system(size: 30, weight: .bold, design: .rounded))
                }
            }
            if bill.hasArithmeticMismatch {
                Text("⚠ Items total \(String(format: "$%.2f", bill.itemsSum)), bill shows \(String(format: "$%.2f", bill.subtotal ?? bill.total ?? 0))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 400, alignment: .leading)
        .background(Color(.systemBackground))
    }
}

/// Wraps `CNContactPickerViewController` — used once, the first time "Send
/// to…" is tapped, to pick the quick-send recipient. No Contacts permission
/// prompt is needed since the picker runs out-of-process.
private struct ContactPickerView: UIViewControllerRepresentable {
    let onPick: (_ name: String, _ phoneNumber: String) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String, String) -> Void
        init(onPick: @escaping (String, String) -> Void) { self.onPick = onPick }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            guard let phoneNumber = contact.phoneNumbers.first?.value.stringValue else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Contact"
            onPick(name, phoneNumber)
        }
    }
}

/// Wraps `MFMessageComposeViewController` — pre-addressed to the quick-send
/// contact with both the rendered breakdown and the original receipt photo
/// already attached, so the recipient can tap through both in the thread.
/// The user still taps Send themselves; iOS doesn't allow an app to send a
/// message silently.
private struct MessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let attachments: [(data: Data, filename: String)]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        for attachment in attachments {
            controller.addAttachmentData(attachment.data, typeIdentifier: "public.jpeg", filename: attachment.filename)
        }
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                           didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
