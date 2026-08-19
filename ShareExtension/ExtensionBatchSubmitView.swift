import SwiftUI
import UIKit

/// The share extension's flow for more than one photo/PDF at once. This is
/// deliberately NOT `Shared/BatchReceiptSubmitView` reused as-is: that view's
/// `submitAll()` starts `BatchSubmissionRunner` (which calls
/// `SubmissionPipeline`, i.e. the Claude round-trip) on a detached task,
/// waits ~700ms, then calls `onComplete()`. That's safe in the main app,
/// which stays alive for as long as the batch takes. It is NOT safe here:
/// `onComplete()` reaches `extensionContext?.completeRequest`
/// (`ShareViewController.swift`), and iOS is free to suspend or kill this
/// extension process once that's called — an in-flight AI extraction call
/// for photo 3 of 5 would simply vanish, with nothing saved and no error
/// shown. See SHARE_EXTENSION_MULTI_RECEIPT_PLAN.md, "The critical
/// constraint", for the full writeup.
///
/// So this view does the only thing that's safe within an extension's short,
/// unreliable lifetime: durably park every photo's bytes — a fast, local,
/// no-network file write via `SubmissionStore.enqueuePending` — and let the
/// main app run them through `SubmissionPipeline` on next launch/foreground
/// (`PendingSubmissionProcessor`), the same way it already processes a
/// queued retry. Nothing here waits on the network, so it's safe to call
/// `onComplete()` right after the writes finish.
struct ExtensionBatchSubmitView: View {
    /// The "please keep batches reasonable" guidance shown once the
    /// extension has actually launched and can render UI — separate from
    /// project.yml's much higher NSExtensionActivationRule MaxCount, which
    /// only controls whether iOS offers ReceiptDrop in the share sheet at
    /// all. Using one number for both would just move the original
    /// silent-disappearance bug from 1 photo to this number.
    static let friendlyLimit = 5

    let attachments: [SharedAttachment]
    let onCancel: () -> Void
    let onComplete: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var selectedCategory: String = ""
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case saved
    }

    var body: some View {
        NavigationStack {
            Group {
                if attachments.count > Self.friendlyLimit {
                    tooManyView
                } else {
                    Form {
                        Section {
                            HStack {
                                Spacer()
                                Text("\(attachments.count) receipts selected")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        } footer: {
                            Text("These will be saved now and read automatically the next time you open ReceiptDrop.")
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
    private var tooManyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("You selected \(attachments.count) receipts — please pick \(Self.friendlyLimit) or fewer at a time.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            Button {
                saveAll()
            } label: {
                HStack { Spacer(); Text("Save All").bold(); Spacer() }
            }
            .disabled(selectedCategory.isEmpty)
        case .saved:
            HStack {
                Spacer()
                Label("\(attachments.count) receipts saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
            }
        }
    }

    /// Writes every attachment to the App Group's pending queue synchronously
    /// (fast local file writes, no network) before doing anything that could
    /// end this view's lifetime — by the time `phase` flips to `.saved`,
    /// every photo is already durable, so the brief confirmation delay below
    /// is purely cosmetic, not something the data's safety depends on.
    private func saveAll() {
        let category = selectedCategory
        for attachment in attachments {
            let kind: ReceiptKind = attachment.kind == .image ? .image : .pdf
            // Re-encode images to JPEG so the parked bytes match what
            // SubmissionPipeline/Claude expect later, same as
            // BatchSubmissionRunner and ReceiptSubmitView do for the
            // live-extraction paths.
            let data: Data
            if attachment.kind == .image, let jpeg = UIImage(data: attachment.data)?.jpegData(compressionQuality: 0.85) {
                data = jpeg
            } else {
                data = attachment.data
            }
            SubmissionStore.enqueuePending(data: data, category: category, kind: kind)
        }
        phase = .saved
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            onComplete()
        }
    }
}
