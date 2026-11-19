#if os(iOS)
import SwiftUI
import WebKit
import VChatCore

/// A local renderer with a native data source. Chat credentials never enter the page.
public struct FieldAtlasView: View {
    private let configuration: ConnectionConfiguration
    private let key: String
    @AppStorage("atlas.responseLimitMiB") private var responseLimit = FieldAtlasResponseLimit.standard
    @State private var revision = 0

    public init(configuration: ConnectionConfiguration, key: String) {
        self.configuration = configuration
        self.key = key
    }

    public var body: some View {
        Group {
            if let page = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "FieldAtlas") {
                AtlasPage(page: page, configuration: configuration, key: key, responseLimit: responseLimit)
                    .id(responseLimit).id(revision)
            } else {
                ContentUnavailableView("场图资源缺失", systemImage: "exclamationmark.triangle")
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("双曲场图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Picker("单次响应上限", selection: $responseLimit) {
                    ForEach(FieldAtlasResponseLimit.allCases, id: \.self) { limit in
                        Text(limit == .unlimited ? "不限" : "\(limit.rawValue) MiB").tag(limit)
                    }
                }
            } label: { Label("场图响应上限", systemImage: "slider.horizontal.3") }
            Button { revision += 1 } label: { Label("重新加载场图", systemImage: "arrow.clockwise") }
        }
    }
}

private struct AtlasPage: UIViewRepresentable {
    let page: URL
    let configuration: ConnectionConfiguration
    let key: String
    let responseLimit: FieldAtlasResponseLimit

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, client: FieldAtlasClient(configuration: configuration, key: key, responseLimit: responseLimit))
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "atlasRead")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "atlasRead", contentWorld: .page)
        view.navigationDelegate = nil
        view.stopLoading()
        coordinator.client.close()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        let page: URL
        let client: FieldAtlasClient
        init(page: URL, client: FieldAtlasClient) { self.page = page.standardizedFileURL; self.client = client }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url?.standardizedFileURL == page ? .allow : .cancel)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == page,
                  let route = message.body as? String else { replyHandler(nil, "请求来源无效"); return }
            Task {
                do { replyHandler(try await client.get(route), nil) }
                catch { replyHandler(nil, error.localizedDescription) }
            }
        }
    }
}
#endif
