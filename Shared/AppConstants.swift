import Foundation

/// Constants shared between the main app and the share extension.
enum AppConstants {
    /// App Group — shares UserDefaults, files, and Keychain items
    /// between the main app and the share extension.
    static let appGroupID = "group.com.dtgincorp.receiptdrop"

    /// Claude model used for receipt extraction. Haiku-class is fast and
    /// cheap and is sufficient for reading receipts. Change here if needed.
    static let claudeModel = "claude-haiku-4-5"

    /// OpenAI model used for receipt extraction — cheapest vision-capable
    /// model as of this writing. Change here if needed.
    static let openAIModel = "gpt-5-mini"

    /// Google Gemini model used for receipt extraction — the current
    /// general-availability Flash model. Change here if needed.
    static let geminiModel = "gemini-3.5-flash"

    /// Keychain account names (stored in the shared App Group keychain).
    enum KeychainKeys {
        static let anthropicAPIKey = "anthropic-api-key"
        static let openAIAPIKey = "openai-api-key"
        static let geminiAPIKey = "gemini-api-key"
    }

    /// UserDefaults (App Group suite) keys.
    enum DefaultsKeys {
        static let categories = "categories"
        static let categoryDescriptions = "categoryDescriptions"
        static let history = "submissionHistory"
        static let retryQueue = "retryQueue"               // failed submissions awaiting retry
        static let extractionProvider = "extractionProvider"
        static let extractionMode = "extractionMode"
        static let lastBackupDate = "lastBackupDate"
        static let backupReminderFrequency = "backupReminderFrequency"
    }

    /// Date format written to the Work_Date column.
    static let sheetDateFormat = "yyyy-MM-dd"

    /// Default categories on first launch.
    static let defaultCategories = ["DTG", "MONTERAS", "HEATHERWOOD"]

    /// CSV header row, written when a category's local log file is first created.
    static let sheetHeader = [
        "Contractor_or_Vendor_Name", "Work_Date", "Amount", "Comments", "Receipt_File", "Scanned_Date",
    ]
}
