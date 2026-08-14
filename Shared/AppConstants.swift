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

    /// Perplexity model used for receipt extraction — their general-purpose
    /// multimodal Sonar model. Change here if needed.
    static let perplexityModel = "sonar-pro"

    /// Azure AI Document Intelligence model used for receipt/bill extraction
    /// — the prebuilt receipt model (fixed schema, not a chat model, so
    /// there's no "which model" choice the way there is for the others).
    static let azureDocIntelModel = "prebuilt-receipt"
    static let azureDocIntelAPIVersion = "2024-11-30"

    /// Keychain account names (stored in the shared App Group keychain).
    enum KeychainKeys {
        static let anthropicAPIKey = "anthropic-api-key"
        static let openAIAPIKey = "openai-api-key"
        static let geminiAPIKey = "gemini-api-key"
        static let perplexityAPIKey = "perplexity-api-key"
        static let azureDocIntelKey = "azure-docintel-api-key"
        static let azureDocIntelEndpoint = "azure-docintel-endpoint"
    }

    /// UserDefaults (App Group suite) keys.
    enum DefaultsKeys {
        static let categories = "categories"
        static let categoryDescriptions = "categoryDescriptions"
        static let history = "submissionHistory"
        static let retryQueue = "retryQueue"               // failed submissions awaiting retry
        static let extractionProvider = "extractionProvider"
        static let extractionMode = "extractionMode"
        static let offlineOnly = "offlineOnly"                 // block cloud providers; on-device only
        static let lastBackupDate = "lastBackupDate"
        static let backupReminderFrequency = "backupReminderFrequency"
        static let hasCompletedAISetup = "hasCompletedAISetup"  // guided Connect-AI wizard shown/skipped
        static let appTextSize = "appTextSize"                  // per-app text size override; see AppTextSize
    }

    /// Date format written to the Work_Date column.
    static let sheetDateFormat = "yyyy-MM-dd"

    /// Default categories on first launch — a placeholder for a brand-new
    /// user to rename/replace via Manage Categories, not real business names.
    /// Uppercase to match `CategoryStore.add`'s own convention — every other
    /// category the app ever creates goes through `add`, which uppercases;
    /// this one didn't, which is how a restored backup could end up with
    /// both "Sample Category" and "SAMPLE CATEGORY" as separate entries.
    static let defaultCategories = ["SAMPLE CATEGORY"]

    /// CSV header row, written when a category's local log file is first created.
    static let sheetHeader = [
        "Contractor_or_Vendor_Name", "Work_Date", "Amount", "Comments", "Receipt_File", "Scanned_Date",
    ]
}
