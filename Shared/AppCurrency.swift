import Foundation

/// User-selectable *display* currency — purely cosmetic. It changes the
/// symbol shown next to amount fields and the summary total's formatting;
/// it does not convert between currencies, does not touch what's stored
/// (`HistoryEntry.amount` stays a plain "342.39" string forever), and has
/// nothing to do with `ReceiptAmountDetector`'s parsing, which must work the
/// same regardless of this setting — see that file's header comment for why.
///
/// Foundation-only (no `SwiftUI` import) for the same reason as
/// `AppTextSize`: this type is compiled into the share extension too.
enum AppCurrency: String, CaseIterable, Identifiable {
    case auto, usd, eur, gbp, inr, cad, aud, jpy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .usd: return "US Dollar ($)"
        case .eur: return "Euro (€)"
        case .gbp: return "British Pound (£)"
        case .inr: return "Indian Rupee (₹)"
        case .cad: return "Canadian Dollar (CA$)"
        case .aud: return "Australian Dollar (A$)"
        case .jpy: return "Japanese Yen (¥)"
        }
    }

    /// Hardcoded per case rather than looked up from `currencyCode` via
    /// `Locale` — a fixed symbol is predictable no matter what region the
    /// device happens to be set to, which matters for `.auto` where we fall
    /// back to the device's own currency symbol below.
    var symbol: String {
        switch self {
        case .auto: return Locale.current.currencySymbol ?? "$"
        case .usd: return "$"
        case .eur: return "€"
        case .gbp: return "£"
        case .inr: return "₹"
        case .cad: return "CA$"
        case .aud: return "A$"
        case .jpy: return "¥"
        }
    }

    /// `nil` for `.auto` — leaves `NumberFormatter.currencyCode` at its
    /// default so it keeps following the device's region, same as today.
    var currencyCode: String? {
        self == .auto ? nil : rawValue.uppercased()
    }

    /// Every symbol any case above can render, for stripping a currency
    /// prefix before parsing a number — used by `ReceiptAmountDetector`,
    /// `FoundationModelsService`, and `ReceiptsView`'s search-query parser
    /// so all three recognize the same set instead of each hardcoding "$".
    /// Independent of the user's selected `AppCurrency`: a receipt or query
    /// can carry a symbol that has nothing to do with the display setting.
    private static let knownSymbols: [String] = ["$", "€", "£", "₹", "¥"]

    static func stripKnownSymbols(from text: String) -> String {
        var result = text
        for symbol in knownSymbols {
            result = result.replacingOccurrences(of: symbol, with: "")
        }
        return result
    }
}
