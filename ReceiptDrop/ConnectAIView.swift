import SwiftUI
import SafariServices

// MARK: - Setup state

/// Tracks whether the user has been through (or skipped) the guided AI setup,
/// so the wizard shows itself exactly once on a fresh install and never nags
/// an existing user who already configured a provider by hand.
enum AISetupState {
    private static var defaults: UserDefaults { UserDefaults(suiteName: AppConstants.appGroupID)! }

    static var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: AppConstants.DefaultsKeys.hasCompletedAISetup) }
        set { defaults.set(newValue, forKey: AppConstants.DefaultsKeys.hasCompletedAISetup) }
    }

    /// True when the currently selected provider can actually run — either it
    /// needs no key (Apple On-Device, model ready) or its key/credentials are
    /// saved. Used to silently mark existing users as "done" instead of
    /// showing them a first-run wizard for a setup they finished long ago.
    static var currentProviderIsConfigured: Bool {
        ExtractionSettings.aiConfigured
    }
}

// MARK: - Wizard providers

/// The providers the wizard can walk a user through. Azure is deliberately
/// absent: its setup is a cloud-portal exercise (create a resource, find an
/// endpoint), not a "copy one key" flow, so it stays a Settings-only option
/// for users who know what they're doing.
private enum WizardProvider: String, CaseIterable, Identifiable, Hashable {
    case claude, openAI, gemini, perplexity

    var id: String { rawValue }

    var extractionProvider: ExtractionProvider {
        switch self {
        case .claude: return .claude
        case .openAI: return .openAI
        case .gemini: return .gemini
        case .perplexity: return .perplexity
        }
    }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openAI: return "ChatGPT"
        case .gemini: return "Google Gemini"
        case .perplexity: return "Perplexity"
        }
    }

    /// The company name as it appears on the key page, so the instructions
    /// match what the user actually sees in the browser.
    var consoleName: String {
        switch self {
        case .claude: return "Anthropic Console"
        case .openAI: return "OpenAI Platform"
        case .gemini: return "Google AI Studio"
        case .perplexity: return "Perplexity Settings"
        }
    }

    /// Deep link straight to the page where the key is created — landing the
    /// user directly on the "Create Key" button is the single biggest
    /// friction-remover in the whole flow.
    var keyURL: URL {
        switch self {
        case .claude: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .perplexity: return URL(string: "https://www.perplexity.ai/settings/api")!
        }
    }

    /// Typical key prefix — used only to warn about an obviously-wrong paste
    /// (e.g. an OpenAI key into the Claude flow), never to block: the live
    /// test below is the real judge.
    var keyPrefix: String {
        switch self {
        case .claude: return "sk-ant-"
        case .openAI: return "sk-"
        case .gemini: return "AIza"
        case .perplexity: return "pplx-"
        }
    }

    var keychainAccount: String {
        switch self {
        case .claude: return AppConstants.KeychainKeys.anthropicAPIKey
        case .openAI: return AppConstants.KeychainKeys.openAIAPIKey
        case .gemini: return AppConstants.KeychainKeys.geminiAPIKey
        case .perplexity: return AppConstants.KeychainKeys.perplexityAPIKey
        }
    }

    /// The one sentence that defuses "why am I paying twice?" — shown only
    /// for providers where the consumer subscription genuinely doesn't cover
    /// API use. Gemini gets a free-tier note instead.
    var billingNote: String? {
        switch self {
        case .claude:
            return "Good to know: a Claude.ai subscription is separate from this and isn't used here. You'll add a small amount of API credit (about $5) once — reading a receipt costs a fraction of a cent, so that typically lasts a year or more."
        case .openAI:
            return "Good to know: a ChatGPT Plus subscription is separate from this and isn't used here. You'll add a small amount of API credit (about $5) once — reading a receipt costs a fraction of a cent, so that typically lasts a year or more."
        case .perplexity:
            return "Good to know: a Perplexity subscription is separate from API access. Pro plans have sometimes included monthly API credit — check the API page after signing in. Reading a receipt costs a fraction of a cent."
        case .gemini:
            return nil
        }
    }

    var freeTierNote: String? {
        switch self {
        case .gemini:
            return "Gemini API keys have a genuine free tier — no credit card needed. This is the easiest paid-nothing option."
        default:
            return nil
        }
    }

    var subtitle: String {
        switch self {
        case .claude: return "I use Claude / have an Anthropic account"
        case .openAI: return "I use ChatGPT / have an OpenAI account"
        case .gemini: return "Free — no credit card needed"
        case .perplexity: return "I use Perplexity"
        }
    }

    func test(_ key: String) async throws {
        switch self {
        case .claude: try await APIKeyTester.testClaudeKey(key)
        case .openAI: try await APIKeyTester.testOpenAIKey(key)
        case .gemini: try await APIKeyTester.testGeminiKey(key)
        case .perplexity: try await APIKeyTester.testPerplexityKey(key)
        }
    }
}

// MARK: - Wizard root

