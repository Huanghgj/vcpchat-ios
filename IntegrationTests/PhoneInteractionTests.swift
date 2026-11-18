import SwiftUI
import UIKit
import WebKit
import XCTest
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

    @MainActor private func eventually(_ check: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        while clock.now < deadline {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTFail("Timed out waiting for the phone UI")
    }

    @MainActor func testComposerManualDismissalAndSendDismissal() async throws {
        let window = try host(KeyboardFixture())
        defer { window.isHidden = true }
        try await eventually { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("草稿")
        let bar = try XCTUnwrap(editor.inputAccessoryView as? UIToolbar)
        let hide = try XCTUnwrap(bar.items?.first { $0.title == "收起键盘" })
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(hide.action), to: hide.target, from: hide, for: nil))
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertEqual(editor.text, "草稿")
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("\n")
        try await eventually { !editor.isFirstResponder && editor.text.isEmpty }
    }

    @MainActor func testBundledAtlasCanCallNativeBridge() async throws {
        let window = try host(FieldAtlasView(configuration: .init(server: "https://example.invalid"), key: ""))
        defer { window.isHidden = true }
        try await eventually {
            guard let web = self.find(WKWebView.self, in: window),
                  let message = try? await web.evaluateJavaScript("document.querySelector('.wa-message')?.textContent") as? String else { return false }
            // This exact response comes from the native /status request, before any network I/O.
            return message.contains("聊天 API Key")
        }
    }
}

private struct KeyboardFixture: View {
    @State private var draft = ""
    @State private var dismissal = 0
    var body: some View {
        NativeComposer(text: $draft, enterSends: true, insertNewline: 0, dismissKeyboard: dismissal) {
            guard !draft.isEmpty else { return }
            draft = ""
            dismissal += 1
        }
    }
}
