import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var selectedProvider: ExtractionProvider = ExtractionSettings.provider
    @State private var selectedMode: ExtractionMode = ExtractionSettings.mode
    @State private var offlineOnly: Bool = ExtractionSettings.offlineOnly
    @State private var isClassifying = false
    @State private var classifyMessage: String?
    @State private var classifyError: String?
    @State private var showConnectAI = false
    // Same App Group store + key ContentView reads, so this picker and the
    // app-wide override it controls always agree — SwiftUI's @AppStorage
    // updates live across both without any extra plumbing.
    @AppStorage(AppConstants.DefaultsKeys.appTextSize, store: UserDefaults(suiteName: AppConstants.appGroupID))
    private var appTextSize: AppTextSize = .system
    @AppStorage(AppConstants.DefaultsKeys.appCurrency, store: UserDefaults(suiteName: AppConstants.appGroupID))
    private var appCurrency: AppCurrency = .auto

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("AI Provider", selection: $selectedProvider) {
                        ForEach(ExtractionProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: selectedProvider) { newValue in
                        guard newValue.isAvailable else {
                            selectedProvider = ExtractionSettings.provider
                            return
                        }
                        ExtractionSettings.provider = newValue
                    }

                    Picker("Extraction Mode", selection: $selectedMode) {
                        ForEach(ExtractionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: selectedMode) { ExtractionSettings.mode = $0 }

                    Toggle("Offline Mode (on-device only)", isOn: $offlineOnly)
                        .onChange(of: offlineOnly) { newValue in
                            ExtractionSettings.offlineOnly = newValue
                            // Turning offline on with a cloud provider selected
                            // would make everything error — auto-switch to the
                            // on-device provider when it's available.
                            if newValue, selectedProvider != .appleOnDevice,
                               ExtractionProvider.appleOnDevice.isAvailable {
                                selectedProvider = .appleOnDevice
                                ExtractionSettings.provider = .appleOnDevice
                            }
                        }

                    // Guided version of everything above — for users who
                    // don't know what an API key is. Same storage underneath.
                    Button {
                        showConnectAI = true
                    } label: {
                        Label("Connect AI (Guided Setup)…", systemImage: "wand.and.stars")
                    }
                } header: {
                    Text("Receipt Extraction")
                } footer: {
                    Text("\"On-Device OCR Text\" reads the receipt on your phone for free and sends only the text — faster and cheaper. Hard-to-read receipts automatically retry with the full image. \"Apple On-Device\" reads receipts entirely on your phone with Apple Intelligence — no API key, nothing leaves the device — and requires iOS 26+ on an Apple Intelligence–capable iPhone with the feature enabled.\n\nOffline Mode blocks the cloud providers (Claude, OpenAI, Gemini, Perplexity, Microsoft Document Intelligence) so nothing is ever sent off the device — reading and search then require the Apple On-Device provider. Turn it on to verify the app works fully in Airplane Mode.")
                }

                Section {
                    Label {
                        Text("Keep receipt images on this iPhone only")
                            .font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Receipt images stay local to this iPhone. The app automatically excludes its receipt storage from iCloud and device backups, so they're never uploaded by a system backup. They live under On My iPhone → ReceiptDrop in the Files app (local storage). To keep them solely on-device, don't manually copy them into iCloud Drive, Photos (with iCloud Photos on), or any other cloud folder.")
                }

                // Only the currently selected provider's key field is shown —
                // no point cluttering Settings with fields for providers
                // that aren't in use.
                switch selectedProvider {
                case .claude:
                    APIKeySection(
                        title: "Anthropic API Key", placeholder: "sk-ant-…",
                        account: AppConstants.KeychainKeys.anthropicAPIKey,
                        footer: "Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the Anthropic API.",
                        testKey: APIKeyTester.testClaudeKey)
                case .openAI:
                    APIKeySection(
                        title: "OpenAI API Key", placeholder: "sk-…",
                        account: AppConstants.KeychainKeys.openAIAPIKey,
                        footer: "Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the OpenAI API.",
                        testKey: APIKeyTester.testOpenAIKey)
                case .gemini:
                    APIKeySection(
                        title: "Google Gemini API Key", placeholder: "AIza…",
                        account: AppConstants.KeychainKeys.geminiAPIKey,
                        footer: "Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the Gemini API.",
                        testKey: APIKeyTester.testGeminiKey)
                case .perplexity:
                    APIKeySection(
                        title: "Perplexity API Key", placeholder: "pplx-…",
                        account: AppConstants.KeychainKeys.perplexityAPIKey,
                        footer: "Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the Perplexity API.",
                        testKey: APIKeyTester.testPerplexityKey)
                case .azureDocumentIntelligence:
                    AzureAPIKeySection()
                case .appleOnDevice:
                    Section {
                        Label("No API key needed — reading happens on-device.",
                              systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Both receipt reading and natural-language search run on-device. If Apple Intelligence isn't enabled or your device isn't eligible, you'll see an error asking you to enable it or pick another provider.")
                    }
                }

                Section {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("Categories", systemImage: "folder.badge.gearshape")
                    }
                    NavigationLink {
                        ArchiveBackupView()
                    } label: {
                        Label("Archive & Backup", systemImage: "archivebox")
                    }
                } footer: {
                    Text("Categories: add or remove categories, open their CSV logs, and run maintenance. Archive & Backup: export receipts by period, or back up everything.")
                }

                Section {
                    Picker("Text Size", selection: $appTextSize) {
                        ForEach(AppTextSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Changes text size in this app only. \"System\" follows your iPhone's Text Size setting (Settings → Display & Brightness). Choosing a specific size overrides it — including any accessibility text size you've set. Bill Breakdown has its own separate text size control.")
                }

                Section {
                    // Default (wheel/menu) picker style, not .segmented —
                    // eight options don't fit a segmented control the way
                    // Text Size's four short labels do.
                    Picker("Currency", selection: $appCurrency) {
                        ForEach(AppCurrency.allCases) { currency in
                            Text(currency.displayName).tag(currency)
                        }
                    }
                } footer: {
                    Text("Changes how amounts are displayed only — it doesn't convert between currencies or change any already-saved amount. \"Automatic\" follows your iPhone's region setting, same as before this setting existed.")
                }

                Section {
                    Button {
                        classifyUnclassified()
                    } label: {
                        HStack {
                            Text("Classify Untyped Receipts")
                            Spacer()
                            if isClassifying { ProgressView() }
                        }
                    }
                    .disabled(isClassifying)
                    if let classifyMessage {
                        Text(classifyMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    if let classifyError {
                        Text(classifyError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Vendor Types")
                } footer: {
                    Text("Receipts get a business type (restaurant, hardware store, etc.) automatically when scanned. Manually-entered receipts and anything saved before this feature don't have one yet — this classifies all of them at once, from vendor name only (no photos re-sent). Safe to run anytime; only untyped receipts are affected.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showConnectAI) {
                ConnectAIView {
                    showConnectAI = false
                    // The wizard may have switched the provider — pick up the
                    // change so the picker and key section reflect it.
                    selectedProvider = ExtractionSettings.provider
                }
            }
        }
    }

    private func classifyUnclassified() {
        classifyMessage = nil
        classifyError = nil
        guard ExtractionSettings.aiConfigured else {
            classifyError = "This needs an AI — use Connect AI above."
            return
        }
        isClassifying = true
        Task {
            do {
                let count = try await VendorTypeBackfillService.classifyUnclassified()
                await MainActor.run {
                    isClassifying = false
                    classifyMessage = count == 0
                        ? "Nothing to classify — every receipt already has a type."
                        : "Classified \(count) receipt\(count == 1 ? "" : "s")."
                }
            } catch {
                await MainActor.run {
                    isClassifying = false
                    classifyError = error.localizedDescription
                }
            }
        }
    }
}

/// One provider's API key field — saved/cleared state, matching the original
/// Anthropic-only section's behavior, reused for OpenAI and Gemini.
private struct APIKeySection: View {
    let title: String
    let placeholder: String
    let account: String
    let footer: String
    /// Fires the provider's cheapest real endpoint to confirm the key works.
    let testKey: (String) async throws -> Void

    @State private var input = ""
    @State private var saved: Bool
    @State private var revealInput = false
    @State private var revealSaved = false
    @State private var testState: TestState = .idle
    @State private var saveError: String?

    private enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    init(title: String, placeholder: String, account: String, footer: String,
         testKey: @escaping (String) async throws -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.account = account
        self.footer = footer
        self.testKey = testKey
        _saved = State(initialValue: KeychainHelper.get(account) != nil)
    }

    var body: some View {
        Section {
            if saved {
                HStack {
                    Label("API key saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        KeychainHelper.delete(account)
                        saved = false
                        revealSaved = false
                        testState = .idle
                    }
                }
                // Lets the user re-check the exact saved key (whitespace,
                // truncation, wrong key pasted, etc.) while troubleshooting a
                // provider that isn't working, instead of only seeing "saved".
                Button(revealSaved ? "Hide Saved Key" : "Show Saved Key") {
                    revealSaved.toggle()
                }
                if revealSaved, let key = KeychainHelper.get(account) {
                    Text(key)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                testControl
            } else {
                HStack {
                    Group {
                        if revealInput {
                            TextField(placeholder, text: $input)
                        } else {
                            SecureField(placeholder, text: $input)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        revealInput.toggle()
                    } label: {
                        Image(systemName: revealInput ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                Button("Save to Keychain") {
                    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    do {
                        try KeychainHelper.setDetailed(trimmed, for: account)
                        input = ""
                        saved = true
                        saveError = nil
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder
    private var testControl: some View {
        switch testState {
        case .idle:
            Button("Test Key") { runTest() }
        case .testing:
            HStack {
                ProgressView()
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .success:
            HStack {
                Label("Key works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Test Again") { runTest() }
            }
        case .failure(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Key didn't work", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Test Again") { runTest() }
            }
        }
    }

    private func runTest() {
        guard let key = KeychainHelper.get(account) else { return }
        testState = .testing
        Task {
            do {
                try await testKey(key)
                testState = .success
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}

/// Azure needs two values (a resource endpoint + a key) instead of the
/// single key the other providers take, so it gets its own section rather
/// than reusing `APIKeySection`. Both are stored in the Keychain and both
/// must be present before a "Test" is meaningful.
private struct AzureAPIKeySection: View {
    @State private var endpointInput = ""
    @State private var keyInput = ""
    @State private var savedEndpoint: String? = KeychainHelper.get(AppConstants.KeychainKeys.azureDocIntelEndpoint)
    @State private var savedKey: String? = KeychainHelper.get(AppConstants.KeychainKeys.azureDocIntelKey)
    @State private var revealSavedKey = false
    @State private var testState: TestState = .idle
    @State private var saveError: String?

    private enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        Section {
            if let savedEndpoint, let savedKey {
                Label("Endpoint saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(savedEndpoint)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Label("API key saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        KeychainHelper.delete(AppConstants.KeychainKeys.azureDocIntelEndpoint)
                        KeychainHelper.delete(AppConstants.KeychainKeys.azureDocIntelKey)
                        self.savedEndpoint = nil
                        self.savedKey = nil
                        revealSavedKey = false
                        testState = .idle
                    }
                }
                Button(revealSavedKey ? "Hide Saved Key" : "Show Saved Key") {
                    revealSavedKey.toggle()
                }
                if revealSavedKey {
                    Text(savedKey)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                testControl(endpoint: savedEndpoint, key: savedKey)
            } else {
                TextField("https://your-resource.cognitiveservices.azure.com", text: $endpointInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("API key", text: $keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save to Keychain") {
                    let endpoint = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !endpoint.isEmpty, !key.isEmpty else { return }
                    do {
                        try KeychainHelper.setDetailed(endpoint, for: AppConstants.KeychainKeys.azureDocIntelEndpoint)
                        try KeychainHelper.setDetailed(key, for: AppConstants.KeychainKeys.azureDocIntelKey)
                        endpointInput = ""
                        keyInput = ""
                        savedEndpoint = endpoint
                        savedKey = key
                        saveError = nil
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .disabled(endpointInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Microsoft Document Intelligence")
        } footer: {
            Text("Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call your Azure resource. Create a Document Intelligence resource in the Azure portal, then copy its endpoint and key here — the free tier covers 500 pages/month.")
        }
    }

    @ViewBuilder
    private func testControl(endpoint: String, key: String) -> some View {
        switch testState {
        case .idle:
            Button("Test Key") { runTest(endpoint: endpoint, key: key) }
        case .testing:
            HStack {
                ProgressView()
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .success:
            HStack {
                Label("Key works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Test Again") { runTest(endpoint: endpoint, key: key) }
            }
        case .failure(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Key didn't work", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Test Again") { runTest(endpoint: endpoint, key: key) }
            }
        }
    }

    private func runTest(endpoint: String, key: String) {
        testState = .testing
        Task {
            do {
                try await APIKeyTester.testAzureKey(endpoint: endpoint, key: key)
                testState = .success
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Archive & Backup

struct ArchiveBackupView: View {
    @StateObject private var categoryStore = CategoryStore.shared

    private enum ScopeKind: String, CaseIterable, Identifiable {
        case year = "Year"
        case month = "Month"
        case custom = "Custom Range"
        var id: String { rawValue }
    }

    @State private var scopeKind: ScopeKind = .year
    @State private var selectedYear: Int?
    @State private var selectedMonth: Int?
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var shareURL: IdentifiableURL?
    @State private var lastBackupDate: Date? = BackupSettings.lastBackupDate
    @State private var reminderFrequency: BackupReminderFrequency = BackupSettings.reminderFrequency

    @State private var showRestorePicker = false
    @State private var restoreMessage: String?
    @State private var showRestoreConfirmation = false
    @State private var localBackups: [URL] = LocalReceiptStore.listBackups()
    /// Staged after the Files picker returns a zip — restore doesn't start
    /// until the user confirms the exact filename, since the system picker
    /// (see the folder-vs-zip discussion) can leave someone unsure exactly
    /// what they just selected.
    @State private var pendingRestoreURL: URL?
    @State private var restoreDuplicatePairs: [DuplicateDetectionService.Pair] = []
    @State private var showRestoreDuplicates = false

    private enum DeleteScopeKind: String, CaseIterable, Identifiable {
        case year = "Year"
        case month = "Month"
        var id: String { rawValue }
    }
    @State private var deleteScopeKind: DeleteScopeKind = .year
    @State private var deleteYear: Int?
    @State private var deleteMonth: Int?
    @State private var showDeleteConfirmation = false
    @State private var deleteMessage: String?

    private var years: [Int] { ArchiveBackupService.availableYears() }
    private var months: [Int] { selectedYear.map(ArchiveBackupService.availableMonths(inYear:)) ?? [] }
    private var deleteMonths: [Int] { deleteYear.map(ArchiveBackupService.availableMonths(inYear:)) ?? [] }

    /// The period currently staged for deletion, if the picker selection is
    /// complete — `nil` disables the delete button entirely rather than
    /// letting an incomplete Month selection through.
    private var deleteScope: (label: String, entries: [HistoryEntry])? {
        guard let deleteYear else { return nil }
        switch deleteScopeKind {
        case .year:
            return (String(deleteYear), ArchiveBackupService.entries(inYear: deleteYear))
        case .month:
            guard let deleteMonth else { return nil }
            return ("\(Self.monthName(deleteMonth)) \(deleteYear)",
                    ArchiveBackupService.entries(inYear: deleteYear, month: deleteMonth))
        }
    }

    private var canArchive: Bool {
        switch scopeKind {
        case .year: return selectedYear != nil
        case .month: return selectedYear != nil && selectedMonth != nil
        case .custom: return customStart <= customEnd
        }
    }

    var body: some View {
        Form {
            archiveSection
            backupSection
            restoreSection
            deleteSection
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Archive & Backup")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareURL) { wrapper in
            ActivityShareSheet(url: wrapper.url)
        }
        .fileImporter(isPresented: $showRestorePicker, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                errorMessage = nil
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                // Reject immediately if this isn't a restorable backup,
                // rather than letting the user pick a target category and
                // tap Restore only to hit the same error afterward.
                if RestoreService.isFullBackup(zipURL: url) {
                    pendingRestoreURL = url
                } else {
                    errorMessage = "\"\(url.lastPathComponent)\" is an Archive export, not a full backup — Restore needs a zip made with \"Backup Now\". Archive exports are for sharing or printing a period's receipts; they can't be restored."
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingRestoreURL != nil },
            set: { if !$0 { pendingRestoreURL = nil } })) {
            if let url = pendingRestoreURL {
                RestoreOptionsView(
                    url: url, existingCategories: categoryStore.categories,
                    onCancel: { pendingRestoreURL = nil },
                    onConfirm: { targetCategory in
                        pendingRestoreURL = nil
                        restore(from: url, targetCategory: targetCategory)
                    })
            }
        }
        .onAppear {
            localBackups = LocalReceiptStore.listBackups()
            lastBackupDate = BackupSettings.lastBackupDate
            reminderFrequency = BackupSettings.reminderFrequency
        }
        .alert("Restore Complete", isPresented: $showRestoreConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreMessage ?? "")
        }
        .sheet(isPresented: $showRestoreDuplicates, onDismiss: { restoreDuplicatePairs = [] }) {
            NavigationStack {
                DuplicateReviewView(pairs: $restoreDuplicatePairs)
            }
        }
        .alert("Delete \(deleteScope?.label ?? "") Receipts?",
               isPresented: $showDeleteConfirmation, presenting: deleteScope) { scope in
            Button("Cancel", role: .cancel) {}
            Button("Back Up, Then Delete", role: .destructive) {
                performDelete(label: scope.label, entries: scope.entries)
            }
        } message: { scope in
            Text("A full backup will be made first. Then \(scope.entries.count) receipt\(scope.entries.count == 1 ? "" : "s") from \(scope.label) — including photos — will be permanently deleted. This can only be undone by restoring that backup, and only while it still exists on this phone (the 3 most recent backups are kept).")
        }
    }

    @ViewBuilder
    private var restoreSection: some View {
        Section {
            if isWorking {
                HStack {
                    ProgressView()
                    Text("Restoring…").foregroundStyle(.secondary)
                }
            }
            if localBackups.isEmpty {
                Text("No backups on this phone yet — tap \"Backup Now\" above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(localBackups, id: \.self) { url in
                    Button {
                        restore(from: url)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.backupDate(for: url)?.formatted(date: .abbreviated, time: .shortened) ?? url.lastPathComponent)
                                    .foregroundStyle(.primary)
                                Text(Self.backupSizeString(for: url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isWorking)
                }
                .onDelete(perform: deleteLocalBackups)
            }

            Button {
                openBackupsFolder()
            } label: {
                Label("Show Backups Folder in Files", systemImage: "folder")
            }
            .disabled(isWorking)

            Button {
                showRestorePicker = true
            } label: {
                Label("Restore/Select from a Backup Zip…", systemImage: "arrow.down.doc")
            }
            .disabled(isWorking)

            if let restoreMessage {
                Label(restoreMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Restore")
        } footer: {
            Text("These backups are stored on this phone at Files → On My iPhone → Receipt Drop → Backups. Tap one to restore it — never overwrites or deletes anything already on this phone, only adds what's missing. Swipe to delete a backup you no longer need. \"Restore/Select from a Backup Zip\" opens the Files picker, for backups saved to iCloud Drive or from another phone — select the .zip file itself, not a folder. When restoring from the Files picker, you can choose to import everything into one category instead of keeping the original ones — handy for a backup from another iPhone. Possible duplicates are flagged for review after restoring. Your API key isn't stored in backups; re-enter it in Settings after restoring on a new phone.")
        }
    }

    private func restore(from url: URL, targetCategory: String? = nil) {
        errorMessage = nil
        restoreMessage = nil
        isWorking = true
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try RestoreService.restore(zipURL: url, targetCategory: targetCategory)
                await MainActor.run {
                    isWorking = false
                    var message = "Restored \(summary.receiptsRestored) receipt\(summary.receiptsRestored == 1 ? "" : "s") (\(summary.receiptsSkipped) already present)."
                    if summary.photosReattached > 0 {
                        message += " Reattached \(summary.photosReattached) missing photo\(summary.photosReattached == 1 ? "" : "s") to receipts already on this phone."
                    }
                    if !summary.duplicatePairs.isEmpty {
                        message += " Found \(summary.duplicatePairs.count) possible duplicate\(summary.duplicatePairs.count == 1 ? "" : "s")."
                    }
                    // Called out explicitly rather than left implicit: a
                    // category can appear here with 0 receipts landing in it
                    // (every entry that would have used it was already
                    // present) — without this, that reads as "nothing
                    // happened" even though a new category now sits in the
                    // list with no other explanation for why it showed up.
                    if !summary.categoriesAdded.isEmpty {
                        message += " Added categor\(summary.categoriesAdded.count == 1 ? "y" : "ies"): \(summary.categoriesAdded.joined(separator: ", "))."
                    }
                    restoreMessage = message
                    localBackups = LocalReceiptStore.listBackups()
                    if !summary.duplicatePairs.isEmpty {
                        restoreDuplicatePairs = summary.duplicatePairs
                        showRestoreDuplicates = true
                    } else {
                        showRestoreConfirmation = true
                    }
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var archiveSection: some View {
        Section {
            Picker("Scope", selection: $scopeKind) {
                ForEach(ScopeKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch scopeKind {
            case .year:
                Picker("Year", selection: $selectedYear) {
                    Text("Select a year").tag(Int?.none)
                    ForEach(years, id: \.self) { year in
                        Text("\(String(year)) (\(ArchiveBackupService.entries(inYear: year).count))").tag(Int?.some(year))
                    }
                }
            case .month:
                Picker("Year", selection: $selectedYear) {
                    Text("Select a year").tag(Int?.none)
                    ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                }
                if let selectedYear {
                    Picker("Month", selection: $selectedMonth) {
                        Text("Select a month").tag(Int?.none)
                        ForEach(months, id: \.self) { month in
                            Text("\(Self.monthName(month)) (\(ArchiveBackupService.entries(inYear: selectedYear, month: month).count))").tag(Int?.some(month))
                        }
                    }
                }
            case .custom:
                DatePicker("From", selection: $customStart, displayedComponents: .date)
                DatePicker("To", selection: $customEnd, displayedComponents: .date)
            }

            Button {
                createArchive()
            } label: {
                HStack {
                    Spacer()
                    if isWorking { ProgressView() } else { Text("Create Archive") }
                    Spacer()
                }
            }
            .disabled(isWorking || !canArchive)
        } header: {
            Text("Archive")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Periods are based on each receipt's work date (falling back to the scan date if missing). Creates a zip of that period's photos, attachments, and a CSV, then lets you save it via AirDrop, iCloud Drive, or Files. Nothing is deleted from the app.")
                Text("This export can't be restored later — for a zip you can restore (on this phone or another one), use \"Backup Now\" below instead.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var backupSection: some View {
        Section {
            if let lastBackupDate {
                Text("Last backup: \(lastBackupDate.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            } else {
                Text("Never backed up").foregroundStyle(.secondary)
            }
            Button {
                createBackup()
            } label: {
                HStack {
                    Spacer()
                    if isWorking { ProgressView() } else { Text("Backup Now") }
                    Spacer()
                }
            }
            .disabled(isWorking)

            Picker("Remind Me", selection: $reminderFrequency) {
                ForEach(BackupReminderFrequency.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: reminderFrequency) { BackupSettings.reminderFrequency = $0 }
        } header: {
            Text("Backup")
        } footer: {
            Text("Backs up every receipt, photo, and category setting into one zip file. Save it to iCloud Drive or AirDrop it to your Mac so it's recoverable even if this phone is lost — an iPhone backup alone can't restore just this app's files individually. Never includes your API keys.")
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Picker("Scope", selection: $deleteScopeKind) {
                ForEach(DeleteScopeKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: deleteScopeKind) { _ in deleteMonth = nil }

            Picker("Year", selection: $deleteYear) {
                Text("Select a year").tag(Int?.none)
                ForEach(years, id: \.self) { year in
                    Text("\(String(year)) (\(ArchiveBackupService.entries(inYear: year).count))").tag(Int?.some(year))
                }
            }
            .onChange(of: deleteYear) { _ in deleteMonth = nil }

            if deleteScopeKind == .month, let deleteYear {
                Picker("Month", selection: $deleteMonth) {
                    Text("Select a month").tag(Int?.none)
                    ForEach(deleteMonths, id: \.self) { month in
                        Text("\(Self.monthName(month)) (\(ArchiveBackupService.entries(inYear: deleteYear, month: month).count))").tag(Int?.some(month))
                    }
                }
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    if isWorking { ProgressView() } else { Text("Delete \(deleteScopeKind.rawValue)…") }
                    Spacer()
                }
            }
            .disabled(isWorking || deleteScope == nil)

            if let deleteMessage {
                Label(deleteMessage, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Delete Receipts")
        } footer: {
            Text("Permanently deletes every receipt and photo from the selected year or month. A full backup is created automatically first — restore it from the Restore section above if you need anything back. Consider also saving a copy to iCloud Drive or AirDropping it to your Mac, since only the 3 most recent on-device backups are kept, and a later backup can silently push this one out.")
        }
    }

    /// Backs up first, and only proceeds to delete if that backup actually
    /// succeeds — a failed backup must never be followed by deletion, or the
    /// whole point of forcing it is defeated. Deletion mirrors exactly what
    /// swiping to delete a single receipt does in `ReceiptsView` (history
    /// entry + underlying photo file), just looped over the period's entries.
    /// Shared by both the Year and Month scopes — `entries` is already
    /// filtered to whichever period the caller resolved via `deleteScope`.
    private func performDelete(label: String, entries: [HistoryEntry]) {
        errorMessage = nil
        deleteMessage = nil
        isWorking = true
        Task {
            do {
                let backupURL = try ArchiveBackupService.buildFullBackup()
                for entry in entries {
                    SubmissionStore.removeHistory(entry)
                    try? LocalReceiptStore.deleteEntry(
                        category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
                        amount: entry.amount, receiptFilename: entry.receiptLink, extraFiles: entry.extraFiles)
                }
                await MainActor.run {
                    BackupSettings.lastBackupDate = Date()
                    isWorking = false
                    deleteYear = nil
                    deleteMonth = nil
                    lastBackupDate = BackupSettings.lastBackupDate
                    localBackups = LocalReceiptStore.listBackups()
                    deleteMessage = "Backed up to Files → On My iPhone → Receipt Drop → Backups → \(backupURL.lastPathComponent). Deleted \(entries.count) receipt\(entries.count == 1 ? "" : "s") for \(label)."
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = "Backup failed, so nothing was deleted: \(error.localizedDescription)"
                }
            }
        }
    }

    private func createArchive() {
        errorMessage = nil
        isWorking = true
        let scope = scopeKind
        let year = selectedYear
        let month = selectedMonth
        let start = customStart
        let end = customEnd
        Task {
            do {
                let label: String
                let entries: [HistoryEntry]
                switch scope {
                case .year:
                    guard let year else { isWorking = false; return }
                    label = "ReceiptDrop_Export_\(year)"
                    entries = ArchiveBackupService.entries(inYear: year)
                case .month:
                    guard let year, let month else { isWorking = false; return }
                    label = "ReceiptDrop_Export_\(year)-\(String(format: "%02d", month))"
                    entries = ArchiveBackupService.entries(inYear: year, month: month)
                case .custom:
                    label = "ReceiptDrop_Export_\(LocalReceiptStore.dateString(start))_to_\(LocalReceiptStore.dateString(end))"
                    entries = ArchiveBackupService.entries(from: start, to: end)
                }
                let url = try ArchiveBackupService.buildArchive(label: label, entries: entries)
                await MainActor.run {
                    isWorking = false
                    shareURL = IdentifiableURL(url: url)
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func createBackup() {
        errorMessage = nil
        isWorking = true
        Task {
            do {
                let url = try ArchiveBackupService.buildFullBackup()
                await MainActor.run {
                    isWorking = false
                    shareURL = IdentifiableURL(url: url)
                    BackupSettings.lastBackupDate = Date()
                    lastBackupDate = Date()
                    localBackups = LocalReceiptStore.listBackups()
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private static func monthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        var components = DateComponents()
        components.month = month
        components.year = 2000
        return formatter.string(from: Calendar.current.date(from: components) ?? Date())
    }

    private func deleteLocalBackups(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: localBackups[index])
        }
        localBackups = LocalReceiptStore.listBackups()
    }

    /// Deep-links into the Files app at the Backups folder using the
    /// `shareddocuments://` scheme — same mechanism as the category-folder
    /// and CSV links on the Categories screen.
    private func openBackupsFolder() {
        guard let folderURL = LocalReceiptStore.backupsFolderURL(),
              let filesURL = URL(string: folderURL.absoluteString
                  .replacingOccurrences(of: "file://", with: "shareddocuments://")) else { return }
        UIApplication.shared.open(filesURL)
    }

    private static func backupDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func backupSizeString(for url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Confirms a zip picked via the Files importer before restoring it, and
/// offers redirecting every receipt in the backup into one category —
/// useful when importing another iPhone's backup, where the source phone
/// may have same-named categories that mean something different on this
/// phone. `nil` passed to `onConfirm` keeps each receipt under its
/// original category name (today's default restore behavior).
private struct RestoreOptionsView: View {
    let url: URL
    let existingCategories: [String]
    let onCancel: () -> Void
    let onConfirm: (String?) -> Void

    private enum Mode: Hashable {
        case keepOriginal
        case importIntoCategory
    }

    @State private var mode: Mode = .keepOriginal
    @State private var selectedExisting: String?
    @State private var newCategoryName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Restore is additive — it never overwrites or deletes anything already on this phone, only adds what's missing from this backup.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("", selection: $mode) {
                        Text("Keep Original Categories").tag(Mode.keepOriginal)
                        Text("Import Into One Category").tag(Mode.importIntoCategory)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } footer: {
                    Text(mode == .keepOriginal
                         ? "Receipts are filed under the same category names they had on the other phone — creating any that don't already exist here."
                         : "Every receipt in this backup is filed under one category you choose below, regardless of what category it was under on the other phone. Useful for keeping an import visibly separate until you've reviewed it — e.g. two phones both having a \"DTG\" category that mean different things.")
                }

                if mode == .importIntoCategory {
                    Section {
                        if !existingCategories.isEmpty {
                            Picker("Category", selection: $selectedExisting) {
                                Text("New Category").tag(String?.none)
                                ForEach(existingCategories, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                        }
                        if selectedExisting == nil {
                            TextField("New category name", text: $newCategoryName)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        }
                    } header: {
                        Text("Category")
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") {
                        switch mode {
                        case .keepOriginal:
                            onConfirm(nil)
                        case .importIntoCategory:
                            let target = selectedExisting
                                ?? newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                            onConfirm(target)
                        }
                    }
                    .disabled(mode == .importIntoCategory && selectedExisting == nil
                              && newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Wraps the system share sheet (`UIActivityViewController`) so the user
/// picks where the zip goes — AirDrop, iCloud Drive, Files, Mail, etc. Same
/// mechanism as "Edit CSV in Numbers App": the app hands off the file, iOS
/// requires the user's own tap to choose a destination, no way to bypass that.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Custom Vendor Types

/// Lists user-added custom vendor types (e.g. "Tiki Bar") with swipe-to-
/// delete. Removing one only stops it being offered on future receipts —
/// any receipt already tagged with it keeps that string as-is, same as
/// deleting a Category.
struct CustomVendorTypesView: View {
    @State private var customTypes: [String] = CustomVendorTypeStore.customTypes

    var body: some View {
        Form {
            Section {
                if customTypes.isEmpty {
                    Text("No custom types yet — add one from a receipt's Edit screen (Type → Add Custom Type…).")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customTypes, id: \.self) { type in
                        Text(type)
                    }
                    .onDelete(perform: delete)
                }
            } footer: {
                Text("Swipe left to delete. Receipts already using a removed type keep it as-is — it just won't be offered for future receipts.")
            }
        }
        .navigationTitle("Custom Types")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func delete(at offsets: IndexSet) {
        CustomVendorTypeStore.remove(at: offsets)
        customTypes = CustomVendorTypeStore.customTypes
    }
}
