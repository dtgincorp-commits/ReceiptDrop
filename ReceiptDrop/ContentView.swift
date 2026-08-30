import SwiftUI

/// Cross-tab bridge for jumping straight to a filtered Receipts list from
/// somewhere outside Receipts' own navigation — currently just Settings →
/// Categories → a category's "Receipts N" row, which used to be an inert
/// label there (see `CategoriesView.onShowReceipts`) because Settings had no
/// way to reach either `ContentView.selectedTab` or `ReceiptsView.filterCategory`,
/// both plain `@State` private to their own views.
///
/// Follows `CategoryStore.shared`'s singleton-`ObservableObject` shape, but
/// lives in the app target rather than `Shared/` — unlike `CategoryStore`,
/// nothing here is read or written by the share extension, which has no
/// tabs or navigation stack to bridge between.
///
/// `ContentView` observes `selectedTab` to switch the visible tab;
/// `ReceiptsView` observes `pendingCategoryFilter` to apply the filter once
/// it's on-screen. Both consumers clear the field they handled back to nil
/// immediately after acting on it, so a value here always means "a jump was
/// just requested," never "the current state" — a plain notification would
/// work for the one-shot signal, but `ReceiptsView` needs the category
/// *string* itself, not just a wake-up call, and both consumers need to fire
/// even if their view isn't the one currently on screen when the request is
/// made.
final class ReceiptsNavigator: ObservableObject {
    static let shared = ReceiptsNavigator()
    private init() {}

    @Published var selectedTab: Int?
    @Published var pendingCategoryFilter: String?

