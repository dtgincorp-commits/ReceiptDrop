import Foundation
import UIKit

/// Runs the existing Backup → Remind Me cadence automatically instead of
/// just showing a reminder — see `BackupSettings.isReminderDue()`. Both
/// entry points are silent (no UI) and share the same "is one actually due"
/// gate, so opening/backgrounding the app doesn't churn the kept backups
/// beyond whatever cadence the user already chose in Settings.
///
/// UIKit-only (`UIApplication`), so this lives in the app target, not
/// `Shared/` — the share extension has no need for it and `UIApplication
/// .shared` isn't available there anyway.
enum AutoBackupService {
    /// Call when the app becomes active (foreground launch or resume).
    /// Runs off the main thread — `buildFullBackup()` does real file I/O
    /// and zip compression, which would otherwise stall app launch.
    static func runIfDueOnForeground() {
        guard BackupSettings.isReminderDue() else { return }
        Task.detached(priority: .utility) {
            _ = try? ArchiveBackupService.buildFullBackup()
            BackupSettings.lastBackupDate = Date()
        }
    }

    /// Call when the app is about to background. Best-effort only: iOS
    /// grants a background task a limited window (historically ~30s) and
    /// can suspend or kill the process at any point with no further
    /// callback, so this can never *guarantee* completion the way the
    /// foreground path effectively can. Same due-check as foreground, so a
    /// quick open-and-close doesn't also spend one of the kept backup slots.
    static func attemptBestEffortBackupOnBackground() {
        guard BackupSettings.isReminderDue() else { return }
        let taskGuard = BackgroundTaskGuard()
        guard taskGuard.begin(name: "AutoBackup") else { return }
        Task.detached(priority: .utility) {
            _ = try? ArchiveBackupService.buildFullBackup()
            BackupSettings.lastBackupDate = Date()
            taskGuard.end()
        }
    }
}

/// `beginBackgroundTask`'s expiration handler and the work it's guarding can
/// each try to end the task — calling `endBackgroundTask` twice for the same
/// ID is a real crash risk if both paths aren't coordinated. This makes
/// ending idempotent regardless of which side gets there first. Apple
/// documents `begin`/`endBackgroundTask` as callable from any thread, so the
/// lock (not `@MainActor`) is the correct guard here.
private final class BackgroundTaskGuard {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private let lock = NSLock()

    func begin(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
        return taskID != .invalid
    }

    func end() {
        lock.lock()
        let id = taskID
        taskID = .invalid
        lock.unlock()
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
