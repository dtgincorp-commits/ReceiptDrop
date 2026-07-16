import SwiftUI

struct SettingsView: View {
    @State private var apiKeyInput = ""
    @State private var apiKeySaved = KeychainHelper.get(AppConstants.KeychainKeys.anthropicAPIKey) != nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if apiKeySaved {
                        HStack {
                            Label("API key saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                KeychainHelper.delete(AppConstants.KeychainKeys.anthropicAPIKey)
                                apiKeySaved = false
                            }
                        }
                    } else {
                        SecureField("sk-ant-…", text: $apiKeyInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save to Keychain") {
                            let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            if KeychainHelper.set(trimmed, for: AppConstants.KeychainKeys.anthropicAPIKey) {
                                apiKeyInput = ""
                                apiKeySaved = true
                            }
                        }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Anthropic API Key")
                } footer: {
                    Text("Stored in the iOS Keychain, shared with the share extension. Never leaves this device except to call the Anthropic API.")
                }

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
