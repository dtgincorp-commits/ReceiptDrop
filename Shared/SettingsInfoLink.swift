import SwiftUI

/// Long-form explanation lifted out of a `Form` section footer and put
/// behind a tap.
///
/// Settings had accumulated ~16 footers over 120 characters, two of them
/// past 650 — enough that a single footer filled more than a phone screen
/// and the controls it described scrolled out of view. The text itself is
/// worth keeping (it heads off real support questions about why a receipt
/// wasn't read, what Offline Mode actually blocks, what a restore will and
/// won't overwrite), so this collapses it rather than deleting it: the
/// footer keeps one plain sentence, and everything else moves into a sheet
/// reachable from a small "Learn more" row in the same section — next to
/// the control it explains, not buried in a separate Help screen.
struct SettingsInfoTopic: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

extension View {
    /// Presents the long-form text for whichever topic is set. Attach once
    /// per screen; drive it with `SettingsInfoButton`.
    func settingsInfoSheet(topic: Binding<SettingsInfoTopic?>) -> some View {
        sheet(item: topic) { info in
            NavigationStack {
                ScrollView {
                    Text(info.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(info.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { topic.wrappedValue = nil }
                    }
                }
            }
            // Medium by default so the sheet reads as a quick aside rather
            // than a full screen the user has to navigate back out of.
            .presentationDetents([.medium, .large])
        }
    }
}

/// The "Learn more" row itself — deliberately `.caption`/secondary so it
/// reads as an aside within the section rather than competing with the
/// actual settings controls above it.
struct SettingsInfoButton: View {
    let title: String
    /// Named `detail`, not `body` — `body` is `View`'s own requirement, and
    /// a stored property of that name silently shadows it into a compile
    /// error rather than anything obvious.
    let detail: String
    @Binding var topic: SettingsInfoTopic?

    var body: some View {
        Button {
            topic = SettingsInfoTopic(title: title, body: detail)
        } label: {
            Label("Learn more", systemImage: "info.circle")
                .font(.caption)
        }
    }
}
