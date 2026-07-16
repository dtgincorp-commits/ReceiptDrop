import SwiftUI

/// Shown after the Live Text scanner recognizes text: pick a category, review
/// the recognized text, and submit — Claude reads the text directly
/// (`SubmissionPipeline.runTextOnly`), no photo is saved.
struct ScannedTextSubmitView: View {
    let recognizedText: String
    let onCancel: () -> Void
    let onComplete: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var selectedCategory: String = ""
    @State private var submitState: SubmitState = .idle
    @State private var statusText: String = ""
    @State private var message: String?

    private enum SubmitState: Equatable {
        case idle
        case running
        case success
    }

    private var controlsDisabled: Bool {
        if case .idle = submitState { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recognized Text") {
                    Text(recognizedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                }

                Section("Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categoryStore.categories, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(controlsDisabled)
                }

                Section {
                    submitContent
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Scanned Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(controlsDisabled)
                }
            }
        }
        .onAppear {
            if selectedCategory.isEmpty {
                selectedCategory = categoryStore.categories.first ?? ""
            }
        }
    }

    @ViewBuilder
    private var submitContent: some View {
        switch submitState {
        case .idle:
            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    Text("Submit").bold()
                    Spacer()
                }
            }
            .disabled(selectedCategory.isEmpty)
        case .running:
            HStack {
                Spacer()
                ProgressView()
                Text(statusText).foregroundStyle(.secondary)
                Spacer()
            }
        case .success:
            HStack {
                Spacer()
                Label("Submitted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
            }
        }
    }

    private func submit() {
        guard !selectedCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Please pick a category before saving."
            return
        }

        message = nil
        submitState = .running
        statusText = SubmissionPipeline.Stage.reading.statusText

        Task {
            do {
                _ = try await SubmissionPipeline().runTextOnly(
                    ocrText: recognizedText, category: selectedCategory
                ) { stage in
                    statusText = stage.statusText
                }
                submitState = .success
                try? await Task.sleep(nanoseconds: 800_000_000)
                onComplete()
            } catch let duplicate as SubmissionError {
                message = duplicate.localizedDescription
                submitState = .success
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                onComplete()
            } catch {
                message = error.localizedDescription
                submitState = .idle
            }
        }
    }
}
