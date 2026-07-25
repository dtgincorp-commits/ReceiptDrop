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

    @State private var state: LoadState = .loading
    @State private var textScale: CGFloat = 1
    @State private var showContactPicker = false
    @State private var messageRecipients: [String]?
    @State private var messageAttachment: (data: Data, filename: String)?
    @State private var showSaveToReceipts = false

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
            if let recipients = messageRecipients, let attachment = messageAttachment {
                MessageComposeView(recipients: recipients, imageData: attachment.data, filename: attachment.filename) {
                    messageRecipients = nil
                    messageAttachment = nil
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
    }

    private func load() {
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
                if !bill.vendor.isEmpty {
                    Text(bill.vendor)
                        .font(.title2.bold())
                }

                if bill.hasArithmeticMismatch {
                    mismatchBanner(bill)
                }
                if bill.unreadableLineCount > 0 {
                    unreadableBanner(bill)
                }

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(bill.items.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top) {
                            Text("\(index + 1).")
                                .font(.system(size: 20 * textScale, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .leading)
                            Text(item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name)
                                .font(.system(size: 20 * textScale, weight: .semibold))
                            Spacer()
                            Text(currency(item.price))
                                .font(.system(size: 20 * textScale, weight: .semibold, design: .rounded))
                        }
                    }
                }

                Divider()

                totalsBlock(bill)

                textSizeControl

                actionButtons(bill)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func mismatchBanner(_ bill: ExtractedBill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Items don't add up", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Items total \(currency(bill.itemsSum)), but the bill shows \(currency(bill.subtotal ?? bill.total ?? 0)).")
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

    @ViewBuilder
    private var textSizeControl: some View {
        HStack {
            Text("Text Size").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                textScale = max(0.8, textScale - 0.15)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            Button {
                textScale = min(2.0, textScale + 0.15)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
        }
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

            ShareLink(item: renderImage(for: bill), preview: SharePreview("Bill Breakdown")) {
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
        }
        .padding(.top, 8)
    }

    private var quickSendLabel: String {
        if let name = QuickSendContactStore.name {
            return "Send to \(name)"
        }
        return "Send to…"
    }

    private func startMessage(to phoneNumber: String) {
        guard case .loaded(let bill) = state else { return }
        let image = renderUIImage(for: bill)
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        messageAttachment = (data, "Bill – \(bill.vendor.isEmpty ? "Receipt" : bill.vendor).jpg")
        messageRecipients = [phoneNumber]
    }

    /// Renders the breakdown to a shareable image file with fonts baked in,
    /// so formatting survives on the recipient's phone regardless of their
    /// own text-size settings.
    private func renderImage(for bill: ExtractedBill) -> Image {
        Image(uiImage: renderUIImage(for: bill))
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
                    Text(item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name)
                        .font(.system(size: 20, weight: .semibold))
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
/// contact with the bill image already attached. The user still taps Send
/// themselves; iOS doesn't allow an app to send a message silently.
private struct MessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let imageData: Data
    let filename: String
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.addAttachmentData(imageData, typeIdentifier: "public.jpeg", filename: filename)
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
