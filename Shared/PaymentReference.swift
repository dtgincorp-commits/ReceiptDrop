import Foundation

/// Payment reference numbers ("REF #PP0YHCL3XF", "Transaction ID 9KD…",
/// "Confirmation #…") read off receipt images, used to settle a suspected
/// duplicate: two receipts sharing a reference are the same payment, two
/// with only different references are different payments, whatever their
/// names, dates or amounts suggest.
///
/// Deliberately never stored. The reference is already in the saved photo,
/// so it is read from there when needed — and it is only needed once some
/// other rule already suspects a duplicate, which keeps the OCR rare.
///
/// A set, not one value: a single Zelle or Venmo screenshot often shows
/// several payments (the motivating one listed $210 REF #PP0YHCL3XF and
/// $200 REF #PP0YGMK3V2 together).
enum PaymentReference {
    enum Verdict: Equatable {
        /// At least one reference appears on both receipts.
        case samePayment(String)
        /// Both receipts carry references, and none are shared.
        case differentPayments
        /// One or both receipts show no reference — nothing to conclude.
        case unknown
    }

    /// "Different payments" hides a suspected duplicate, so it is only
    /// concluded when every pair of references differs by more than OCR
    /// noise could explain. References a character or two apart are most
    /// likely one reference read two ways — that stays `.unknown`, and the
    /// ordinary duplicate warning still shows.
    static func compare(_ a: Set<String>, _ b: Set<String>) -> Verdict {
        guard !a.isEmpty, !b.isEmpty else { return .unknown }
        if let shared = a.intersection(b).sorted().first { return .samePayment(shared) }
        let nearMiss = a.contains { x in b.contains { y in editDistance(x, y) <= maxOCRNoise } }
        return nearMiss ? .unknown : .differentPayments
    }

    /// Characters Vision misreads apart from those OCR confuses outright
    /// (handled in `canonical`). Real references are ~10 random characters,
    /// so two genuinely different ones essentially never land this close.
    private static let maxOCRNoise = 2

    /// Uppercased, with the look-alikes Vision actually confuses folded
    /// together: on a real Zelle screenshot it read REF #PP0YHCL3XF as
    /// "PPOYHCL3XF". Folding toward the digit keeps the displayed reference
    /// right in that common case.
    private static func canonical(_ raw: String) -> String {
        String(raw.uppercased().map { $0 == "O" ? "0" : $0 == "I" ? "1" : $0 })
    }

    /// Levenshtein distance: single-character insertions, deletions and
    /// substitutions needed to turn one reference into the other.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, charA) in a.enumerated() {
            var current = [i + 1]
            for (j, charB) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1,
                                   previous[j] + (charA == charB ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// A label (REF, Reference, Confirmation, Transaction/Payment/Txn ID),
    /// an optional "No."/"Number"/"Code", an optional "#" or ":", then the
    /// value. Group 1 is that punctuation, group 2 the value.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(?:ref(?:erence)?|confirmation|conf|(?:transaction|payment|txn)\s*id)\b\s*(?:no\.?|number|code)?\s*([:#])?\s*([A-Za-z0-9][A-Za-z0-9-]{5,})"#,
        options: [.caseInsensitive])

    /// A value counts as a reference when, as printed, it either contains a
    /// digit or follows "#" and is all capitals and at least 8 long. That
    /// keeps ordinary words after a label ("Reference Number Application")
    /// out, while still catching a Zelle reference whose only digit Vision
    /// misread: "REF #RP0YDBQJNY" came back as "RPOYDBQJNY", no digit left.
    /// Tested on the text as printed, before `canonical` folds O/I into
    /// digits — folded first, "APPLICATION" would read as "APPL1CAT10N".
    static func find(in text: String) -> Set<String> {
        var found = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let printed = String(text[valueRange])
            let afterHash = Range(match.range(at: 1), in: text).map { text[$0] == "#" } ?? false
            let hasDigit = printed.contains(where: \.isNumber)
            let looksLikeACode = afterHash && printed.count >= 8 && printed == printed.uppercased()
            guard hasDigit || looksLikeACode else { continue }
            found.insert(canonical(printed))
        }
        return found
    }

    /// References on a receipt image that hasn't been saved yet. PDFs are
    /// skipped — payment-app receipts arrive as screenshots.
    static func read(from data: Data, kind: ReceiptKind) async -> Set<String> {
        guard kind == .image, let text = try? await VisionOCRService.recognizeText(in: data) else { return [] }
        return find(in: text)
    }

    /// References on a saved receipt's photo. Cached in memory for the
    /// life of the process — the same suspected pair is re-checked on
    /// every reload of the Receipts list, and a stored photo never changes
    /// under the same filename.
    static func read(for entry: HistoryEntry) async -> Set<String> {
        let key = "\(entry.category)/\(entry.receiptLink)"
        if let cached = await cache.value(for: key) { return cached }
        guard !SubmissionPipeline.isPlaceholderLabel(entry.receiptLink),
              let url = LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink),
              ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url) else { return [] }
        let references = await read(from: data, kind: .image)
        await cache.set(references, for: key)
        return references
    }

    /// Drops suspected-duplicate groups whose receipts are provably
    /// different payments. Only two-entry fuzzy groups are checked: an
    /// identical-file group is the same photo, so its references can only
    /// agree.
    static func excludingDifferentPayments(_ groups: [DuplicateDetectionService.Group]) async -> [DuplicateDetectionService.Group] {
        var kept: [DuplicateDetectionService.Group] = []
        for group in groups {
            guard group.confidence != .identicalFile, group.entries.count == 2 else {
                kept.append(group)
                continue
            }
            let a = await read(for: group.entries[0])
            let b = await read(for: group.entries[1])
            if compare(a, b) != .differentPayments { kept.append(group) }
        }
        return kept
    }

    private actor Cache {
        private var storage: [String: Set<String>] = [:]
        func value(for key: String) -> Set<String>? { storage[key] }
        func set(_ value: Set<String>, for key: String) { storage[key] = value }
    }
    private static let cache = Cache()
}
