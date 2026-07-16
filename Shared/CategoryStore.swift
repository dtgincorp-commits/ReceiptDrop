import Foundation

/// User-editable category list, stored in App Group UserDefaults so the
/// share extension sees edits made in the main app's Settings screen.
final class CategoryStore: ObservableObject {
    static let shared = CategoryStore()

    @Published private(set) var categories: [String]

    private let defaults: UserDefaults

    private init() {
        // Force-unwrap is intentional: a nil suite means the App Group
        // entitlement is misconfigured, which we want to surface loudly.
        defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
        if let saved = defaults.stringArray(forKey: AppConstants.DefaultsKeys.categories),
           !saved.isEmpty {
            categories = saved
        } else {
            categories = AppConstants.defaultCategories
            defaults.set(categories, forKey: AppConstants.DefaultsKeys.categories)
        }
    }

    func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty, !categories.contains(trimmed) else { return }
        categories.append(trimmed)
        persist()
    }

    func remove(at offsets: IndexSet) {
        categories.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        defaults.set(categories, forKey: AppConstants.DefaultsKeys.categories)
    }
}
