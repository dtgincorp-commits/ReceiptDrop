import Photos
import SwiftUI
import UIKit

/// Settings entry for the "Receipts Only" album — creates it, says what is
/// waiting in it, and opens the review tray.
///
/// Every state the photo permission can be in is spelled out here rather than
/// collapsed into one button, because two of them are dead ends the user can
/// only escape through iOS Settings. In particular "Limited" access looks
/// like success — the app has *a* permission — while making the feature
/// impossible, since user albums are invisible under it. Left unexplained,
/// that reads as the app being broken.
struct ReceiptAlbumSettingsSection: View {
    @State private var availability = ReceiptAlbumService.availability
    @State private var albumExists = false
    @State private var waitingCount = 0
    @State private var isWorking = false
    @State private var showImporter = false

    var body: some View {
        Section {
            switch availability {
            case .notDetermined:
                createButton
            case .authorized:
                if albumExists {
                    Button {
                        showImporter = true
                    } label: {
                        HStack {
                            Label("Receipts Only Album", systemImage: "photo.stack")
                            Spacer()
                            Text(waitingCount == 0 ? "Empty" : "\(waitingCount) waiting")
                                .foregroundStyle(waitingCount == 0 ? .secondary : Color.accentColor)
                        }
                    }
                } else {
                    createButton
                }
            case .limited:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Full photo access needed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    // Precise about why, because "allow access" is not
                    // actionable when the user believes they already did.
                    Text("You've allowed access to selected photos only. Albums aren't visible under that setting, so this feature can't see the album at all. It needs \"All Photos\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: openSystemSettings)
                        .font(.caption.weight(.semibold))
                }
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Photo access is off", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Open Settings", action: openSystemSettings)
                        .font(.caption.weight(.semibold))
                }
            }
        } header: {
            Text("Photo Album Import")
        } footer: {
            Text("Creates an album called \"\(ReceiptAlbumService.albumTitle)\" in Photos. Add receipt photos to it whenever you like — from Photos, no need to open this app — and file them here in one go. Photos are only read when you tap Import, and nothing leaves your phone until then.")
        }
        .sheet(isPresented: $showImporter, onDismiss: refresh) {
            ReceiptAlbumImportView(onDone: { showImporter = false })
        }
        .onAppear(perform: refresh)
    }

    private var createButton: some View {
        Button {
            Task { await createAlbum() }
        } label: {
            HStack {
                Label("Create \"\(ReceiptAlbumService.albumTitle)\" Album", systemImage: "rectangle.stack.badge.plus")
                if isWorking {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isWorking)
    }

    private func createAlbum() async {
        isWorking = true
        defer { isWorking = false }

        if availability == .notDetermined {
            availability = await ReceiptAlbumService.requestAccess()
        }
        guard availability == .authorized else { return }
        _ = try? await ReceiptAlbumService.createAlbum()
        refresh()
    }

    private func refresh() {
        availability = ReceiptAlbumService.availability
        albumExists = ReceiptAlbumService.findAlbum() != nil
        waitingCount = ReceiptAlbumService.pendingAssets().count
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
