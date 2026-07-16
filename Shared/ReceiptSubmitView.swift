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

    /// Drives the Submit section's UI while the pipeline runs.
    private enum SubmitState: Equatable {
        case idle
        case running
        case success
        case queued
    }

    private var controlsDisabled: Bool {
        if case .idle = submitState { return false }
        return true
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
            .disabled(selectedCategory.isEmpty)
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
        statusText = SubmissionPipeline.Stage.reading.statusText

        Task {
            do {
                _ = try await SubmissionPipeline().run(data: data, kind: kind, category: category) { stage in
                    statusText = stage.statusText
                }
                submitState = .success
                try? await Task.sleep(nanoseconds: 800_000_000)
                onComplete()
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
}

/// Renders a PDF's first page as a thumbnail image, used by both the extension's
/// NSItemProvider loading and any future in-app PDF source.
func pdfThumbnail(_ data: Data) -> UIImage? {
    guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
    return page.thumbnail(of: CGSize(width: 400, height: 520), for: .mediaBox)
}
