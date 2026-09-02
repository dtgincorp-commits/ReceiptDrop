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
            onComplete: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            extensionItems: (extensionContext?.inputItems as? [NSExtensionItem]) ?? [],
            onOpenMainApp: { [weak self] in
                // `UIApplication.shared` doesn't exist in an extension's
                // process — `extensionContext?.open` is the sandbox-approved
                // substitute, and only works for a URL scheme the host app
                // has registered (ReceiptDrop/Info.plist's CFBundleURLTypes).
                guard let url = URL(string: "\(AppConstants.urlScheme)://") else { return }
                self?.extensionContext?.open(url, completionHandler: nil)
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
