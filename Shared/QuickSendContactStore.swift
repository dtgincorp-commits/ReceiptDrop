import Foundation

/// The saved "quick-send" recipient for Check-a-Bill shares — picked once via
/// the system contact picker on first use, remembered so every later tap
/// goes straight to a pre-addressed Messages compose instead of the full
/// share sheet. Plain `UserDefaults.standard`: a main-app-only convenience,
/// not something the share extension needs to see.
enum QuickSendContactStore {
    private static let nameKey = "quickSendContactName"
    private static let phoneKey = "quickSendContactPhone"

    static var name: String? {
        UserDefaults.standard.string(forKey: nameKey)
    }

    static var phoneNumber: String? {
        UserDefaults.standard.string(forKey: phoneKey)
    }

    static func save(name: String, phoneNumber: String) {
        UserDefaults.standard.set(name, forKey: nameKey)
        UserDefaults.standard.set(phoneNumber, forKey: phoneKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: nameKey)
        UserDefaults.standard.removeObject(forKey: phoneKey)
    }
}
