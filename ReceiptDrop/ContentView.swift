import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var showBackupReminder = false
    @State private var showConnectAI = false
    // @AppStorage against the App Group suite (not the default store) so
    // this reads/writes the same value SettingsView's picker does, with
    // SwiftUI's normal live-update behavior — changing it in Settings
    // redraws here immediately, no relaunch needed.
    @AppStorage(AppConstants.DefaultsKeys.appTextSize, store: UserDefaults(suiteName: AppConstants.appGroupID))
    private var appTextSize: AppTextSize = .system

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
        // Applied once at the root — sheets/full-screen covers presented
        // from anywhere in this tree (Edit Receipt, the submit screen,
        // Connect AI) inherit it as part of the normal environment.
        // `.system` applies no modifier at all, so iOS's own Text Size /
        // accessibility setting flows through completely untouched.
        .modifier(OptionalDynamicTypeSize(size: appTextSize.dynamicTypeSize))
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

/// Applies a `DynamicTypeSize` override only when one is given — `nil`
/// (the `.system` case of `AppTextSize`) must leave iOS's own Text Size /
/// accessibility setting completely untouched rather than pinning to some
/// default, which is why this isn't just `.dynamicTypeSize(size ?? .large)`.
private struct OptionalDynamicTypeSize: ViewModifier {
    let size: DynamicTypeSize?

    func body(content: Content) -> some View {
        if let size {
            content.dynamicTypeSize(size)
        } else {
            content
        }
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
                            NavigationLink {
                                QueueEntryDetailView(
                                    entry: entry,
                                    onRetry: { Task { await retry(entry) } },
                                    onDelete: {
                                        SubmissionStore.remove(entry)
                                        reload()
                                    })
                            } label: {
                                QueueRow(entry: entry, isRetrying: retrying.contains(entry.id)) {
                                    Task { await retry(entry) }
                                }
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

/// Tapping a Retry Queue row lands here — shows the actual photo/PDF that
/// failed to submit (read back from the parked file via
/// `SubmissionStore.attachmentData`) plus the full error text, since the
/// list row truncates it to two lines. Retrying or deleting both return to
/// the list immediately (rather than tracking progress in this screen too)
/// so success/failure is reported in one place, the same way it already is
/// for the inline retry button.
private struct QueueEntryDetailView: View {
    let entry: QueueEntry
    let onRetry: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isPDF = false
    @State private var showDeleteConfirm = false
    @State private var showPhotoViewer = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    if let image {
                        // Tappable: a queued receipt is exactly the case where
                        // the user needs a close look — deciding whether it's
                        // worth retrying, or reading a total off a dim/angled
                        // shot. Reuses the same viewer as Bill Breakdown, so
                        // pinch-zoom plus the Enhanced/Cropped renderings for
                        // faded thermal paper come along for free.
                        Button {
                            showPhotoViewer = true
                        } label: {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    } else if isPDF {
                        Label("PDF attached", systemImage: "doc.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .frame(height: 120)
                    }
                    Spacer()
                }
            } footer: {
                if image != nil {
                    Text("Tap the photo to zoom in.")
                }
            }

            Section {
                LabeledContent("Category", value: entry.category)
                LabeledContent("Queued", value: entry.timestamp.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Text(entry.error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } header: {
                Text("Why it failed")
            }

            Section {
                Button {
                    onRetry()
                    dismiss()
                } label: {
                    HStack {
                        Spacer()
                        Text("Retry").bold()
                        Spacer()
                    }
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Delete from Queue")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Failed Submission")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete this from the queue?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete()
                dismiss()
            }
        } message: {
            Text("The photo won't be submitted or saved anywhere — this can't be undone.")
        }
        .fullScreenCover(isPresented: $showPhotoViewer) {
            // Read the bytes fresh rather than re-encoding `image` — the
            // viewer's Enhanced/Cropped modes work off the original file.
            if let data = SubmissionStore.attachmentData(for: entry) {
                BillPhotoViewerView(photoData: data, onDone: { showPhotoViewer = false })
            }
        }
        .onAppear(perform: loadPreview)
    }

    private func loadPreview() {
        guard let data = SubmissionStore.attachmentData(for: entry) else { return }
        if entry.kind == .image {
            image = UIImage(data: data)
        } else {
            isPDF = true
            image = pdfThumbnail(data)
        }
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
