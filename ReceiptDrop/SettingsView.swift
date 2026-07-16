import SwiftUI

struct SettingsView: View {
    @StateObject private var categoryStore = CategoryStore.shared

    @State private var apiKeyInput = ""
    @State private var apiKeySaved = KeychainHelper.get(AppConstants.KeychainKeys.anthropicAPIKey) != nil
    @State private var newCategory = ""

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
                    ForEach(categoryStore.categories, id: \.self) { category in
                        Text(category)
                    }
                    .onDelete { categoryStore.remove(at: $0) }

                    HStack {
                        TextField("New category", text: $newCategory)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button {
                            categoryStore.add(newCategory)
                            newCategory = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Categories")
                } footer: {
                    Text("Each category gets its own folder and CSV log under Files > On My iPhone > ReceiptDrop. Swipe left to delete.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
