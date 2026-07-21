import SwiftUI

@main
struct ReceiptDropApp: App {
    init() {
        // Keep receipt images off iCloud/device backups — enforce, don't just
        // advise. Runs every launch so the flag survives folder recreation.
        LocalReceiptStore.excludeReceiptsFromBackup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
