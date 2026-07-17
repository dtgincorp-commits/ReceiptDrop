import Foundation

/// User-editable category list, stored in App Group UserDefaults so the
/// share extension sees edits made in the main app's Settings screen.
final class CategoryStore: ObservableObject {
    static let shared = CategoryStore()

    @Published private(set) var categories: [String]
    /// User-written description of what each category is for (e.g. "DTG:
    /// expenses for my IT company"), keyed by category name. Fed into the
    /// extraction prompt as `categoryContext` so the model has real signal
    /// for judging whether a receipt looks like it belongs and for writing
    /// better Comments. Categories with no description simply aren't present
    /// in this dictionary.
    @Published private(set) var descriptions: [String: String]

    private let defaults: UserDefaults

    private init() {
        // Force-unwrap is intentional: a nil suite means the App Group
        // entitlement is misconfigured, which we want to surface loudly.
        let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
        let savedCategories = defaults.stringArray(forKey: AppConstants.DefaultsKeys.categories)
        let resolvedCategories = (savedCategories?.isEmpty == false) ? savedCategories! : AppConstants.defaultCategories
        self.defaults = defaults
        categories = resolvedCategories
        descriptions = (defaults.dictionary(forKey: AppConstants.DefaultsKeys.categoryDescriptions) as? [String: String]) ?? [:]
        if savedCategories?.isEmpty != false {
            defaults.set(resolvedCategories, forKey: AppConstants.DefaultsKeys.categories)
        }
    }

    func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty, !categories.contains(trimmed) else { return }
        categories.append(trimmed)
        persist()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets { descriptions.removeValue(forKey: categories[index]) }
        categories.remove(atOffsets: offsets)
        persist()
        persistDescriptions()
    }

    func description(for category: String) -> String {
        descriptions[category] ?? ""
    }

    func setDescription(_ text: String, for category: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            descriptions.removeValue(forKey: category)
        } else {
            descriptions[category] = trimmed
        }
        persistDescriptions()
    }

    private func persist() {
        defaults.set(categories, forKey: AppConstants.DefaultsKeys.categories)
    }

    private func persistDescriptions() {
        defaults.set(descriptions, forKey: AppConstants.DefaultsKeys.categoryDescriptions)
    }
}
