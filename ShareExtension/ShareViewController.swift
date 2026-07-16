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
            extensionItems: (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        )

        let host = UIHostingController(rootView: rootView)
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
}
