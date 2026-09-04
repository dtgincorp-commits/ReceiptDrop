#if DEBUG
import SwiftUI
import UIKit

/// Scores extraction against the hand-verified fixtures in `test-receipts/`,
/// using whichever provider is selected in Settings.
///
/// Switching the AI Provider and running again *is* the comparison — there is
/// no separate code path per provider here, so the numbers cannot drift from
/// what the app actually does. Same arrangement `BillEvalView` uses for
/// itemization.
///
/// Runs the real extraction (`SubmissionPipeline.extractWithFallback`),
/// including the OCR-first attempt and the needs-review retry on the full
/// image. It does not touch anything that saves: no duplicate check, no file
/// write, no CSV append, no history. An eval must never leave a receipt
/// behind.
///
/// DEBUG-only, and the fixtures it reads are copied into the bundle by a
/// Debug-only build phase (see project.yml) — neither ships.
struct ExtractionEvalView: View {
    @State private var truths: [ExtractionEvalHarness.GroundTruth] = []
    @State private var results: [ExtractionEvalHarness.Result] = []
    @State private var isRunning = false
    @State private var progress = ""
    @State private var loadError: String?
    @State private var copied = false

    private var summary: ExtractionEvalHarness.Summary {
        ExtractionEvalHarness.Summary(results: results)
    }

