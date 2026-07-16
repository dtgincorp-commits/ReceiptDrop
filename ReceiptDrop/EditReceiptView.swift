import PhotosUI
import SwiftUI

/// Edits an existing receipt: category, vendor, amount, work date, comments,
/// and optionally attaches/replaces the photo. Delegates all the file/CSV/
/// history bookkeeping to `SubmissionPipeline.updateEntry`.
struct EditReceiptView: View {
    let entry: HistoryEntry
    let onCancel: () -> Void
    let onComplete: () -> Void

    @StateObject private var categoryStore = CategoryStore.shared
    @State private var selectedCategory: String
    @State private var vendor: String
    @State private var amount: String
    @State private var workDate: Date
    @State private var comments = ""
    @State private var message: String?
    @State private var isSaving = false

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var newPhotoData: Data?
    @State private var newPhotoImage: UIImage?

    @State private var extraPickerItems: [PhotosPickerItem] = []
    @State private var remainingExtraFiles: [String]
    @State private var newExtraImages: [(image: UIImage, data: Data)] = []

    init(entry: HistoryEntry, onCancel: @escaping () -> Void, onComplete: @escaping () -> Void) {
        self.entry = entry
        self.onCancel = onCancel
        self.onComplete = onComplete
        _selectedCategory = State(initialValue: entry.category)
        _vendor = State(initialValue: entry.vendor)
        _amount = State(initialValue: entry.amount)
        _workDate = State(initialValue: EditReceiptView.parseWorkDate(entry.workDate))
        _remainingExtraFiles = State(initialValue: entry.extraFiles)
    }

    private var isPlaceholder: Bool { SubmissionPipeline.isPlaceholderLabel(entry.receiptLink) }

    private var canSave: Bool {
        !vendor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                attachmentsSection

                Section("Category") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(categoryStore.categories, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isSaving)
                }

                Section("Details") {
                    TextField("Merchant / Vendor", text: $vendor).disabled(isSaving)
                    HStack {
                        Text("$")
                        TextField("Amount", text: $amount)
                            .keyboardType(.decimalPad)
                    }
                    .disabled(isSaving)
                    DatePicker("Work Date", selection: $workDate, displayedComponents: .date)
                        .disabled(isSaving)
                    TextField("Comments", text: $comments, axis: .vertical)
                        .lineLimit(2...4)
                        .disabled(isSaving)
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Save Changes").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .navigationTitle("Edit Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).disabled(isSaving)
                }
            }
        }
        .onAppear {
            comments = LocalReceiptStore.comments(
                category: entry.category, vendor: entry.vendor, workDate: entry.workDate,
                amount: entry.amount, receiptFilename: entry.receiptLink)
        }
        .onChange(of: photoPickerItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    newPhotoData = data
                    newPhotoImage = image
                }
            }
        }
        .onChange(of: extraPickerItems) { items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        newExtraImages.append((image, data))
                    }
                }
                extraPickerItems = []
            }
        }
    }

    @ViewBuilder
    private var photoSection: some View {
        Section("Photo") {
            HStack {
                Spacer()
                if let newPhotoImage {
                    Image(uiImage: newPhotoImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let existingImage {
                    Image(uiImage: existingImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Label(isPlaceholder ? "No photo attached" : "PDF attached", systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            PhotosPicker(isPlaceholder ? "Add Photo" : "Replace Photo",
                        selection: $photoPickerItem, matching: .images)
                .disabled(isSaving)
        }
    }

    @ViewBuilder
    private var attachmentsSection: some View {
        Section {
            attachmentsStrip
            PhotosPicker("Add Photos", selection: $extraPickerItems, matching: .images)
                .disabled(isSaving)
        } header: {
            Text("Attachments")
        } footer: {
            Text("Extra pages or supporting photos for this receipt — shown when you preview it, not sent to Claude.")
        }
    }

    @ViewBuilder
    private var attachmentsStrip: some View {
        if !remainingExtraFiles.isEmpty || !newExtraImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(remainingExtraFiles, id: \.self) { filename in
                        attachmentThumbnail(existingImage(for: filename)) {
                            remainingExtraFiles.removeAll { $0 == filename }
                        }
                    }
                    ForEach(newExtraImages.indices, id: \.self) { index in
                        attachmentThumbnail(newExtraImages[index].image) {
                            newExtraImages.remove(at: index)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func attachmentThumbnail(_ image: UIImage?, onRemove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
            .disabled(isSaving)
        }
    }

    private func existingImage(for filename: String) -> UIImage? {
        guard let url = LocalReceiptStore.existingFileURL(category: entry.category, filename: filename),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private var existingImage: UIImage? {
        guard !isPlaceholder,
              let url = LocalReceiptStore.existingFileURL(category: entry.category, filename: entry.receiptLink),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func save() {
        guard !selectedCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Please pick a category before saving."
            return
        }

        let normalizedAmount = Double(amount.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { String($0) } ?? amount

        var newPhoto: (data: Data, kind: ReceiptKind)?
        if let newPhotoData, let jpeg = UIImage(data: newPhotoData)?.jpegData(compressionQuality: 0.85) {
            newPhoto = (jpeg, .image)
        }

        message = nil
        isSaving = true

        let newExtraPhotos: [(data: Data, kind: ReceiptKind)] = newExtraImages.compactMap { entry in
            guard let jpeg = entry.image.jpegData(compressionQuality: 0.85) else { return nil }
            return (jpeg, .image)
        }
        let removedExtras = entry.extraFiles.filter { !remainingExtraFiles.contains($0) }

        Task {
            do {
                _ = try SubmissionPipeline.updateEntry(
                    old: entry,
                    newCategory: selectedCategory,
                    newVendor: vendor.trimmingCharacters(in: .whitespacesAndNewlines),
                    newWorkDate: LocalReceiptStore.dateString(workDate),
                    newAmount: normalizedAmount,
                    newComments: comments.trimmingCharacters(in: .whitespacesAndNewlines),
                    newPhoto: newPhoto,
                    newExtraPhotos: newExtraPhotos,
                    removedExtraFiles: removedExtras)
                LocalReceiptStore.drainSpoolIntoDocuments()
                onComplete()
            } catch {
                message = error.localizedDescription
                isSaving = false
            }
        }
    }

    private static func parseWorkDate(_ raw: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = AppConstants.sheetDateFormat
        return formatter.date(from: raw) ?? Date()
    }
}
