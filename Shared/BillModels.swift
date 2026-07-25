import Foundation

/// One line item read off a bill. `price` is the line's printed total (already
/// reflecting quantity), not a per-unit price — that's what's actually printed
/// on the receipt and avoids a multiplication step that could introduce error.
struct BillItem: Identifiable {
    let id = UUID()
    let name: String
    let quantity: Int
    let price: Double
}

/// Result of itemizing a bill photo for "Check a Bill" — a separate, ephemeral
/// path from `ExtractedReceipt`/the permanent archive. Built from raw
/// AI-returned strings the same way `ExtractedReceipt.build` is, so every
/// provider's response goes through one parsing/validation point.
struct ExtractedBill {
    let vendor: String
    let items: [BillItem]
    let subtotal: Double?
    let tax: Double?
    let serviceCharge: Double?
    let total: Double?
    /// How many lines the model couldn't confidently read — surfaced to the
    /// user rather than silently guessing or omitting them, matching the
    /// app's existing HITL honesty rule. Never invent a line item.
    let unreadableLineCount: Int

    /// Sum of the line items actually read — compared locally against the
    /// printed subtotal/total below. Zero AI cost, catches padded bills even
    /// when every individual line looks plausible on its own.
    var itemsSum: Double {
        items.reduce(0) { $0 + $1.price }
    }

    /// Prefer comparing against the subtotal (pre-tax/tip) since that's what
    /// line items should equal; falls back to the grand total if no subtotal
    /// was printed.
    private var arithmeticTarget: Double? { subtotal ?? total }

    /// True if the items don't add up to the printed subtotal/total, beyond a
    /// small rounding tolerance. Only checked when there's something to check
    /// against — an empty item list or missing totals isn't a "mismatch".
    var hasArithmeticMismatch: Bool {
        guard !items.isEmpty, let target = arithmeticTarget else { return false }
        return abs(itemsSum - target) > 0.05
    }

    static func build(vendor: String, rawItems: [(name: String, quantity: String, price: String)],
                       subtotal: String, tax: String, serviceCharge: String, total: String,
                       unreadableLineCount: String) -> ExtractedBill {
        let items = rawItems.compactMap { raw -> BillItem? in
            let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let price = Double(raw.price.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            let quantity = Int(raw.quantity.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
            return BillItem(name: name, quantity: max(quantity, 1), price: price)
        }
        return ExtractedBill(
            vendor: vendor.trimmingCharacters(in: .whitespacesAndNewlines),
            items: items,
            subtotal: Double(subtotal.trimmingCharacters(in: .whitespacesAndNewlines)),
            tax: Double(tax.trimmingCharacters(in: .whitespacesAndNewlines)),
            serviceCharge: Double(serviceCharge.trimmingCharacters(in: .whitespacesAndNewlines)),
            total: Double(total.trimmingCharacters(in: .whitespacesAndNewlines)),
            unreadableLineCount: Int(unreadableLineCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }
}
