#if DEBUG && targetEnvironment(simulator)
import UIKit

/// Fills the app with fictional receipts for App Store screenshots, when
/// launched with `-ScreenshotDemoData` (see ReceiptDropUITests).
///
/// Compiled only into DEBUG builds for the Simulator, so it can never run on
/// a real device or ship: it **erases** this install's receipts and settings
/// before writing the demo set. Every vendor is made up — real receipts carry
/// real names and payments, and screenshots are public.
enum ScreenshotDemoData {
    static let launchArgument = "-ScreenshotDemoData"

    private struct Demo {
        let category, vendor: String
        let daysAgo: Int
        let amount, type: String
        var flagged: String? = nil
        var withPhoto = false
    }

    private static let receipts: [Demo] = [
        Demo(category: "HOME OFFICE", vendor: SyntheticReceiptGenerator.vendorName, daysAgo: 1,
             // The photo's own printed total, so the row and the photo agree.
             amount: String(format: "%.2f", SyntheticReceiptGenerator.total), type: "hardware_home_improvement", withPhoto: true),
        Demo(category: "CLIENT MEALS", vendor: "Harbor Lane Bistro", daysAgo: 2, amount: "142.60", type: "restaurant"),
        Demo(category: "VEHICLE", vendor: "Northgate Fuel Stop", daysAgo: 4, amount: "58.12", type: "gas_station"),
        Demo(category: "TRAVEL", vendor: "Summit Ridge Hotel", daysAgo: 6, amount: "389.00", type: "lodging"),
        Demo(category: "CLIENT MEALS", vendor: "Copper Kettle Café", daysAgo: 8, amount: "23.85", type: "restaurant"),
        Demo(category: "HOME OFFICE", vendor: "Brightline Office Supply", daysAgo: 11, amount: "64.30", type: "retail",
             flagged: "Amount $64.30 isn't printed on this receipt — please check it."),
        Demo(category: "VEHICLE", vendor: "Precision Auto Care", daysAgo: 15, amount: "412.75", type: "auto_repair"),
        Demo(category: "TRAVEL", vendor: "Bayview Airport Parking", daysAgo: 19, amount: "72.00", type: "other"),
        Demo(category: "HOME OFFICE", vendor: "Clearwave Internet", daysAgo: 24, amount: "79.99", type: "utilities"),
        Demo(category: "CLIENT MEALS", vendor: "Olive & Ember Grill", daysAgo: 31, amount: "118.40", type: "restaurant"),
        Demo(category: "VEHICLE", vendor: "Northgate Fuel Stop", daysAgo: 38, amount: "61.48", type: "gas_station"),
        Demo(category: "TRAVEL", vendor: "Meridian Rail", daysAgo: 45, amount: "96.20", type: "other"),
        Demo(category: "HOME OFFICE", vendor: "Tidewater Print & Ship", daysAgo: 52, amount: "37.15", type: "retail"),
        Demo(category: "PROFESSIONAL", vendor: "Hollis & Grant CPA", daysAgo: 60, amount: "650.00", type: "professional_services"),
        Demo(category: "CLIENT MEALS", vendor: "Juniper Street Deli", daysAgo: 67, amount: "31.90", type: "restaurant"),
    ]

    static func installIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
        for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? fm.removeItem(at: docs.appendingPathComponent("Receipts"))
        }
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID) {
            try? fm.removeItem(at: group.appendingPathComponent("Receipts"))
        }

        let categories = ["HOME OFFICE", "CLIENT MEALS", "VEHICLE", "TRAVEL", "PROFESSIONAL"]
        defaults.set(categories, forKey: AppConstants.DefaultsKeys.categories)
        defaults.set(true, forKey: AppConstants.DefaultsKeys.hasCompletedAISetup)
        defaults.set(true, forKey: AppConstants.DefaultsKeys.hasSeenPhotoPickerTip)
        defaults.set("appleOnDevice", forKey: AppConstants.DefaultsKeys.extractionProvider)
        // A new customer on the free tier, not a grandfathered early user.
        defaults.set(false, forKey: AppConstants.DefaultsKeys.subscriptionGrandfathered)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        // Oldest first: appendHistory inserts at the front.
        for demo in receipts.reversed() {
            let date = Calendar.current.date(byAdding: .day, value: -demo.daysAgo, to: Date())!
            var link = SubmissionPipeline.manualEntryLabel
            if demo.withPhoto,
               let jpeg = SyntheticReceiptGenerator.generateImage(date: date).jpegData(compressionQuality: 0.9),
               let saved = try? LocalReceiptStore.save(data: jpeg, category: demo.category, kind: .image) {
                link = saved
            }
            try? LocalReceiptStore.appendLog(vendor: demo.vendor, workDate: formatter.string(from: date),
                                             amount: demo.amount, comments: "", receiptFilename: link,
                                             category: demo.category)
            SubmissionStore.appendHistory(HistoryEntry(
                category: demo.category, vendor: demo.vendor, workDate: formatter.string(from: date),
                amount: demo.amount, receiptLink: link, timestamp: date,
                verificationStatus: demo.flagged == nil ? .verified : .needsReview,
                reviewReason: demo.flagged ?? "", vendorType: demo.type))
        }
    }
}
#endif
