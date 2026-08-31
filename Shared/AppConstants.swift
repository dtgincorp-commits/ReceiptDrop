import Foundation

/// Constants shared between the main app and the share extension.
enum AppConstants {
    /// App Group — shares UserDefaults, files, and Keychain items
    /// between the main app and the share extension.
    static let appGroupID = "group.com.datatechnologygroup.receipts4tax"

    /// Custom URL scheme the main app registers (see ReceiptDrop/Info.plist's
    /// CFBundleURLTypes) so the share extension has a way back to it. A
    /// share-extension process has no `UIApplication.shared` and so can't call
    /// `.open(_:)` directly — `extensionContext?.open(_:completionHandler:)`
    /// with this scheme is the sandbox-safe equivalent. No path/query is ever
    /// read on the receiving end today; this just launches the app to its
    /// normal entry point (see ReceiptDropApp's `onOpenURL`).
    static let urlScheme = "receiptdrop"

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
        static let appCurrency = "appCurrency"                  // display currency; see AppCurrency
    }

    /// Date format written to the Work_Date column.
    static let sheetDateFormat = "yyyy-MM-dd"

    /// Default categories on first launch — a real, generically-useful
    /// bucket a brand-new user can file an actual receipt into immediately,
    /// not demo/placeholder data (a prior seed of "SAMPLE CATEGORY" read as
    /// leftover test data rather than something the app was ready for real
    /// use with). Still just a starting point to rename/replace via Manage
    /// Categories. Uppercase to match `CategoryStore.add`'s own convention —
    /// every other category the app ever creates goes through `add`, which
    /// uppercases; this constant is seeded directly instead, so it must
    /// already be uppercase or a restored backup could end up with both the
    /// lowercase-ish and uppercase spellings as separate entries (exactly
    /// what happened with the old "Sample Category" / "SAMPLE CATEGORY"
    /// pair — see `CategoryStore.add` and `bfcac55`).
    static let defaultCategories = ["BUSINESS EXPENSES"]

    /// Whether the "Check a Bill" itemization feature is reachable at all.
    ///
    /// Off for 1.0. The feature works, but not reliably enough on real bills
    /// to put in front of people who did not choose to be testing it — and a
    /// visibly unfinished feature is also a rejection risk under App Review
    /// guideline 2.1. Hiding the entry point is the same remedy
    /// `ExtractionProvider.supportsBillItemization` already applies to Apple
    /// On-Device, just applied to every provider rather than one.
    ///
    /// Deliberately a flag rather than deleting the ~2,400 lines behind it.
    /// The open question is *why* itemization is wrong — a model that cannot
    /// itemize a real restaurant bill, or a prompt and parser that need work
    /// — and `BillEvalHarness` exists to answer exactly that against the
    /// fixtures in `test-receipts/`. Deleting now would throw away both the
    /// feature and the instrument that would tell us whether it is
    /// salvageable. Flip this to `true` to bring it back; nothing else needs
    /// to change.
    ///
    /// The cost of keeping it: the code still compiles, still ships in the
    /// binary, and still has to keep building. That is the price of leaving
    /// the decision open, and it is deliberate — this is not dead code, and
    /// it should not be deleted as such.
    static let billItemizationEnabled = false

    /// CSV header row, written when a category's local log file is first created.
    static let sheetHeader = [
        "Contractor_or_Vendor_Name", "Work_Date", "Amount", "Comments", "Receipt_File", "Scanned_Date",
    ]
}
