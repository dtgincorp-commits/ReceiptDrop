import AVFoundation
import SwiftUI

/// Whether the camera-permission priming screen should be shown before
/// triggering whatever actually pops the system camera dialog.
///
/// iOS only ever asks once per install: the very first camera access
/// attempt (`UIImagePickerController` with `.camera`,
/// `VNDocumentCameraViewController`, or `AVCaptureDevice.requestAccess`)
/// shows the system prompt and permanently resolves it to `.authorized` or
/// `.denied`. That resolution is exactly what makes this naturally
/// one-time by construction: `.notDetermined` can only be true before the
/// user has ever answered, so once they have (either way), this returns
/// `false` forever after — no separate "have I shown this before" flag is
/// needed. The one case that could reset it is a full device restore
/// (fresh install, no keychain/UserDefaults survive), which is exactly the
/// case where re-priming is correct anyway: it's a new install as far as
/// the OS permission system is concerned.
func shouldPrimeCameraPermission(for status: AVAuthorizationStatus) -> Bool {
    status == .notDetermined
}

/// Convenience wrapper reading the live status, for call sites that don't
/// need to inject a status for testing.
func shouldPrimeCameraPermission() -> Bool {
    shouldPrimeCameraPermission(for: AVCaptureDevice.authorizationStatus(for: .video))
}

/// The one shared "why we need your camera" screen, shown immediately
/// before whichever flow is about to trigger the system camera dialog.
/// There are four real trigger points in the app, all wired through this
/// same screen:
///   - `NewReceiptView` / `.camera` — `UIImagePickerController(.camera)`
///   - `NewReceiptView` / `.scanDocument` — `VNDocumentCameraViewController`
///   - `NewReceiptView` / `.scanText` — VisionKit's `DataScannerViewController`
///     (a live camera feed, same as the other two even though no photo is
///     ever captured)
///   - `BillCaptureView` — a direct `AVCaptureDevice.requestAccess(for: .video)`
/// Every call site presents this the same way: check
/// `shouldPrimeCameraPermission()` first, and only if true, show this
/// screen with `onContinue` wired to the real trigger — never skip
/// straight to the system dialog with no context, since a cold prompt is
/// what drives the reflexive "Don't Allow" taps this exists to avoid.
///
/// The Photos library picker (`PhotosPicker`/`PHPickerViewController`,
/// used for both "choose from library" and "add extra photos") is
/// deliberately NOT primed: it runs out-of-process and never shows a
/// system permission dialog at all on iOS 16+, which is also why
/// `project.yml` declares `NSCameraUsageDescription` but no
/// `NSPhotoLibraryUsageDescription`. Priming it would be priming for a
/// prompt that never appears.
struct CameraPermissionPrimingView: View {
    /// Invoked when the user taps Continue — this is what actually causes
    /// the system dialog to appear. Never call this speculatively; it's
    /// meant to fire exactly once, right after the tap.
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "camera.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                // Purely decorative — the heading right below says the same
                // thing in words.
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Receipts4Tax needs your camera")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("To scan a receipt, we need access to your camera. Nothing you photograph ever leaves your phone unless you connect an AI provider yourself.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .padding()
    }
}
