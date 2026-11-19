import Foundation
import WebKit

/// Only the source of an image is transported here, never credentials for VCP APIs.
/// This handler is attached only to the isolated message WebView, not to the browser.
@MainActor final class IslandImageScheme: NSObject, WKURLSchemeHandler {
    static let name = "vchat-image"
    private let store: RemoteImageStore
    init(store: RemoteImageStore = .shared) { self.store=store; super.init() }
    var stickers = StickerContext()
    var mediaEnabled = false
    private var tasks: [ObjectIdentifier:Task<Void,Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard mediaEnabled, let locator=urlSchemeTask.request.url, locator.host=="asset",
              let encoded=URLComponents(url:locator,resolvingAgainstBaseURL:false)?.percentEncodedQuery,
              encoded.utf8.count <= 32000, let raw=encoded.removingPercentEncoding else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
        }
        let context = stickers
        tasks[id] = Task {
            do {
                guard let target=await StickerResolver.shared.url(raw,in:context),target.scheme?.lowercased()=="https", !Task.isCancelled else {
                    throw URLError(.unsupportedURL)
                }
                let value=try await store.resource(target)
                guard !Task.isCancelled, tasks.removeValue(forKey:id) != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url:locator,mimeType:value.mime,expectedContentLength:value.data.count,textEncodingName:nil))
                urlSchemeTask.didReceive(value.data);urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled,tasks.removeValue(forKey:id) != nil else { return }
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey:ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    func invalidate() {
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        stickers = StickerContext(); mediaEnabled=false
    }
}
