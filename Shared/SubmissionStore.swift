import Foundation

/// Reads and writes the submission history and retry queue, both persisted in
/// App Group storage so the share extension can write them while the main app
/// is backgrounded, and the main app can read them when it foregrounds.
///
/// - History lives as a Codable array in App Group defaults (newest first,
///   capped at ~200 entries).
/// - Failed submissions park their bytes as a file in the App Group container
///   plus a Codable queue entry in defaults, so the main app can retry them.
enum SubmissionStore {
    private static let defaults = UserDefaults(suiteName: AppConstants.appGroupID)!
    private static let historyLimit = 200
    private static let pendingDirName = "PendingReceipts"

    // MARK: - History

    static func loadHistory() -> [HistoryEntry] {
        decode([HistoryEntry].self, key: AppConstants.DefaultsKeys.history) ?? []
    }

    static func appendHistory(_ entry: HistoryEntry) {
        var items = loadHistory()
        items.insert(entry, at: 0)
        if items.count > historyLimit { items = Array(items.prefix(historyLimit)) }
        encode(items, key: AppConstants.DefaultsKeys.history)
    }

    static func removeHistory(_ entry: HistoryEntry) {
        var items = loadHistory()
        items.removeAll { $0.id == entry.id }
        encode(items, key: AppConstants.DefaultsKeys.history)
    }

    /// Replaces an existing entry (matched by id) with an edited version.
    static func updateHistory(_ entry: HistoryEntry) {
        var items = loadHistory()
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[index] = entry
        encode(items, key: AppConstants.DefaultsKeys.history)
    }

    // MARK: - Retry queue

    static func loadQueue() -> [QueueEntry] {
        decode([QueueEntry].self, key: AppConstants.DefaultsKeys.retryQueue) ?? []
    }

    /// Persist the attachment bytes to disk and record a queue entry.
    static func enqueue(data: Data, category: String, kind: ReceiptKind, error: String) {
        let filename = "\(UUID().uuidString).\(kind.fileExtension)"
        if let url = fileURL(for: filename) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        var items = loadQueue()
        items.insert(
            QueueEntry(category: category, filename: filename, kind: kind,
                       error: error, timestamp: Date()),
            at: 0)
        encode(items, key: AppConstants.DefaultsKeys.retryQueue)
    }

    /// Remove a queue entry and delete its parked file.
    static func remove(_ entry: QueueEntry) {
        if let url = fileURL(for: entry.filename) {
            try? FileManager.default.removeItem(at: url)
        }
        var items = loadQueue()
        items.removeAll { $0.id == entry.id }
        encode(items, key: AppConstants.DefaultsKeys.retryQueue)
    }

    static func attachmentData(for entry: QueueEntry) -> Data? {
        guard let url = fileURL(for: entry.filename) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Paths

    private static func fileURL(for filename: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupID)?
            .appendingPathComponent(pendingDirName, isDirectory: true)
            .appendingPathComponent(filename)
    }

    // MARK: - Codable helpers

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
