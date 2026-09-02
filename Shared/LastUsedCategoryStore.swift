import Foundation

/// Remembers the category the user last filed a receipt under.
///
/// Exists so the share extension can park a receipt without asking. The
/// extension has no UI to ask *in* — that is the point of it — and a receipt
/// still needs a category to be filed, so the app's best guess stands in
/// until the user says otherwise in the app.
///
/// Lives in the App Group's defaults because both processes need it: the main
/// app writes it whenever a receipt is filed, the extension reads it.
enum LastUsedCategoryStore {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
    private static let key = AppConstants.DefaultsKeys.lastUsedCategory

    /// The last category used, or the user's first category if nothing has
    /// been filed yet.
    ///
    /// Falls back through the user's own category list rather than to a
    /// hardcoded name: a user who renamed or deleted the default would
    /// otherwise get receipts filed under a category that no longer exists,
    /// which `LocalReceiptStore` would then recreate as a stray folder.
    static var current: String {
        let categories = CategoryStore.shared.categories
        if let stored = defaults.string(forKey: key), categories.contains(stored) {
            return stored
        }
        return categories.first ?? AppConstants.defaultCategories[0]
    }

    static func record(_ category: String) {
        guard !category.isEmpty else { return }
        defaults.set(category, forKey: key)
    }
}
