import UIKit

/// Draws a synthetic, thermal-receipt-style image entirely on-device at
/// runtime — the demo image behind "Try it with a sample receipt" (see
/// TODO.md item 9). Two decisions from that item drove this file:
///
/// 1. No real photo is ever bundled. A coding agent can't produce an actual
///    photograph, and this session's real test receipts carry real (if
///    partially masked) purchase data — shipping one to every install would
///    be a privacy problem, not just an aesthetic one. So this draws one
///    instead, with entirely fabricated vendor/items/amounts that don't
///    resemble any real business.
/// 2. It has to contain real, extractable text. The whole point of the demo
///    is proving the actual OCR/extraction pipeline works, not showing a
///    static mockup — so the text is rendered as real glyphs (Core Text via
///    `UIGraphicsImageRenderer`, not vector shapes standing in for text),
///    high-contrast, and large enough for Vision to read reliably at the
///    rendered resolution.
enum SyntheticReceiptGenerator {
    /// One line-item on the fabricated receipt.
    struct LineItem {
        let name: String
        let price: Double
    }

    /// Portrait, narrow-and-tall — the shape an actual phone photo of a
    /// receipt has, not a square canvas. Rendered at 2x the target point
    /// size so the text is sharp enough for on-device Vision OCR to read
    /// reliably, the same way a real camera photo has far more pixels than
    /// the thumbnail shown on screen.
    private static let pointSize = CGSize(width: 380, height: 820)
    private static let scale: CGFloat = 2

    /// Fabricated small business — a hardware store, chosen for a receipt
    /// shape (several small-dollar line items, one plausible tax rate) that
    /// exercises the same parsing paths a real thermal receipt would.
    static let vendorName = "Riverbend Hardware & Supply"
    private static let vendorAddress = "482 Millbrook Lane, Ashford"
    private static let vendorPhone = "(555) 018-4432"

    static let items: [LineItem] = [
        LineItem(name: "Wood Screws #8 2ct", price: 6.50),
        LineItem(name: "Paint Roller Set", price: 12.99),
        LineItem(name: "Drop Cloth 9x12", price: 8.25),
    ]
    private static let taxRate = 0.07

    static var subtotal: Double { items.reduce(0) { $0 + $1.price } }
    /// Rounded independently to the cent, the same way a real POS system
    /// prints a tax line — not derived by subtracting a rounded total from
    /// a rounded subtotal, which can be off by a cent from what a real
    /// receipt shows.
    static var tax: Double { (subtotal * taxRate * 100).rounded() / 100 }
    static var total: Double { (subtotal * 100).rounded() / 100 + tax }

    /// Renders the demo receipt. `date` defaults to now so the printed date
    /// always looks current — pass a fixed date in tests for a
    /// deterministic assertion.
    static func generateImage(date: Date = Date()) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: pointSize, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            return format
        }())

        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pointSize))

            let margin: CGFloat = 20
            let contentWidth = pointSize.width - margin * 2
            var y: CGFloat = 24

            // Monospace, like an actual thermal-printer font — also what
            // makes the label/price padding below line up visually.
            let mono = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let monoBold = UIFont.monospacedSystemFont(ofSize: 15, weight: .bold)
            let monoSmall = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

            func draw(_ text: String, font: UIFont, centered: Bool = false, y: inout CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
                let attributed = NSAttributedString(string: text, attributes: attrs)
                let size = attributed.size()
                let x = centered ? (pointSize.width - size.width) / 2 : margin
                attributed.draw(at: CGPoint(x: x, y: y))
                y += size.height + 4
            }

            func drawDivider(y: inout CGFloat) {
                let charWidth = mono.pointSize * 0.6
                let dashCount = max(1, Int(contentWidth / charWidth))
                draw(String(repeating: "-", count: dashCount), font: mono, y: &y)
            }

            /// Pads a label/price pair to a fixed character width so the
            /// price lands flush right, the same left-label/right-amount
            /// layout `BillTotalsParser` and `ManualEntryOCRPrefill` are
            /// built to read off a real receipt.
            func moneyLine(_ label: String, _ amount: Double, columns: Int = 30) -> String {
                let priceText = String(format: "%.2f", amount)
                let padding = max(1, columns - label.count - priceText.count)
                return label + String(repeating: " ", count: padding) + priceText
            }

            draw(vendorName, font: monoBold, centered: true, y: &y)
            draw(vendorAddress, font: monoSmall, centered: true, y: &y)
            draw(vendorPhone, font: monoSmall, centered: true, y: &y)
            y += 8
            drawDivider(y: &y)

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MM/dd/yyyy hh:mm a"
            draw("Date: \(dateFormatter.string(from: date))", font: mono, y: &y)
            draw("Register: 2   Cashier: J.M.", font: mono, y: &y)
            drawDivider(y: &y)

            for item in items {
                draw(moneyLine(item.name, item.price), font: mono, y: &y)
            }
            drawDivider(y: &y)

            draw(moneyLine("Subtotal", subtotal), font: mono, y: &y)
            draw(moneyLine("Tax (7%)", tax), font: mono, y: &y)
            y += 4
            draw(moneyLine("TOTAL", total), font: monoBold, y: &y)
            y += 8
            drawDivider(y: &y)

            y += 12
            draw("THANK YOU FOR SHOPPING", font: mono, centered: true, y: &y)
            draw("WITH US!", font: mono, centered: true, y: &y)
        }
    }
}
