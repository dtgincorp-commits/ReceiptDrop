import SwiftUI

@main
struct ReceiptDropApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Keep receipt images off iCloud/device backups — enforce, don't just
        // advise. Runs every launch so the flag survives folder recreation.
        LocalReceiptStore.excludeReceiptsFromBackup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                AutoBackupService.runIfDueOnForeground()
            case .background:
                AutoBackupService.attemptBestEffortBackupOnBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
