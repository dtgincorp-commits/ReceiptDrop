import SwiftUI

/// Whether the one-time "you can pick several, then tap ✓" tip should be
/// shown before opening the photo library.
///
/// Unlike `shouldPrimeCameraPermission`, this cannot lean on a system
/// permission state to make itself one-time — `PhotosPicker` runs
/// out-of-process and never resolves anything — so it needs its own flag.
/// Set on Continue rather than on appear, so a user who kills the app mid-tip
/// sees it once more rather than never.
func shouldShowPhotoPickerTip(
    defaults: UserDefaults = UserDefaults(suiteName: AppConstants.appGroupID)!
) -> Bool {
    !defaults.bool(forKey: AppConstants.DefaultsKeys.hasSeenPhotoPickerTip)
}

func markPhotoPickerTipSeen(
    defaults: UserDefaults = UserDefaults(suiteName: AppConstants.appGroupID)!
) {
    defaults.set(true, forKey: AppConstants.DefaultsKeys.hasSeenPhotoPickerTip)
}

/// Shown once, immediately before the system photo picker.
///
/// The thing a first-time user does not know is that receipts can be picked
/// in bulk — they select one, file it, and repeat, or they select several and
/// then cannot find how to confirm. Neither can be fixed inside the picker
/// itself: `PHPickerViewController` runs in another process, and there is no
/// API to highlight, annotate or animate anything in it. So the help has to
/// arrive just before it opens, which is also the moment it is useful — once
/// the picker is up, the user has either worked it out or has not.
///
/// Deliberately one screen with one button, and never shown again. A tip that
/// reappears is a tax on everyone who already knows.
struct PhotoPickerTipView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "square.stack.3d.down.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                // Decorative — the heading below says it in words.
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Pick as many as you like")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Tap every receipt you want to add — up to 20 at once — then tap the blue ✓ at the top right to bring them in.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("You'll only see this once.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            Spacer()

            Button(action: onContinue) {
                Text("Choose Photos")
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
