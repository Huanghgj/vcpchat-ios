import SwiftUI
import UIKit
import WebKit
import XCTest
import SQLite3
@testable import VChatCore
import VChatRendering
@testable import VChat

final class PhoneInteractionTests: XCTestCase {
    @MainActor private func host<V: View>(_ content: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    @MainActor private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let found = root as? T { return found }
        for child in root.subviews {
            if let found = find(type, in: child) { return found }
        }
        return nil
    }

    @MainActor private func eventually(_ description: String, file: StaticString = #filePath, line: UInt = #line, _ check: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        while clock.now < deadline {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTFail("Timed out: " + description, file: file, line: line)
    }

    @MainActor func testComposerManualDismissalAndSendDismissal() async throws {
        let state = KeyboardFixtureState()
        state.draft = ""
        let window = try host(KeyboardFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("editor is mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("草稿")
        try await eventually("typed draft reached the model") { state.draft == "草稿" }
        let bar = try XCTUnwrap(editor.inputAccessoryView as? UIToolbar)
        let hide = try XCTUnwrap(bar.items?.first { $0.title == "收起键盘" })
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(hide.action), to: hide.target, from: hide, for: nil))
        XCTAssertFalse(editor.isFirstResponder, "manual dismissal keeps the draft without sending it")
        XCTAssertEqual(editor.text, "草稿")
        XCTAssertEqual(state.draft, "草稿")
        XCTAssertTrue(state.sent.isEmpty)

        XCTAssertTrue(editor.becomeFirstResponder())
        state.acceptsSend = false
        editor.insertText("\n")
        XCTAssertTrue(editor.isFirstResponder, "rejected send should keep focus")
        XCTAssertEqual(editor.text, "草稿")
        XCTAssertTrue(state.sent.isEmpty)

        state.acceptsSend = true
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("！")
        editor.insertText("\n")
        XCTAssertEqual(state.sent, ["草稿！"], "Return must submit the latest text exactly once")
        XCTAssertFalse(editor.isFirstResponder, "accepted send should release keyboard focus")
        try await eventually("accepted draft cleared from the visible editor") { editor.text.isEmpty }
    }

    @MainActor func testReturnCanStillInsertANewline() async throws {
        let state = KeyboardFixtureState()
        let window = try host(KeyboardFixture(state: state, enterSends: false))
        defer { window.isHidden = true }
        try await eventually("newline-mode editor is mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("\n")
        XCTAssertEqual(editor.text, "草稿\n")
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertTrue(state.sent.isEmpty)
    }

    @MainActor func testComposerKeepsFocusUntilMessageAndOutboxCommit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("chat.sqlite").path
        let store = try await ChatStore.open(path: path)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_outbox BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT,'outbox unavailable'); END", nil, nil, nil), SQLITE_OK)

        let model = ChatViewModel()
        let agent = VCPAgent(), topic = ChatTopic(ownerId: agent.id, title: "本机入队")
        let room = ChatRoom(id: topic.id, messages: [])
        model.store = store; model.agents = [agent]; model.topics = [topic]
        model.activeTopicID = topic.id; model.rooms = [topic.id: room]; model.apiKey = "fixture"
        let keyboard = ComposerKeyboard()
        let composer = NativeComposer(text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                                     enterSends: true, insertNewline: 0, keyboard: keyboard) {
            model.send {
                keyboard.dismiss()
                room.cancellation = .stopped  // Stop before network generation, after the real commit.
            }
        }
        let window = try host(composer)
        defer { window.isHidden = true }
        try await eventually("composer mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("重试"); editor.insertText("\n")
        await room.generation?.value
        let rolledBack = try await store.messages(topicID: topic.id)
        XCTAssertTrue(room.error?.contains("outbox unavailable") == true)
        XCTAssertTrue(rolledBack.isEmpty)
        XCTAssertEqual(room.draft, "重试")
        XCTAssertTrue(editor.isFirstResponder)

        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_outbox", nil, nil, nil), SQLITE_OK)
        editor.insertText("\n")
        await room.generation?.value
        let stored = try await store.messages(topicID: topic.id)
        let pending = try await store.pending()
        XCTAssertEqual(stored.map(\.content), ["重试"])
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(room.draft, "")
        XCTAssertFalse(editor.isFirstResponder)
    }

    func testAtlasKeepsConfiguredPrefixAndEncodedQuery() throws {
        for base in ["https://example.invalid/vcp", "https://example.invalid/vcp/v1", "https://example.invalid/vcp/v1/chat/completions"] {
            let config = ConnectionConfiguration(server: base)
            let url = try FieldAtlasClient.endpoint("/messages?q=%E6%98%A5%26%23", configuration: config)
            XCTAssertEqual(url.absoluteString, "https://example.invalid/vcp/api/plugins/WarpedFieldAtlas/messages?q=%E6%98%A5%26%23")
            XCTAssertThrowsError(try FieldAtlasClient.endpoint("/unlisted", configuration: config))
        }
    }

