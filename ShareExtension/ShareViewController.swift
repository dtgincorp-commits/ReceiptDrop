import SwiftUI
import UIKit

/// Entry point of the share extension (named in Info.plist as
/// NSExtensionPrincipalClass). Hosts the SwiftUI sheet UI.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let rootView = ShareSheetView(
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "ReceiptDrop", code: 0,
                                       userInfo: [NSLocalizedDescriptionKey: "User cancelled"]))
            },
            extensionItems: (extensionContext?.inputItems as? [NSExtensionItem]) ?? [],
            onOpenMainApp: { [weak self] in
                // `UIApplication.shared` doesn't exist in an extension's
                // process — `extensionContext?.open` is the sandbox-approved
                // substitute, and only works for a URL scheme the host app
                // has registered (ReceiptDrop/Info.plist's CFBundleURLTypes).
                // First-run only: just brings the app forward and leaves the
                // card up, so no `completeRequest` here.
                guard let url = URL(string: "\(AppConstants.urlScheme)://") else { return }
                self?.extensionContext?.open(url, completionHandler: nil)
            },
            onComplete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onFinish: { [weak self] host, onCouldNotOpen in
                // Post-save exit: a green flash that lasts 800ms is easy to
                // miss entirely, and with no route into the app a successful
                // save was indistinguishable from nothing happening. Opening
                // the app at the destination the receipt actually went to
                // fixes that — but the extension still has to end, so
                // `completeRequest` happens from the open completion handler
                // (or immediately, if the URL couldn't even be built).
                guard let host, let url = URL(string: "\(AppConstants.urlScheme)://\(host)") else {
                    onCouldNotOpen()
                    return
                }
                self?.extensionContext?.open(url) { opened in
                    if opened {
                        self?.extensionContext?.completeRequest(returningItems: nil)
                    } else {
                        // `NSExtensionContext.open` is documented for Today
                        // widgets opening their containing app; iOS does not
                        // reliably grant it to a share extension, and it was
                        // observed refused on-device sharing from Messages'
                        // PDF viewer. Completing the request here anyway
                        // would recreate the original bug: the sheet
                        // vanishes and the user is dropped back into
                        // Messages with nothing confirming the receipt was
                        // even saved. So don't — leave the request open and
                        // let the sheet show a confirmation the user
                        // dismisses themselves. The completion handler isn't
                        // guaranteed to land on the main queue, and this
                        // drives SwiftUI state, so hop over explicitly.
                        DispatchQueue.main.async { onCouldNotOpen() }
                    }
                }
            }
        )

        let host = UIHostingController(rootView: rootView)
        // Clear on both, so ShareSheetView's card floats over the host app's
        // content instead of sitting on an opaque page. UIHostingController
        // paints a system background by default, which would defeat the
        // card's own background and shadow.
        host.view.backgroundColor = .clear
        view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
}