    func showReceipts(filteredTo category: String) {
        pendingCategoryFilter = category
        selectedTab = 0
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var receiptsNavigator = ReceiptsNavigator.shared
    @State private var selectedTab = 0
    @State private var showBackupReminder = false
    @State private var showConnectAI = false
    @State private var caseVariantHealMessage = ""
    @State private var showCaseVariantHealAlert = false
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
                // "Pending", not "Retry Queue" -- a queue of retries is how
                // this works, not what it means to the person looking at it.
                // Same reasoning as Receipt Date over Work Date (TODO item 2):
                // the internal name stays, the label speaks the user's words.
                .tabItem { Label("Pending", systemImage: "arrow.clockwise") }
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
            healCaseVariantFolders()
            showBackupReminder = BackupSettings.isReminderDue()
            maybeShowAISetup()
        }
        .onChange(of: scenePhase) {
            if $0 == .active {
                LocalReceiptStore.drainSpoolIntoDocuments()
                healCaseVariantFolders()
                showBackupReminder = BackupSettings.isReminderDue()
            }
        }
        .alert("Back up your receipts?", isPresented: $showBackupReminder) {
            Button("Remind Me Later", role: .cancel) {}
            Button("Go to Backup") { selectedTab = 3 }
        } message: {
            Text("It's been a while since your last backup. Go to Settings → Archive & Backup to back up now.")
        }
        // Surfaced (not silent): this is moving tax records the user relies
        // on, so even though it's automatic and safe (see
        // `healCaseVariantFolders` below), it's told rather than just done.
        .alert("Category Folders Combined", isPresented: $showCaseVariantHealAlert) {
            Button("OK") {}
        } message: {
            Text(caseVariantHealMessage)
        }
        .sheet(isPresented: $showConnectAI) {
            ConnectAIView { showConnectAI = false }
        }
        // Consumes `ReceiptsNavigator`'s cross-tab jump request — see its
        // doc comment. Cleared right after acting on it so revisiting
        // Receipts later doesn't re-select tab 0 on its own.
        .onChange(of: receiptsNavigator.selectedTab) {
            guard let tab = $0 else { return }
            selectedTab = tab
            receiptsNavigator.selectedTab = nil
        }
    }

    /// Must run only after `drainSpoolIntoDocuments()` — spooled files that
    /// haven't landed in Documents yet aren't visible to this at all, so
    /// draining first is what lets a receipt sitting in a share-extension
    /// spool folder end up healed instead of orphaned in a variant that
    /// this pass never sees.
    ///
    /// Silent when there's nothing to do (the overwhelming majority of
    /// launches, once an install has been healed once) — the alert only
    /// fires the run that actually found and merged a split. iOS's
    /// case-sensitive data volume is what let two folders share one
    /// category in the first place (see `LocalReceiptStore.
    /// categoryFolderURL`); an install already carrying that split gets it
    /// fixed automatically rather than requiring a support conversation,
    /// but because this moves real receipt files across folders — the
    /// user's actual tax records — it's told about it after the fact rather
    /// than done invisibly, the same way Merge/Rename in Settings already
    /// report what they moved.
    private func healCaseVariantFolders() {
        let summary = LocalReceiptStore.healCaseVariantCategoryFolders()
        guard summary.categoriesHealed > 0 else { return }
        var message = "\(summary.categoriesHealed) categor\(summary.categoriesHealed == 1 ? "y" : "ies") had files split across two folders — they've been combined, moving \(summary.filesMoved) file\(summary.filesMoved == 1 ? "" : "s") into one place."
        if summary.conflicts > 0 {
            message += " \(summary.conflicts) file\(summary.conflicts == 1 ? "" : "s") shared a name with a different file already there, so \(summary.conflicts == 1 ? "it was" : "they were") left where \(summary.conflicts == 1 ? "it was" : "they were") — check Files → On My iPhone → Receipts4Tax if a category looks off."
        }
        caseVariantHealMessage = message
        showCaseVariantHealAlert = true
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
    /// Set by `retry(_:)` when a single-entry retry hits a connectivity-class
    /// failure (see `ExtractionFailureClass`) — presented as a sheet so the
    /// user gets the same fallback choices `ReceiptSubmitView`'s
    /// `.offlineChoice` prompt offers, instead of the dead-end "\(reason)"
    /// text that used to land in `errorText` (nothing to do but change
    /// Settings and try again). Not surfaced by `retryAll()` — see its
    /// comment.
    @State private var offlineChoice: OfflineRetryChoice?

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableCompatView(
                        title: "Queue Empty",
                        message: "Receipts that fail to upload (no network, API error), or that a multi-photo share arrived too fast to process, will wait here and can be retried."
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
            .navigationTitle("Pending")
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
        .sheet(item: $offlineChoice) { choice in
            QueueOfflineChoiceView(
                entry: choice.entry, reason: choice.reason,
                canUseAppleIntelligence: choice.canUseAppleIntelligence,
                onResolved: {
                    offlineChoice = nil
                    reload()
                },
                onDismiss: { offlineChoice = nil })
        }
    }

    private func reload() {
        entries = SubmissionStore.loadQueue()
    }

    private func delete(at offsets: IndexSet) {
        offsets.map { entries[$0] }.forEach(SubmissionStore.remove)
        reload()
    }

    /// `offerChoice` is true for every entry point except `retryAll()` — see
    /// that function's comment for why a batch retry never opens the
    /// connectivity-choice sheet.
    private func retry(_ entry: QueueEntry, offerChoice: Bool = true) async {
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
        } catch let duplicate as SubmissionError {
            // Already recorded elsewhere — retrying again would just hit the
            // same duplicate check, so there's nothing to gain by leaving it
            // queued. But the match only checks category/date/amount (not
            // vendor), so this could genuinely be a different receipt —
            // silently dropping the entry with no trace (the old behavior)
            // left the user no way to know that happened or why. Surface
            // the same message `ReceiptSubmitView` would, in the existing
            // error banner, before removing it. This is a background/batch
            // context, not an interactive moment, so unlike
            // `ReceiptSubmitView`'s "Save Anyway" there's no bypass offered
            // here — just visibility.
            errorText = duplicate.localizedDescription
            SubmissionStore.remove(entry)
            reload()
        } catch {
            if offerChoice, ExtractionFailureClass.classify(error) == .connectivity {
                // AI just couldn't be reached — same situation
                // `ReceiptSubmitView.submit()` handles with `.offlineChoice`.
                // Apple Intelligence is only worth offering if it's usable on
                // this device *and* isn't the provider that just failed.
                let canUseAppleIntelligence = ExtractionSettings.provider != .appleOnDevice
                    && ExtractionSettings.appleOnDeviceReady
                offlineChoice = OfflineRetryChoice(
                    entry: entry, reason: error.localizedDescription,
                    canUseAppleIntelligence: canUseAppleIntelligence)
            } else {
                errorText = "\(entry.category): \(error.localizedDescription)"
            }
        }
    }

    /// Deliberately keeps the old collect-errors-into-`errorText` behavior
    /// instead of offering the connectivity-choice sheet per entry: with
    /// four (or more) queued receipts all blocked the same way (e.g. Offline
    /// Mode just got turned on), popping a modal choice for each one in turn
    /// would mean four sequential prompts the user has to click through one
    /// at a time, which is worse than today's single error summary. Anyone
    /// who wants the fallback choices for a specific receipt already has
    /// single-entry retry (the row's retry button, or the detail screen) for
    /// that.
    private func retryAll() async {
        for entry in SubmissionStore.loadQueue() {
            await retry(entry, offerChoice: false)
        }
    }
}

