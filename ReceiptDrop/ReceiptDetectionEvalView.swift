#if DEBUG
import PhotosUI
import SwiftUI
import UIKit
import Vision

/// Phase 0 eval harness for auto-import (see AUTO_IMPORT_RESEARCH.md,
/// "Phase 0 — spike"). Runs `ReceiptPhotoClassifier` over photos picked by
/// hand and reports a confusion matrix, so the one question that gates the
/// whole feature — *is detection good enough to justify asking for the
/// photo-library permission?* — gets a measured answer before a single line
/// of Phase 1 is written.
///
/// Deliberately uses `PhotosPicker`, which runs out of process and needs no
/// `NSPhotoLibraryUsageDescription`. That matters: the point of Phase 0 is to
/// find out whether the permission is worth spending, so Phase 0 itself must
/// not spend it. It also means measurement happens against a real camera roll
/// — ordinary photos of people, pets, menus, whiteboards — rather than against
/// the all-positive fixtures in `test-receipts/`, which cannot show precision.
///
/// Ground truth is entered by tapping each row's Receipt / Not toggle. Nothing
/// is submitted, extracted, saved, or spent; no AI call is made anywhere in
/// this screen.
///
/// DEBUG-only: ships in no TestFlight or App Store build.
struct ReceiptDetectionEvalView: View {
    /// Longest edge the image is scaled to before OCR. The research note's
    /// per-image timing budget (30-80ms) assumes a thumbnail, not a 12MP
    /// original — and in Phase 1 this is what makes the scan viable at all
    /// with "Optimize iPhone Storage", where full-resolution images live in
    /// iCloud and thumbnails are the only thing reliably on device.
    private static let ocrMaxDimension: CGFloat = 1000

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var rows: [Row] = []
    @State private var isRunning = false
    @State private var progress = ""
    @State private var threshold: Double = ReceiptPhotoClassifier.suggestedThreshold
    @State private var copied = false
    @State private var viewing: ViewerPhoto?
    @State private var loadingViewerRow: UUID?

    /// `Data` isn't `Identifiable`, and `.sheet(item:)` wants an identity —
    /// so the row's id rides along as the identity rather than hashing
    /// megabytes of image on every view update.
    private struct ViewerPhoto: Identifiable {
        let id: UUID
        let data: Data
    }

    /// One scored photo plus the verdict a human gave it.
    private struct Row: Identifiable {
        let id = UUID()
        /// Kept so the full-size image can be re-fetched when the row is
        /// tapped. Deliberately NOT holding the decoded original: fifty 12MP
        /// photos held at once is hundreds of megabytes and a jetsam kill on
        /// the very device the eval has to run on. The item is a lightweight
        /// reference; the bytes are loaded only for the one photo being
        /// looked at, and dropped when the viewer closes.
        let item: PhotosPickerItem
        let thumbnail: UIImage?
        let score: Double
        let reason: String
        let milliseconds: Double
        let textPreview: String
        /// nil until tagged — untagged rows are excluded from the matrix
        /// rather than assumed negative, so a half-tagged run reports on what
        /// was actually judged.
        var truth: Truth?
    }

    /// Ground truth, with a third case for a negative that only exists
    /// because this phone belongs to the developer.
    ///
    /// A camera roll full of ReceiptDrop's own screens is not a camera roll
    /// any user has, so scoring those as ordinary false positives understates
    /// the precision a real user would see. Throwing them out entirely
    /// overstates it — a screenshot of *some* receipt app is not impossible,
    /// and screenshots of other apps' payment confirmations are in fact what
    /// several of the tagged positives here are. So they are counted
    /// separately and the report gives precision both ways, rather than
    /// quietly picking one.
    enum Truth: Hashable {
        case receipt
        case notReceipt
        /// Not a receipt, and an artifact of developing this app.
        case devArtifact

        var isReceipt: Bool { self == .receipt }
    }

