import UIKit
import Social
import UniformTypeIdentifiers
import MobileCoreServices

/// Share/Action Extension target: appears in the iOS share sheet for any
/// image (e.g. the user takes a screenshot, taps Share, picks
/// "Translate Screen Text"). Writes the image into the same App Group
/// container SampleHandler.swift uses, then deep-links back into the
/// main app so it can immediately run OCR + translation — no broadcast
/// needed for this "quick capture" path.
class ShareViewController: SLComposeServiceViewController {

    private let appGroupId = "group.com.example.screentranslate"

    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        guard
            let item = extensionContext?.inputItems.first as? NSExtensionItem,
            let provider = item.attachments?.first
        else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        let typeIdentifier = UTType.image.identifier
        if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] data, _ in
                self?.handleLoadedImage(data)
            }
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func handleLoadedImage(_ data: NSSecureCoding?) {
        var image: UIImage?
        if let url = data as? URL, let d = try? Data(contentsOf: url) {
            image = UIImage(data: d)
        } else if let img = data as? UIImage {
            image = img
        } else if let d = data as? Data {
            image = UIImage(data: d)
        }

        guard
            let uiImage = image,
            let pngData = uiImage.pngData(),
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId)
        else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        let frameURL = containerURL.appendingPathComponent("latest_frame.png")
        let metaURL = containerURL.appendingPathComponent("latest_frame.json")
        try? pngData.write(to: frameURL)
        let meta = "{\"width\":\(Int(uiImage.size.width)),\"height\":\(Int(uiImage.size.height))}"
        try? meta.write(to: metaURL, atomically: true, encoding: .utf8)

        // Deep link back into the host app; AppDelegate.swift handles
        // `screentranslate://capture` by immediately calling
        // captureFromShareExtension() -> recognizeText() -> showOverlay().
        if let url = URL(string: "screentranslate://capture") {
            openMainApp(url)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// UIApplication.shared isn't available in an extension target — walk
    /// the responder chain for the `openURL:` selector, the standard
    /// workaround Apple documents for share extensions that need to
    /// hand off to their host app.
    private func openMainApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while responder != nil {
            if responder!.responds(to: selector) {
                responder!.perform(selector, with: url)
                return
            }
            responder = responder?.next
        }
    }

    override func configurationItems() -> [Any]! { [] }
}