/// Identifies which queued entry `RetryQueueView`'s connectivity-choice
/// sheet is currently showing, plus the failure it needs to display. See
/// `RetryQueueView.offlineChoice`.
private struct OfflineRetryChoice: Identifiable {
    let entry: QueueEntry
    let reason: String
    let canUseAppleIntelligence: Bool
    var id: UUID { entry.id }
}

/// The Retry Queue's answer to `ReceiptSubmitView`'s `.offlineChoice`
/// prompt — same fork (Apple Intelligence / manual entry), but adapted to a
/// receipt that's already saved to the queue: there's no "Save for Later"
/// here, since it's already saved for later, so the third choice is
/// "Keep in Queue" (do nothing, leave it as-is).
private struct QueueOfflineChoiceView: View {
    let entry: QueueEntry
    /// Called once the entry is resolved — either Apple Intelligence
    /// succeeded, or the manual-entry sheet below finished a submission.
    /// The caller reloads its list and dismisses this sheet.
    let onResolved: () -> Void
    let onDismiss: () -> Void

    @State private var reason: String
    @State private var canUseAppleIntelligence: Bool
    @State private var isRetrying = false
    /// True while `beginManualEntry()` is reading the parked file and
    /// building a thumbnail off the main thread — drives the "Continue
    /// Without AI" button's spinner so the tap isn't silent while that work
    /// happens, and blocks a double-tap the same way `isRetrying` already
    /// does for the Apple Intelligence retry.
    @State private var isPreparingManualEntry = false
    @State private var showManualEntry = false
    @State private var manualAttachment: SharedAttachment?
    /// Set when `useAppleIntelligence()` hits `SubmissionError.duplicate` —
    /// swaps this sheet's content over to an "Already Saved" notice instead
    /// of silently removing the queue entry and dismissing with no trace
    /// (the old behavior). Kept simple relative to `ReceiptSubmitView`'s
    /// "Save Anyway": this is a background-queue retry, not the interactive
    /// moment that check was really designed to guard, so the only action
    /// offered is acknowledging and dismissing — see `useAppleIntelligence()`.
    @State private var duplicateNotice: String?

