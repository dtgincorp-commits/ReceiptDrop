import SwiftUI

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

                APIKeySection(
                    title: "Anthropic API Key", placeholder: "sk-ant-…",
                    account: AppConstants.KeychainKeys.anthropicAPIKey,
                    footer: "Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the Anthropic API.")

                APIKeySection(
                    title: "OpenAI API Key", placeholder: "sk-…",
                    account: AppConstants.KeychainKeys.openAIAPIKey,
                    footer: "Only needed if AI Provider above is set to OpenAI.")

                APIKeySection(
                    title: "Google Gemini API Key", placeholder: "AIza…",
                    account: AppConstants.KeychainKeys.geminiAPIKey,
                    footer: "Only needed if AI Provider above is set to Google Gemini.")

                Section {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        Label("Categories", systemImage: "folder.badge.gearshape")
                    }
                } footer: {
                    Text("Add or remove categories, open their CSV logs, and run maintenance.")
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