/// Guided first-run AI setup: asks which AI the user already has (no jargon),
/// then walks them through getting a key with an in-app browser opened
/// directly on the key page, a paste button (no typing), and an automatic
/// live validation — ending in an unambiguous green "you're connected".
struct ConnectAIView: View {
    /// Called when setup finishes or is skipped — the presenter owns the
    /// sheet flag, and a pushed child can't reliably dismiss the sheet via
    /// `dismiss()` (that pops the navigation stack instead).
    let finish: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("ReceiptDrop uses AI to read the vendor, date, and amount off each receipt photo. Pick whichever you already use — or the free option. This takes about two minutes, once.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if appleOnDeviceReady {
                    Section {
                        Button {
                            ExtractionSettings.provider = .appleOnDevice
                            AISetupState.hasCompletedSetup = true
                            finish()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("Apple Intelligence")
                                        .font(.body.weight(.semibold))
                                    Text("RECOMMENDED")
                                        .font(.caption2.weight(.heavy))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green)
                                        .foregroundStyle(.white)
                                        .clipShape(Capsule())
                                }
                                Text("Built into this iPhone — no account, no key, nothing to set up. Tap and you're done.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                }

                Section {
                    ForEach(WizardProvider.allCases) { provider in
                        NavigationLink(value: provider) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.displayName)
                                    .font(.body.weight(.semibold))
                                Text(provider.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Which AI do you already use?")
                }

                Section {
                    NavigationLink(value: WizardProvider.gemini) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("None of these")
                                .font(.body.weight(.semibold))
                            Text("No problem — we'll set you up with Google Gemini. It's free and takes two minutes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Connect an AI")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WizardProvider.self) { provider in
                ProviderSetupView(provider: provider, finish: finish)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Set Up Later") {
                        AISetupState.hasCompletedSetup = true
                        finish()
                    }
                }
            }
        }
    }

    private var appleOnDeviceReady: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return FoundationModelsService.isModelReady }
        #endif
        return false
    }
}

// MARK: - Per-provider setup

/// One provider's guided key flow: billing honesty up top, an in-app browser
/// opened directly on the key page, then paste → auto-validate → green check.
private struct ProviderSetupView: View {
    let provider: WizardProvider
    let finish: () -> Void

    @State private var showBrowser = false
    @State private var state: SetupState = .idle
    @State private var prefixWarning = false
    /// Kept so "Try Again" retests without another paste, and "Save Anyway"
    /// (offline escape hatch) can still store it.
    @State private var lastKey = ""
    @State private var showManualEntry = false
    @State private var manualInput = ""

    private enum SetupState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            if let note = provider.billingNote {
                Section {
                    Label {
                        Text(note).font(.subheadline)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }
            if let note = provider.freeTierNote {
                Section {
                    Label {
                        Text(note).font(.subheadline)
                    } icon: {
                        Image(systemName: "gift.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            if state != .success {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        instructionRow(number: "1", text: "Tap the button below — it opens the \(provider.consoleName) right on the key page. Sign in if it asks.")
                        instructionRow(number: "2", text: "Tap “Create key” (any name is fine), then tap Copy.")
                        instructionRow(number: "3", text: "Come back here and tap Paste — we'll check it works automatically.")
                    }
                    .padding(.vertical, 4)

                    Button {
                        showBrowser = true
                    } label: {
                        Label("Open \(provider.consoleName)", systemImage: "safari")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } header: {
                    Text("Get your key")
                }
            }

            Section {
                switch state {
                case .idle:
                    pasteControls
                case .testing:
                    HStack {
                        ProgressView()
                        Text("Checking your key…").foregroundStyle(.secondary)
                    }
                case .success:
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Connected to \(provider.displayName)", systemImage: "checkmark.circle.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.green)
                        Text("Your key works and is saved securely in the iOS Keychain. Receipts will now be read automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            finish()
                        } label: {
                            Text("Start Scanning")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                case .failure(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("That key didn't work", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if prefixWarning {
                            Text("Heads up: \(provider.displayName) keys usually start with “\(provider.keyPrefix)…” — double-check you copied the right one.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("Try Again") { validate(lastKey) }
                        // Offline escape hatch — the test needs the internet,
                        // the key itself might still be fine.
                        Button("Save Without Testing") { saveWithoutTesting(lastKey) }
                            .font(.caption)
                        pasteControls
                    }
                }
            } header: {
                Text(state == .success ? "Done" : "Paste your key")
            } footer: {
                if state != .success {
                    Text("Your key is stored only in this iPhone's Keychain and never leaves the device except to call \(provider.displayName) directly.")
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBrowser) {
            SafariView(url: provider.keyURL)
                .ignoresSafeArea()
        }
    }

    /// PasteButton (not a programmatic clipboard read): it's the one way to
    /// take clipboard contents with zero permission prompt — the system shows
    /// no "allow paste?" banner because the tap itself is the consent.
    @ViewBuilder
    private var pasteControls: some View {
        HStack {
            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else { return }
                Task { @MainActor in validate(pasted) }
            }
            Spacer()
            Button(showManualEntry ? "Hide Manual Entry" : "Type It Instead") {
                showManualEntry.toggle()
            }
            .font(.caption)
        }
        if showManualEntry {
            SecureField("\(provider.keyPrefix)…", text: $manualInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Use This Key") { validate(manualInput) }
                .disabled(manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Circle())
            Text(text)
                .font(.subheadline)
        }
    }

    private func validate(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lastKey = key
        prefixWarning = !key.hasPrefix(provider.keyPrefix)
        state = .testing
        Task {
            do {
                try await provider.test(key)
                try KeychainHelper.setDetailed(key, for: provider.keychainAccount)
                await MainActor.run {
                    ExtractionSettings.provider = provider.extractionProvider
                    AISetupState.hasCompletedSetup = true
                    state = .success
                }
            } catch {
                await MainActor.run {
                    state = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func saveWithoutTesting(_ key: String) {
        guard !key.isEmpty else { return }
        do {
            try KeychainHelper.setDetailed(key, for: provider.keychainAccount)
            ExtractionSettings.provider = provider.extractionProvider
            AISetupState.hasCompletedSetup = true
            state = .success
        } catch {
            state = .failure(error.localizedDescription)
        }
    }
}

// MARK: - In-app browser

/// SFSafariViewController wrapper — an in-app browser sheet keeps the user's
/// context (swipe down to come back) and shares Safari's cookies, so they're
/// usually already signed in to the provider's console.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