    init(entry: QueueEntry, reason: String, canUseAppleIntelligence: Bool,
         onResolved: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.entry = entry
        self.onResolved = onResolved
        self.onDismiss = onDismiss
        _reason = State(initialValue: reason)
        _canUseAppleIntelligence = State(initialValue: canUseAppleIntelligence)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let duplicateNotice {
                    // Replaces the whole Apple Intelligence / Continue
                    // Without AI fork below — there's nothing left to retry
                    // once the pipeline says this is already recorded, so
                    // the only thing left to do is show why before the
                    // entry goes, then let the user dismiss.
                    Section {
                        Label("Already Saved", systemImage: "checkmark.circle.badge.questionmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                        Text(duplicateNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button {
                            SubmissionStore.remove(entry)
                            onResolved()
                        } label: {
                            HStack { Spacer(); Text("OK").bold(); Spacer() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                Section {
                    Label("Couldn't reach AI extraction", systemImage: "wifi.exclamationmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if canUseAppleIntelligence {
                        Text("Apple Intelligence reads the receipt on this iPhone; Continue Without AI just text-matches and is often wrong.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await useAppleIntelligence() }
                        } label: {
                            HStack {
                                Spacer()
                                if isRetrying { ProgressView() } else { Text("Use Apple Intelligence").bold() }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRetrying || isPreparingManualEntry)
                    } else {
                        Text("The receipt itself is fine — fill in the details yourself, or keep it queued to retry with AI later.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Same type-inference reason `ReceiptSubmitView`'s
                    // `.offlineChoice` case has two copies of this button:
                    // `.bordered`/`.borderedProminent` aren't the same
                    // concrete `ButtonStyle` type, so a ternary picking
                    // between them as a single `.buttonStyle(...)` call
                    // doesn't type-check.
                    if canUseAppleIntelligence {
                        Button {
                            beginManualEntry()
                        } label: {
                            HStack {
                                Spacer()
                                if isPreparingManualEntry { ProgressView() } else { Text("Continue Without AI").bold() }
                                Spacer()
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRetrying || isPreparingManualEntry)
                    } else {
                        Button {
                            beginManualEntry()
                        } label: {
                            HStack {
                                Spacer()
                                if isPreparingManualEntry { ProgressView() } else { Text("Continue Without AI").bold() }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRetrying || isPreparingManualEntry)
                    }

                    // Least prominent, matching `ReceiptSubmitView`'s
                    // "Discard Receipt" — this one just closes the sheet and
                    // leaves the entry queued rather than discarding it.
                    Button("Keep in Queue", action: onDismiss)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isRetrying || isPreparingManualEntry)
                }
                }
            }
            .navigationTitle("Retry Failed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep in Queue", action: onDismiss)
                        .disabled(isRetrying || isPreparingManualEntry)
                }
            }
        }
        .sheet(isPresented: $showManualEntry) {
            if let manualAttachment {
                // `startInManualMode: true` — this entry already failed AI
                // extraction once; opening straight into the manual fields
                // (Vision OCR prefill) rather than letting `submit()` try
                // the AI pipeline again matches what "Continue Without AI"
                // means everywhere else in the app.
                ReceiptSubmitView(
                    attachment: manualAttachment,
                    onCancel: { showManualEntry = false },
                    onComplete: {
                        showManualEntry = false
                        SubmissionStore.remove(entry)
                        LocalReceiptStore.drainSpoolIntoDocuments()
                        onResolved()
                    },
                    startInManualMode: true)
            }
        }
    }

    /// Reading the parked file (can be several MB) and decoding a thumbnail
    /// from a full ~12MP capture used to happen synchronously here, right
    /// before presenting the sheet — that's the multi-second blank-screen
    /// stall this button caused. Both steps now run off the main thread in
    /// a detached task (mirroring `BatchSubmissionRunner`'s pattern), and
    /// only the final state assignment + sheet presentation hop back to the
    /// main actor.
    private func beginManualEntry() {
        isPreparingManualEntry = true
        let entry = entry
        Task.detached(priority: .userInitiated) {
            let prepared: SharedAttachment?
            if let data = SubmissionStore.attachmentData(for: entry) {
                // Downsampled — this is only ever shown as a ~220pt
                // thumbnail here and in the manual-entry sheet; `data`
                // below stays the untouched original for OCR/extraction.
                let thumbnail = entry.kind == .image
                    ? AttachmentThumbnail.downsampled(from: data)
                    : pdfThumbnail(data)
                prepared = SharedAttachment(kind: entry.kind == .image ? .image : .pdf, data: data, thumbnail: thumbnail)
            } else {
                prepared = nil
            }
            await MainActor.run {
                isPreparingManualEntry = false
                guard let prepared else {
                    // Parked file is gone — nothing left to hand to manual
                    // entry; drop the stale entry instead of opening an
                    // empty sheet.
                    SubmissionStore.remove(entry)
                    onResolved()
                    return
                }
                manualAttachment = prepared
                showManualEntry = true
            }
        }
    }

    /// Same one-shot `forcedProvider` retry `ReceiptSubmitView.useAppleIntelligence()`
    /// does — if it fails again, don't loop back to offering Apple
    /// Intelligence a second time on the same receipt; fall through to the
    /// manual-entry / keep-in-queue pair with the new error.
    private func useAppleIntelligence() async {
        guard let data = SubmissionStore.attachmentData(for: entry) else {
            SubmissionStore.remove(entry)
            onResolved()
            return
        }
        isRetrying = true
        defer { isRetrying = false }
        do {
            _ = try await SubmissionPipeline().run(
                data: data, kind: entry.kind, category: entry.category, forcedProvider: .appleOnDevice)
            LocalReceiptStore.drainSpoolIntoDocuments()
            SubmissionStore.remove(entry)
            onResolved()
        } catch let duplicate as SubmissionError {
            // Same reasoning as `RetryQueueView.retry`'s duplicate catch —
            // show why before the entry goes instead of vanishing it
            // silently. Doesn't remove the entry or dismiss immediately;
            // `duplicateNotice` swaps this sheet's content to the notice
            // above, and its "OK" button is what actually removes the
            // entry and calls `onResolved()`, once the user has seen it.
            duplicateNotice = duplicate.localizedDescription
        } catch {
            reason = error.localizedDescription
            canUseAppleIntelligence = false
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
                Text(entry.isPending ? "Waiting to process" : entry.error)
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
                if entry.isPending {
                    // Not a failure — this is a batch item the share
                    // extension parked but couldn't safely run AI extraction
                    // on itself (see PendingSubmissionProcessor). It'll be
                    // processed automatically next launch; Retry here just
                    // runs that same step immediately instead of waiting.
                    Text("Not processed yet — this will run automatically the next time Receipts4Tax opens, or tap Retry to process it now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(entry.isPending ? "Status" : "Why it failed")
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

    /// Same off-main-thread treatment as `beginManualEntry` above: reading
    /// the parked file and decoding a thumbnail from a full-resolution
    /// capture are both slow enough to be worth keeping off the main
    /// thread, even though this preview already shows a `ProgressView`
    /// while it loads. The full-screen zoom viewer reads its own copy of
    /// `data` fresh (see `.fullScreenCover` above), so downsampling this
    /// preview doesn't affect it.
    private func loadPreview() {
        let entry = entry
        Task.detached(priority: .userInitiated) {
            guard let data = SubmissionStore.attachmentData(for: entry) else { return }
            let loadedIsPDF = entry.kind != .image
            let loadedImage = loadedIsPDF ? pdfThumbnail(data) : AttachmentThumbnail.downsampled(from: data)
            await MainActor.run {
                isPDF = loadedIsPDF
                image = loadedImage
            }
        }
    }
}

/// iOS 16-compatible stand-in for ContentUnavailableView (which is iOS 17+).
///
/// `actions` defaults to `EmptyView`, so every existing call site (search
/// results, filtered-category, upload queue, insights, duplicate review) is
/// unaffected — it's opt-in, used only where an empty state should actually
/// invite a specific next action (the "zero receipts, period" case) rather
/// than just narrate why the list is empty.
struct ContentUnavailableCompatView<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    init(title: String, message: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.actions = actions
    }

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
            actions()
        }
    }
}