    var body: some View {
        List {
            controlSection
            if !results.isEmpty { scoreSection }
            if !results.isEmpty { detailSection }
        }
        .navigationTitle("Extraction Eval")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadFixtures)
    }

    private var controlSection: some View {
        Section {
            LabeledContent("Provider", value: ExtractionSettings.provider.displayName)
            LabeledContent("Fixtures", value: "\(truths.count)")

            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }

            if isRunning {
                HStack {
                    ProgressView()
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Run Eval") { Task { await run() } }
                    .disabled(truths.isEmpty)
                if !results.isEmpty {
                    Button {
                        UIPasteboard.general.string = report()
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy results",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        } footer: {
            Text("Runs every fixture through the provider selected in Settings, using the app's real extraction path. Nothing is saved. Switch provider and run again to compare.")
        }
    }

    private var scoreSection: some View {
        Section("Score") {
            LabeledContent("Vendor", value: "\(summary.vendorCorrect)/\(summary.count)")
            LabeledContent("Date", value: "\(summary.dateCorrect)/\(summary.count)")
            LabeledContent("Amount", value: "\(summary.amountCorrect)/\(summary.count)")
            LabeledContent("All three", value: "\(summary.allThreeCorrect)/\(summary.count)")
            if summary.errored > 0 {
                LabeledContent("Errored", value: "\(summary.errored)")
                    .foregroundStyle(.red)
            }
            // The guardrails' own score, independent of the model's: of the
            // receipts that came back wrong, how many did the app catch and
            // ask the user to check? A wrong answer that is flagged is a far
            // smaller problem than one that sails into a tax record.
            LabeledContent("Wrong but flagged",
                           value: "\(summary.wrongAndFlagged)/\(summary.wrongTotal)")
            LabeledContent("Average time", value: String(format: "%.1fs", summary.averageSeconds))
        }
    }

    private var detailSection: some View {
        Section("Receipts") {
            ForEach(results, id: \.receiptFile) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(result.receiptFile)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if result.needsReview {
                            Image(systemName: "flag.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let errorMessage = result.errorMessage {
                        Text(errorMessage).font(.caption2).foregroundStyle(.red)
                    } else {
                        fieldRow("vendor", result.vendor)
                        fieldRow("date", result.workDate)
                        fieldRow("amount", result.amount)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func fieldRow(_ name: String, _ score: ExtractionEvalHarness.FieldScore) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: score.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(score.correct ? .green : .red)
            Text(name).font(.caption2).foregroundStyle(.secondary)
            if score.correct {
                Text(score.got).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                // Both values, always: "wrong" is not useful without knowing
                // what it said instead, which is where every diagnosis in
                // this app has actually started.
                Text("\(score.got.isEmpty ? "—" : score.got)  ≠  \(score.expected)")
                    .font(.caption2)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Running

    private func loadFixtures() {
        guard let directory = Bundle.main.url(forResource: "TestReceipts", withExtension: nil) else {
            loadError = "TestReceipts isn't in the bundle. It's copied by a Debug-only build phase — check project.yml, and that this is a Debug build."
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        var rows: [ExtractionEvalHarness.GroundTruth] = []
        for csv in files where csv.lastPathComponent.hasSuffix("_log.csv") {
            guard let text = try? String(contentsOf: csv, encoding: .utf8) else { continue }
            rows.append(contentsOf: ExtractionEvalHarness.groundTruth(fromCSV: text))
        }
        // Only rows whose image actually made it into the bundle — a log row
        // for a missing file would score as a guaranteed failure and quietly
        // drag every provider's number down.
        let present = Set(files.map(\.lastPathComponent))
        truths = rows.filter { present.contains($0.receiptFile) }
        if truths.isEmpty && loadError == nil {
            loadError = "Found no fixture rows with a matching image in the bundle."
        }
    }

    private func run() async {
        isRunning = true
        copied = false
        results = []
        defer { isRunning = false }

        guard let directory = Bundle.main.url(forResource: "TestReceipts", withExtension: nil) else { return }

        for (index, truth) in truths.enumerated() {
            progress = "\(index + 1) of \(truths.count) — \(truth.receiptFile)"
            let url = directory.appendingPathComponent(truth.receiptFile)
            guard let data = try? Data(contentsOf: url) else {
                results.append(.init(receiptFile: truth.receiptFile,
                                     vendor: .init(correct: false, expected: truth.vendor, got: ""),
                                     workDate: .init(correct: false, expected: truth.workDate, got: ""),
                                     amount: .init(correct: false, expected: truth.amount, got: ""),
                                     needsReview: false, reviewReason: "",
                                     errorMessage: "couldn't read file", seconds: 0))
                continue
            }
            let kind: ReceiptKind = truth.receiptFile.lowercased().hasSuffix(".pdf") ? .pdf : .image
            let started = Date()
            do {
                let extracted = try await SubmissionPipeline.extractWithFallback(
                    data: data, kind: kind, categoryContext: "")
                results.append(ExtractionEvalHarness.score(
                    truth: truth, extracted: extracted,
                    seconds: Date().timeIntervalSince(started)))
            } catch {
                results.append(ExtractionEvalHarness.failure(
                    truth: truth, error: error.localizedDescription))
            }
        }
        progress = ""
    }

    private func report() -> String {
        var out = "## Extraction eval — \(ExtractionSettings.provider.displayName)\n\n"
        out += "vendor \(summary.vendorCorrect)/\(summary.count) · "
        out += "date \(summary.dateCorrect)/\(summary.count) · "
        out += "amount \(summary.amountCorrect)/\(summary.count) · "
        out += "all three \(summary.allThreeCorrect)/\(summary.count)\n"
        out += "wrong but flagged \(summary.wrongAndFlagged)/\(summary.wrongTotal) · "
        out += String(format: "avg %.1fs\n\n", summary.averageSeconds)

        out += "| receipt | vendor | date | amount | flagged |\n|---|---|---|---|---|\n"
        for r in results {
            func cell(_ s: ExtractionEvalHarness.FieldScore) -> String {
                s.correct ? "✓" : "✗ \(s.got.isEmpty ? "—" : s.got) (want \(s.expected))"
            }
            let file = r.receiptFile.replacingOccurrences(of: "|", with: "/")
            if let errorMessage = r.errorMessage {
                out += "| \(file) | error: \(errorMessage) | | | |\n"
            } else {
                out += "| \(file) | \(cell(r.vendor)) | \(cell(r.workDate)) | \(cell(r.amount)) "
                out += "| \(r.needsReview ? "yes" : "no") |\n"
            }
        }
        return out
    }
}
#endif
