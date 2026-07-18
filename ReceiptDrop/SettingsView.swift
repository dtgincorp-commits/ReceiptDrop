import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var selectedProvider: ExtractionProvider = ExtractionSettings.provider
    @State private var selectedMode: ExtractionMode = ExtractionSettings.mode

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
                } header: {
                    Text("Receipt Extraction")
                } footer: {
                    Text("\"On-Device OCR Text\" reads the receipt on your phone for free and sends only the text — faster and cheaper. Hard-to-read receipts automatically retry with the full image. Apple On-Device requires iOS 26 + Apple Intelligence, not available on this device/toolchain yet.")
                }

                // Only the currently selected provider's key field is shown —
                // no point cluttering Settings with fields for providers
                // that aren't in use.
                switch selectedProvider {
                case .claude:
                    APIKeySection(
                        title: "Anthropic API Key", placeholder: "sk-ant-…",
                        account: AppConstants.KeychainKeys.anthropicAPIKey,
                        footer: "Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the Anthropic API.")
                case .openAI:
                    APIKeySection(
                        title: "OpenAI API Key", placeholder: "sk-…",
                        account: AppConstants.KeychainKeys.openAIAPIKey,
                        footer: "Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the OpenAI API.")
                case .gemini:
                    APIKeySection(
                        title: "Google Gemini API Key", placeholder: "AIza…",
                        account: AppConstants.KeychainKeys.geminiAPIKey,
                        footer: "Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the Gemini API.")
                case .appleOnDevice:
                    EmptyView()
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
            }
            .navigationTitle("Settings")
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

    @State private var input = ""
    @State private var saved: Bool

    init(title: String, placeholder: String, account: String, footer: String) {
        self.title = title
        self.placeholder = placeholder
        self.account = account
        self.footer = footer
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
                    }
                }
            } else {
                SecureField(placeholder, text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save to Keychain") {
                    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if KeychainHelper.set(trimmed, for: account) {
                        input = ""
                        saved = true
                    }
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}

// MARK: - Archive & Backup

struct ArchiveBackupView: View {
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
    @State private var localBackups: [URL] = LocalReceiptStore.listBackups()

    private var years: [Int] { ArchiveBackupService.availableYears() }
    private var months: [Int] { selectedYear.map(ArchiveBackupService.availableMonths(inYear:)) ?? [] }

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
            case .success(let url): restore(from: url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            localBackups = LocalReceiptStore.listBackups()
            lastBackupDate = BackupSettings.lastBackupDate
            reminderFrequency = BackupSettings.reminderFrequency
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
                Text("No backups on this phone yet — tap \"Back Up Now\" above.")
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
                showRestorePicker = true
            } label: {
                Label("Restore from Other Location…", systemImage: "arrow.down.doc")
            }
            .disabled(isWorking)

            if let restoreMessage {
                Text(restoreMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Restore")
        } footer: {
            Text("Tap a backup to restore it — never overwrites or deletes anything already on this phone, only adds what's missing. Swipe to delete a backup you no longer need. \"Restore from Other Location\" opens the Files picker, for backups saved to iCloud Drive or from another phone. Your API key isn't stored in backups; re-enter it in Settings after restoring on a new phone.")
        }
    }

    private func restore(from url: URL) {
        errorMessage = nil
        restoreMessage = nil
        isWorking = true
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try RestoreService.restore(zipURL: url)
                await MainActor.run {
                    isWorking = false
                    restoreMessage = "Restored \(summary.receiptsRestored) receipt\(summary.receiptsRestored == 1 ? "" : "s") (\(summary.receiptsSkipped) already present)."
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
            Text("Periods are based on each receipt's work date (falling back to the scan date if missing). Creates a zip of that period's photos, attachments, and a CSV, then lets you save it via AirDrop, iCloud Drive, or Files. Nothing is deleted from the app.")
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
                    if isWorking { ProgressView() } else { Text("Back Up Now") }
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
                    label = "ReceiptDrop_\(year)"
                    entries = ArchiveBackupService.entries(inYear: year)
                case .month:
                    guard let year, let month else { isWorking = false; return }
                    label = "ReceiptDrop_\(year)-\(String(format: "%02d", month))"
                    entries = ArchiveBackupService.entries(inYear: year, month: month)
                case .custom:
                    label = "ReceiptDrop_\(LocalReceiptStore.dateString(start))_to_\(LocalReceiptStore.dateString(end))"
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

    private static func backupDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func backupSizeString(for url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
