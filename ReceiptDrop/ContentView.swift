import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var showBackupReminder = false
    @State private var showConnectAI = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ReceiptsView()
                .tabItem { Label("Receipts", systemImage: "list.bullet.clipboard") }
                .tag(0)
            InsightsView()
                .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
                .tag(1)
            RetryQueueView()
                .tabItem { Label("Retry Queue", systemImage: "arrow.clockwise") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
        .tint(Theme.skyBlue)
        // Receipts saved by the share extension land in the App Group spool;
        // drain them into Documents (visible in Files) whenever we foreground.
        .onAppear {
            LocalReceiptStore.drainSpoolIntoDocuments()
            showBackupReminder = BackupSettings.isReminderDue()
            maybeShowAISetup()
        }
        .onChange(of: scenePhase) {
            if $0 == .active {
                LocalReceiptStore.drainSpoolIntoDocuments()
                showBackupReminder = BackupSettings.isReminderDue()
            }
        }
        .alert("Back up your receipts?", isPresented: $showBackupReminder) {
            Button("Remind Me Later", role: .cancel) {}
            Button("Go to Backup") { selectedTab = 3 }
        } message: {
            Text("It's been a while since your last backup. Go to Settings → Archive & Backup to back up now.")
        }
        .sheet(isPresented: $showConnectAI) {
            ConnectAIView { showConnectAI = false }
        }
    }

    /// First-run guided AI setup — shown once, and only to users who don't
    /// already have a working provider. An existing user (key already saved,
    /// or on-device selected) is marked done silently so they never see it.
    private func maybeShowAISetup() {
        guard !AISetupState.hasCompletedSetup else { return }
        if AISetupState.currentProviderIsConfigured {
            AISetupState.hasCompletedSetup = true
            return
        }
        showConnectAI = true
    }
}

// MARK: - Retry Queue

/// Failed submissions awaiting retry. Each row (and "Retry All") re-runs the
/// submission pipeline from the main app; successes move to history and their
/// parked file is deleted. Swipe to delete discards without retrying.
struct RetryQueueView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [QueueEntry] = []
    @State private var retrying: Set<UUID> = []
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableCompatView(
                        title: "Queue Empty",
                        message: "Receipts that fail to upload (no network, API error) will wait here and can be retried."
                    )
                } else {
                    List {
                        if let errorText {
                            Section {
                                Text(errorText)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        ForEach(entries) { entry in
                            QueueRow(entry: entry, isRetrying: retrying.contains(entry.id)) {
                                Task { await retry(entry) }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Retry Queue")
            .toolbar {
                if !entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry All") {
                            Task { await retryAll() }
                        }
                        .disabled(!retrying.isEmpty)
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { if $0 == .active { reload() } }
    }

    private func reload() {
        entries = SubmissionStore.loadQueue()
    }

    private func delete(at offsets: IndexSet) {
        offsets.map { entries[$0] }.forEach(SubmissionStore.remove)
        reload()
    }

    private func retry(_ entry: QueueEntry) async {
        guard !retrying.contains(entry.id) else { return }
        guard let data = SubmissionStore.attachmentData(for: entry) else {
            // File missing — nothing to retry; drop the stale entry.
            SubmissionStore.remove(entry)
            reload()
            return
        }
        errorText = nil
        retrying.insert(entry.id)
        defer { retrying.remove(entry.id) }
        do {
            _ = try await SubmissionPipeline().run(
                data: data, kind: entry.kind, category: entry.category)
            LocalReceiptStore.drainSpoolIntoDocuments()
            SubmissionStore.remove(entry)
            reload()
        } catch is SubmissionError {
            // Already recorded elsewhere — drop the stale queue entry, nothing to retry.
            SubmissionStore.remove(entry)
            reload()
        } catch {
            errorText = "\(entry.category): \(error.localizedDescription)"
        }
    }

    private func retryAll() async {
        for entry in SubmissionStore.loadQueue() {
            await retry(entry)
        }
    }
}

private struct QueueRow: View {
    let entry: QueueEntry
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.category).font(.headline)
                Text(entry.error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isRetrying {
                ProgressView()
            } else {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

/// iOS 16-compatible stand-in for ContentUnavailableView (which is iOS 17+).
struct ContentUnavailableCompatView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
