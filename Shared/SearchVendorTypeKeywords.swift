import Foundation

/// A small, deliberately narrow keyword fallback for a search query's
/// `vendorType` — used only by `SemanticSearchService.finalize` to fill in a
/// type the model left nil. It never overrides a type the model did return
/// (that is a semantic judgment call the model is generally good at — see
/// `SearchVendorTypeGuard`'s own comment on why only "other" gets a lexical
/// check) and it never reinstates a type that guard just rejected, because
/// the call site only reaches this once `vendorType` is still nil.
///
/// This exists because vendor-type classification is otherwise entirely
/// model-dependent, and on Apple's on-device model that dependency shows: a
/// query as plain as "show me all grocery receipts" came back with no
/// vendorType often enough that a deterministic net for the obvious cases
/// was worth having. It is intentionally small and lexical, not a second
/// taxonomy — anything requiring real judgment ("dinner receipts" ->
/// restaurant, "filled up the truck" -> gas_station) stays with the model,
/// which already handles those correctly; this only catches the literal
/// cases a prompt can drop under load.
enum SearchVendorTypeKeywords {

    /// Exact multi-word phrases, checked first since they name a single
    /// concept ("gas station", "home improvement") that a per-word match
    /// below would otherwise catch through their individual words anyway —
    /// spelling them out here just documents the phrase explicitly.
    private static let phrases: [(phrase: String, type: VendorType)] = [
        ("home improvement", .hardwareHomeImprovement),
        ("hardware store", .hardwareHomeImprovement),
        ("gas station", .gasStation),
        ("medical expenses", .medical),
    ]

    /// Single words, matched whole-word only — the same rule
    /// `SearchVendorTypeGuard` applies and for the same reason: "carpet"
    /// must never license "car".
    private static let wordsByType: [(words: Set<String>, type: VendorType)] = [
        (["restaurant", "restaurants", "dining", "diner", "cafe", "coffee"], .restaurant),
        (["grocery", "groceries", "supermarket"], .grocery),
        (["gas", "fuel", "petrol"], .gasStation),
        (["hardware"], .hardwareHomeImprovement),
        (["medical", "doctor", "dentist", "pharmacy"], .medical),
        (["hotel", "motel", "lodging"], .lodging),
    ]

    /// The first matching vendor type's raw value, or nil if the query
    /// contains none of the recognized words.
    static func match(in query: String) -> String? {
        let lowered = query.lowercased()
        for (phrase, type) in phrases where lowered.contains(phrase) {
            return type.rawValue
        }

        let words = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        for (candidates, type) in wordsByType where !candidates.isDisjoint(with: words) {
            return type.rawValue
        }
        return nil
    }
}
