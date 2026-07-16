import SwiftUI
import VisionKit

/// Wraps VisionKit's `DataScannerViewController` — the same live, on-device
/// text recognition Notes' "Scan Text" uses: point the camera at the receipt,
/// recognized lines highlight in real time, no photo is ever captured.
struct LiveTextScannerView: UIViewControllerRepresentable {
    @Binding var recognizedText: String

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .accurate,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        if !uiViewController.isScanning {
            try? uiViewController.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(recognizedText: $recognizedText) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        @Binding var recognizedText: String
        init(recognizedText: Binding<String>) { _recognizedText = recognizedText }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            update(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            update(allItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            update(allItems)
        }

        private func update(_ items: [RecognizedItem]) {
            recognizedText = items.compactMap { item -> String? in
                if case .text(let text) = item { return text.transcript }
                return nil
            }.joined(separator: "\n")
        }
    }
}

/// Full-screen host for the live scanner: camera preview, a close button, and
/// an "Insert" pill that becomes enabled once any text is recognized —
/// mirrors the Notes app's Scan Text UI.
struct LiveTextScanScreen: View {
    let onInsert: (String) -> Void
    let onCancel: () -> Void

    @State private var recognizedText = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveTextScannerView(recognizedText: $recognizedText)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .padding()
                }
                Spacer()
            }

            Button {
                onInsert(recognizedText)
            } label: {
                Text("Insert")
                    .bold()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Theme.skyBlueBright, in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .padding(.bottom, 36)
        }
    }
}
