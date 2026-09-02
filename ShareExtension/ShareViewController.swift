import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Entry point of the share extension (named in Info.plist as
/// NSExtensionPrincipalClass).
///
/// Deliberately has no interface to speak of. Tapping Receipts4Tax in the
/// share sheet parks every shared photo in the app's waiting area and
/// dismisses — no category picker, no Submit button, no choices. The share
/// sheet icon *is* the button.
///
/// This replaced a full sheet (category picker + Submit, or Save All for a
/// batch, plus a 5-photo ceiling). That flow asked the user to make decisions
/// at the moment they least want to make them — mid-scroll through Photos —
/// and the decisions were nearly always the same ones. Parking first and
/// deciding later in the app inverts that, and as a side effect removes the
/// photo-count limit entirely: nothing here runs the AI, so there is no
/// network round-trip to be killed mid-flight, which is the constraint that
/// forced the old ceiling (SHARE_EXTENSION_MULTI_RECEIPT_PLAN.md).
///
/// What is lost: seeing a single receipt's extraction result immediately, and
/// choosing its category up front. Both are available in the app, and the
/// category defaults to whatever the user last filed under
/// (`LastUsedCategoryStore`), which for a one-category user is always right.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let host = UIHostingController(rootView: ShareConfirmationView())
        // Transparent so the host app stays visible behind the small
        // confirmation — this is a HUD, not a screen.
        host.view.backgroundColor = .clear
        view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)

        Task { await parkEverything() }
    }

    /// Writes every shared image/PDF into the App Group's queue, flagged to
    /// be read overnight, then finishes.
    ///
    /// Every step here is a local file write — no network, no AI — so it
    /// completes in milliseconds and is safe against iOS killing this
    /// short-lived process the moment `completeRequest` is called.
    private func parkEverything() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        let category = LastUsedCategoryStore.current

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let data = await loadData(from: provider, type: UTType.image.identifier) {
                    // Re-encoded to JPEG so the parked bytes match what the
                    // extraction providers are given everywhere else — same
                    // as BatchSubmissionRunner does for the live path.
                    let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
                    SubmissionStore.enqueueHeld(data: jpeg, category: category, kind: .image)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                if let data = await loadData(from: provider, type: UTType.pdf.identifier) {
                    SubmissionStore.enqueueHeld(data: data, category: category, kind: .pdf)
                }
            }
        }

        // Long enough for the confirmation to register as feedback rather
        // than a flicker, short enough not to feel like waiting. Nothing is
        // at stake in this delay — every receipt is already durable on disk
        // by the time it starts.
        try? await Task.sleep(nanoseconds: 700_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func loadData(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// Non-interactive confirmation. No buttons — there is nothing to decide, and
/// the only thing the user needs to know is that it worked.
private struct ShareConfirmationView: View {
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                Text("Saved to Receipts4Tax")
                    .font(.headline)
                Text("It'll be read overnight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