    var body: some View {
        List {
            pickerSection
            if !rows.isEmpty {
                matrixSection
                resultsSection
            }
        }
        .navigationTitle("Receipt Detection Eval")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItems) { _ in
            guard !pickerItems.isEmpty else { return }
            Task { await run() }
        }
        .sheet(item: $viewing) { photo in
            BillPhotoViewerView(photoData: photo.data, onDone: { viewing = nil })
        }
    }

    private var pickerSection: some View {
        Section {
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: 0,
                         matching: .images) {
                Label("Pick photos to score", systemImage: "photo.stack")
            }
            .disabled(isRunning)

            if isRunning {
                HStack {
                    ProgressView()
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            } else if !rows.isEmpty {
                Button {
                    UIPasteboard.general.string = report()
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy results", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button("Clear", role: .destructive) {
                    rows = []
                    pickerItems = []
                    copied = false
                }
            }
        } footer: {
            Text("Pick a realistic mix: the receipts you'd want found, plus ordinary photos — people, pets, menus, whiteboards, business cards, non-receipt screenshots. Precision can't be measured without those.")
        }
    }

    private var matrixSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Threshold")
                    Spacer()
                    Text(String(format: "%.2f", threshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $threshold, in: 0...1, step: 0.01)
            }

            let stats = Stats(rows: rows, threshold: threshold)
            if stats.tagged == 0 {
                Text("Tag rows Receipt / Not below to score.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Tagged", value: "\(stats.tagged) of \(rows.count)")
                LabeledContent("True positives", value: "\(stats.truePositives)")
                LabeledContent("False positives", value: "\(stats.falsePositives)")
                LabeledContent("False negatives", value: "\(stats.falseNegatives)")
                LabeledContent("True negatives", value: "\(stats.trueNegatives)")
                LabeledContent("Precision", value: stats.precisionText)
                LabeledContent("Recall", value: stats.recallText)
            }
            LabeledContent("Median OCR", value: String(format: "%.0f ms", medianMilliseconds))
        } header: {
            Text("Confusion matrix")
        } footer: {
            Text("Precision is what decides this feature: it's how much of the suggestions tray is junk. Recall only says how many real receipts got missed, and a miss costs nothing the user doesn't already have today.")
        }
    }

    private var resultsSection: some View {
        Section("Scored (\(rows.count))") {
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        if let thumbnail = row.thumbnail {
                            // Tap to open full-screen and pinch-zoom. At 52pt
                            // a thermal receipt and a menu look identical, so
                            // without this the Receipt/Not tag below would be
                            // a guess on the rows that matter most — the
                            // near-misses this eval exists to measure.
                            Button {
                                Task { await openViewer(for: row) }
                            } label: {
                                ZStack {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    if loadingViewerRow == row.id {
                                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.5))
                                            .frame(width: 52, height: 52)
                                        ProgressView().tint(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View photo full screen")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(String(format: "%.2f", row.score))
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(row.score >= threshold ? .green : .secondary)
                                Text(String(format: "%.0f ms", row.milliseconds))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(row.reason.isEmpty ? "no signals" : row.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.textPreview)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                    Picker("Truth", selection: $row.truth) {
                        Text("Receipt").tag(Truth?.some(.receipt))
                        Text("Not").tag(Truth?.some(.notReceipt))
                        Text("Dev").tag(Truth?.some(.devArtifact))
                        Text("—").tag(Truth?.none)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// The whole run as plain text, for pasting somewhere it can be read.
    ///
    /// Includes every row, not just the totals: the per-row score and the
    /// signals behind it are what a weight adjustment is argued from, and a
    /// screenshot of the matrix throws exactly that away. Sweeps the
    /// threshold too, so the precision/recall trade-off is visible as a curve
    /// rather than at whichever value the slider happened to be left on.
    ///
    /// No image data and no OCR text beyond the short preview already on
    /// screen — this is meant to be shareable without handing over the
    /// contents of a camera roll.
    private func report() -> String {
        var out = "## Receipt detection eval\n\n"
        out += "\(rows.count) photos scored, median OCR \(String(format: "%.0f", medianMilliseconds)) ms\n\n"

        let devCount = rows.filter { $0.truth == .devArtifact }.count
        out += sweep(title: devCount > 0 ? "All negatives (incl. \(devCount) dev artifacts)" : "Matrix",
                     excludingDevArtifacts: false)
        if devCount > 0 {
            out += sweep(title: "Excluding dev artifacts — closer to a real user's camera roll",
                         excludingDevArtifacts: true)
        }

        out += "\n| score | tagged | signals | text |\n|---|---|---|---|\n"
        for row in rows.sorted(by: { $0.score > $1.score }) {
            let truth: String
            switch row.truth {
            case .receipt: truth = "receipt"
            case .notReceipt: truth = "not"
            case .devArtifact: truth = "dev"
            case nil: truth = "untagged"
            }
            let preview = row.textPreview
                .replacingOccurrences(of: "|", with: "/")
                .prefix(60)
            out += "| \(String(format: "%.2f", row.score)) | \(truth) "
            out += "| \(row.reason.isEmpty ? "none" : row.reason) | \(preview) |\n"
        }
        return out
    }

    /// One threshold sweep as a markdown table.
    private func sweep(title: String, excludingDevArtifacts: Bool) -> String {
        var out = "**\(title)**\n\n"
        out += "| threshold | precision | recall | TP | FP | FN | TN |\n"
        out += "|---|---|---|---|---|---|---|\n"
        for step in stride(from: 0.2, through: 0.8, by: 0.1) {
            let stats = Stats(rows: rows, threshold: step,
                              excludingDevArtifacts: excludingDevArtifacts)
            guard stats.tagged > 0 else { continue }
            out += "| \(String(format: "%.2f", step)) | \(stats.precisionText) | \(stats.recallText) "
            out += "| \(stats.truePositives) | \(stats.falsePositives) "
            out += "| \(stats.falseNegatives) | \(stats.trueNegatives) |\n"
        }
        return out + "\n"
    }

    /// Loads one photo's full bytes and shows it in the shared zoomable
    /// viewer. May take a moment when the original lives in iCloud rather
    /// than on the device, hence the spinner over the thumbnail.
    private func openViewer(for row: Row) async {
        loadingViewerRow = row.id
        defer { loadingViewerRow = nil }
        guard let data = try? await row.item.loadTransferable(type: Data.self) else { return }
        viewing = ViewerPhoto(id: row.id, data: data)
    }

    private var medianMilliseconds: Double {
        let values = rows.map(\.milliseconds).sorted()
        guard !values.isEmpty else { return 0 }
        return values[values.count / 2]
    }

    /// Scores every picked photo, one at a time so the progress line means
    /// something and the device isn't asked to hold N full-size images at once.
    private func run() async {
        isRunning = true
        copied = false
        defer { isRunning = false }

        let items = pickerItems
        var scored: [Row] = []
        for (index, item) in items.enumerated() {
            progress = "Scoring \(index + 1) of \(items.count)…"
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }

            let downscaled = Self.downscaled(image, maxDimension: Self.ocrMaxDimension)
            let started = Date()
            let text = (try? await Self.fastText(in: downscaled)) ?? ""
            let elapsed = Date().timeIntervalSince(started) * 1000

            let hints = ReceiptPhotoClassifier.AssetHints(
                // PhotosPicker gives no PHAsset, so the screenshot flag isn't
                // available here. Phase 1 reads it from
                // `PHAsset.mediaSubtypes` — until then it's a signal this
                // eval simply doesn't exercise, which the numbers below
                // should be read as excluding.
                isScreenshot: false,
                aspectRatio: image.size.width > 0 ? image.size.height / image.size.width : nil)
            let result = ReceiptPhotoClassifier.classify(text: text, hints: hints)

            scored.append(Row(
                item: item,
                thumbnail: Self.downscaled(image, maxDimension: 160),
                score: result.score,
                reason: result.reason,
                milliseconds: elapsed,
                textPreview: text.replacingOccurrences(of: "\n", with: " ").prefix(120).description))
            rows = scored
        }
        progress = ""
    }

    /// Vision text recognition at `.fast`, which is the level a library sweep
    /// can afford — `VisionOCRService.recognizeText` uses `.accurate` because
    /// it feeds extraction, where a misread digit is a wrong tax record. Here
    /// the output only has to be good enough to spot the word TOTAL.
    private static func fastText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Counts at one threshold. Untagged rows are ignored entirely.
    private struct Stats {
        var truePositives = 0
        var falsePositives = 0
        var trueNegatives = 0
        var falseNegatives = 0

        init(rows: [Row], threshold: Double, excludingDevArtifacts: Bool = false) {
            for row in rows {
                guard let truth = row.truth else { continue }
                if excludingDevArtifacts, truth == .devArtifact { continue }
                let flagged = row.score >= threshold
                switch (truth.isReceipt, flagged) {
                case (true, true): truePositives += 1
                case (false, true): falsePositives += 1
                case (false, false): trueNegatives += 1
                case (true, false): falseNegatives += 1
                }
            }
        }

        var tagged: Int { truePositives + falsePositives + trueNegatives + falseNegatives }

        var precisionText: String {
            let flagged = truePositives + falsePositives
            guard flagged > 0 else { return "—" }
            return String(format: "%.0f%%", 100 * Double(truePositives) / Double(flagged))
        }

        var recallText: String {
            let actual = truePositives + falseNegatives
            guard actual > 0 else { return "—" }
            return String(format: "%.0f%%", 100 * Double(truePositives) / Double(actual))
        }
    }
}
#endif
