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

    /// Returns whether `name` was actually added — `false` for an empty name
    /// or one that already exists (case-insensitively). Restore and other
    /// bulk callers rely on that being a silent no-op rather than an error
    /// (re-adding an already-present category on every restore is normal,
    /// expected behavior, not something to surface); the interactive "Add
    /// Category" UI is the one place the return value matters, so it can
    /// show "already exists" instead of silently clearing the text field as
    /// if the category had been created.
    @discardableResult
    func add(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Case-insensitive on purpose: `trimmed` is always uppercase, but
        // existing entries aren't guaranteed to be — the hardcoded
        // `AppConstants.defaultCategories` seed ("Sample Category") never
        // goes through this uppercasing, so a case-sensitive check here let
        // restore (which calls `add` for every category in a backup's
        // manifest) silently create a second "SAMPLE CATEGORY" duplicate.
        guard !trimmed.isEmpty,
              !categories.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return false }
        categories.append(trimmed)
        persist()
        return true
    }

    func remove(at offsets: IndexSet) {
        for index in offsets { descriptions.removeValue(forKey: categories[index]) }
        categories.remove(atOffsets: offsets)
        persist()
        persistDescriptions()
    }

    /// Removes one category by name — used by category-merge cleanup, where
    /// the caller has a name, not an index into the live `categories` array.
    func remove(named name: String) {
        guard let index = categories.firstIndex(of: name) else { return }
        remove(at: IndexSet(integer: index))
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