    func testAtlasResponseLimitCanBeRaisedOrRemoved() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [AtlasResponseFixture.self]
        for limit in [FieldAtlasResponseLimit.standard, .larger, .unlimited] {
            let client = FieldAtlasClient(configuration: .init(server: "https://atlas.invalid/vcp"), key: "fixture", responseLimit: limit, sessionConfiguration: session)
            defer { client.close() }
            do {
                let body = try await client.get("/status")
                XCTAssertNotEqual(limit, .standard)
                XCTAssertEqual(body, "{}")
            } catch {
                XCTAssertEqual(limit, .standard)
                XCTAssertTrue(error.localizedDescription.contains("32 MiB"))
            }
        }
    }

    @MainActor func testBubbleHostIsTransparentInBothThemes() async throws {
        let web = WKWebView()
        let sample = #"<div id="vcp-root" style="background:#faf5ef;color:#336699;border-radius:16px">卡片</div><p>正文</p>"#
        for dark in [false, true] {
            let page = HTMLIslandPolicy.document(sample, motion: false, media: false, dark: dark)
            web.loadHTMLString(page, baseURL: nil)
            try await eventually("bubble page loaded") { !web.isLoading }
            let result = try await web.evaluateJavaScript("""
                (() => { const css = el => getComputedStyle(el), card = css(document.querySelector('#vcp-root'));
                    return [css(document.documentElement).backgroundColor, css(document.body).backgroundColor,
                            css(document.querySelector('p')).color, card.backgroundColor, card.color, card.borderRadius]; })()
                """) as? [String]
            XCTAssertEqual(result, ["rgba(0, 0, 0, 0)", "rgba(0, 0, 0, 0)", dark ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)",
                                    "rgb(250, 245, 239)", "rgb(51, 102, 153)", "16px"])
        }
    }

    @MainActor func testBundledAtlasCanCallNativeBridge() async throws {
        let window = try host(FieldAtlasView(configuration: .init(server: "https://example.invalid"), key: ""))
        defer { window.isHidden = true }
        try await eventually("atlas mounts a web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))

        // Reading JS during provisional navigation can target the empty document. Use
        // native state while WebKit cold-starts; keep the bridge assertion separate.
        let clock = ContinuousClock()
        let loadDeadline = clock.now + .seconds(60)
        while web.isLoading || web.url?.isFileURL != true {
            guard clock.now < loadDeadline else {
                return XCTFail("Atlas navigation timed out: page=\(web.url?.lastPathComponent ?? "none"), progress=\(web.estimatedProgress), loading=\(web.isLoading)")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(web.url?.lastPathComponent, "index.html")

        // One WebKit call, in an isolated world, observes the visible DOM. The bundled
        // page must still call /status and render the real native client's reply.
        let observation = """
        const message = document.querySelector('.wa-message');
        if (!message) throw new Error('Atlas did not mount; document=' + document.readyState);
        const visibleText = () => message.isConnected && !message.hidden && message.textContent.trim();
        if (visibleText()) return visibleText();
        return await new Promise((resolve, reject) => {
            const observer = new MutationObserver(() => {
                const text = visibleText();
                if (text) { observer.disconnect(); clearTimeout(timer); resolve(text); }
            });
            const timer = setTimeout(() => {
                observer.disconnect();
                reject(new Error('Atlas mounted but rendered no status; hidden=' + message.hidden));
            }, 30000);
            observer.observe(message, { childList: true, subtree: true, characterData: true, attributes: true });
        });
        """
        var rendered: Result<Any, any Error>?
        web.callAsyncJavaScript(observation, arguments: [:], in: nil, in: .defaultClient) { rendered = $0 }
        let replyDeadline = clock.now + .seconds(45)
        while rendered == nil {
            guard clock.now < replyDeadline else {
                return XCTFail("WebContent did not complete the DOM observation after the local page loaded")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        switch try XCTUnwrap(rendered) {
        case .success(let value):
            let message = try XCTUnwrap(value as? String)
            XCTAssertTrue(message.contains("请先在服务器设置中填写聊天 API Key。"), "Unexpected visible status: \(message)")
        case .failure(let error):
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            XCTFail("Atlas status observation failed: \(detail ?? error.localizedDescription)")
        }
    }
}

@MainActor private final class KeyboardFixtureState: ObservableObject {
    @Published var draft = "草稿"
    let keyboard = ComposerKeyboard()
    var acceptsSend = true
    var sent: [String] = []

    func send() {
        guard acceptsSend, !draft.isEmpty else { return }
        sent.append(draft)
        draft = ""
        keyboard.dismiss()
    }
}

private struct KeyboardFixture: View {
    @ObservedObject var state: KeyboardFixtureState
    var enterSends = true
    var body: some View {
        NativeComposer(text: $state.draft, enterSends: enterSends, insertNewline: 0, keyboard: state.keyboard, onSend: state.send)
    }
}

// An advertised length exercises the preflight limit without allocating a large fixture.
private final class AtlasResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "atlas.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(33 * 1024 * 1024)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
