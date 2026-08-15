import SwiftUI

/// Lets the user type in a receipt's details by hand when there's no photo
/// or PDF to scan — same category/history bookkeeping as a scanned receipt,
/// just without a file (`SubmissionPipeline.recordManualEntry`).
struct ManualReceiptEntryView: View {
    let onCancel: () -> Void
    let onComplete: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var selectedCategory: String = ""
    @State private var vendor: String = ""
    @State private var amount: String = ""
    @State private var workDate: Date = Date()
    @State private var comments: String = ""
    @State private var message: String?
    @State private var isDuplicate = false

    // Same App Group store + key SettingsView writes, so the symbol shown
    // here always matches whatever the user picked.
    @AppStorage(AppConstants.DefaultsKeys.appCurrency, store: UserDefaults(suiteName: AppConstants.appGroupID))
    private var appCurrency: AppCurrency = .auto

    private var canSave: Bool {
        !vendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categoryStore.categories, id: \.self) { Text($0) }
                    }
                    .adaptiveCategoryPickerStyle(count: categoryStore.categories.count)
                }

                Section("Details") {
                    TextField("Merchant / Vendor", text: $vendor)
                    HStack {
                        Text(appCurrency.symbol)
                        TextField("Amount", text: $amount)
                            .keyboardType(.decimalPad)
                    }
                    DatePicker("Work Date", selection: $workDate, displayedComponents: .date)
                    TextField("Comments", text: $comments, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(isDuplicate ? Color.secondary : Color.red)
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Save").bold()
                            Spacer()
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle("Enter Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .onAppear {
            if selectedCategory.isEmpty {
                selectedCategory = categoryStore.categories.first ?? ""
            }
        }
    }

    private func save() {
        guard !selectedCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isDuplicate = false
            message = "Please pick a category before saving."
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        let normalizedAmount = Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)).map { String($0) } ?? amount

        do {
            _ = try SubmissionPipeline.recordManualEntry(
                vendor: vendor.trimmingCharacters(in: .whitespacesAndNewlines),
                workDate: formatter.string(from: workDate),
                amount: normalizedAmount,
                comments: comments.trimmingCharacters(in: .whitespacesAndNewlines),
                category: selectedCategory)
            onComplete()
        } catch let duplicate as SubmissionError {
            isDuplicate = true
            message = duplicate.localizedDescription
        } catch {
            isDuplicate = false
            message = error.localizedDescription
        }
    }
}
