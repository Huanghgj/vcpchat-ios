import SwiftUI
import UIKit
import WebKit
import XCTest
import SQLite3
@testable import VChatCore
@testable import VChatRendering
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

    private let receiptID = "2026-11-19T22:50:25.956+08:00"
    private func batch(_ body: String, id: String, shell: Bool = true) -> String {
        let source = "<<<[VCP_TOOL_BATCH_START:\(id)]>>>\n" + body + "\n<<<[VCP_TOOL_BATCH_END:\(id)]>>>"
        return shell ? "<<<[ROLE_DIVIDE_USER]>>>\n"+source+"\n<<<[END_ROLE_DIVIDE_USER]>>>" : source
    }

    func testToolBatchHidesOnlyItsTransportAndKeepsSummaryAndImage() async throws {
        let tool = "<<<[TOOL_REQUEST]>>>\ntool_name:「始」NovelAIGen「末」\n<<<[END_TOOL_REQUEST]>>>"
        let summary = "[本轮工具调用摘要:]\nNovelAIGen 调用成功。\n[本轮工具调用摘要结束]"
        let picture = "![生成图](https://fixtures.invalid/generated/portrait.png)"
        let source = tool+"\n"+batch(summary,id:receiptID)+"\n"+picture
        let blocks = try await MessageRenderer().render(source, options:.init(), dark:false)
        XCTAssertEqual(blocks.count,3)
        guard blocks.count==3,
              case .vcp(.tool("NovelAIGen", _, _, true)) = blocks[0],
              case .vcp(.batch(let receipts, true)) = blocks[1], receipts.count == 1,
              case .summary(let lines,true) = receipts[0],
              case .paragraph(let runs) = blocks[2] else { return XCTFail("Expected the tool, one receipt and the assistant's image") }
        XCTAssertEqual(lines,["NovelAIGen 调用成功。"])
        XCTAssertTrue(runs.contains { if case .media(let image)=$0 { return image.caption=="生成图" };return false })
        XCTAssertFalse(SpeechText.plain(source).contains("VCP_TOOL_BATCH"))
    }

    func testBatchCloseMatchesIDAndToolPayloadStaysInert() {
        let foreign = "<<<[VCP_TOOL_BATCH_END:wrong]>>>"
        let literal = "<script>sample()</script>\n<<<[TOOL_REQUEST]>>>"
        let result = "[[VCP调用结果信息汇总:\n工具名称: Example\n执行状态: 成功\n返回内容: ok\nVCP调用结果结束]]"
        let full = batch(literal+"\n"+foreign+"\n"+result,id:receiptID,shell:false)+"\n正文"
        let items=VCPMarkup.parse(full)
        guard items.count==2,case .batch(let parts,true)=items[0],case .text(let after)=items[1] else { return XCTFail("Boundary mismatch") }
        XCTAssertEqual(after.trimmingCharacters(in:.whitespacesAndNewlines),"正文")
        XCTAssertTrue(parts.contains { if case .note(let note)=$0 { return note.contains(literal) && note.contains(foreign) };return false })
        XCTAssertTrue(parts.contains { if case .result(let r,true)=$0 { return r.tool=="Example" && r.content=="ok" };return false })
        let partial = "<<<[ROLE_DIVIDE_USER]>>>\n<<<[VCP_TOOL_BATCH_START:\(receiptID)]>>>\n等待\n<<<[VCP_TOOL_BATCH_EN"
        XCTAssertEqual(VCPMarkup.parse(partial,streaming:true),[.batch([.note("等待")],false)])
        XCTAssertEqual(VCPMarkup.parse(batch("",id:receiptID)),[])
        let other = "<<<[ROLE_DIVIDE_USER]>>>你好<<<[END_ROLE_DIVIDE_USER]>>>"
        XCTAssertEqual(VCPMarkup.parse(other),[.divider("user",false),.text("你好"),.divider("user",true)])
    }

    func testDocumentedBatchInMarkdownIsLiteral() async throws {
        let sample=batch("演示",id:receiptID,shell:false)
        let fence=String(repeating:"`",count:3)
        let source=fence+"text\n"+sample+"\n"+fence+"\n\n"+batch("真的回执",id:receiptID,shell:false)
        let blocks=try await MessageRenderer().render(source, options:.init(), dark:false)
        guard blocks.count==2,case .code(_,let code,_)=blocks[0],
              case .vcp(.batch(let parts,true))=blocks[1],parts == [.note("真的回执")] else { return XCTFail("Expected a code example and a separate receipt") }
        XCTAssertTrue(code.contains(sample))
        let inline = "`example <<<[VCP_TOOL_BATCH_START:sample]>>> text`"
        XCTAssertEqual(VCPMarkup.parse(inline),[.text(inline)])
    }

    // The list supplies a finite width; its one-line label environment must not
    // leak into message prose. Compare identical folded headers/images, so the
    // measured difference can only come from the visible, wrapped body text.
    @MainActor func testLongMixedParagraphWrapsBetweenReasoningAndSticker() async throws {
        let file = "GEM_PHOTO_" + String(repeating: "1A2965D5", count: 14) + "_FINAL.PNG"
        let chinese = String(repeating: "这段回复应该在手机气泡内一直换行直到", count: 5) + "最后一字。"
        let captions = ["短句", chinese, file]
        let tag = #"<img width="36" alt="合成表情" src="data:image/png;base64,\#(pixelPNG(.green).base64EncodedString())">"#
        let renderer = MessageRenderer()
        for caption in captions {
            let blocks = try await renderer.render(caption + " " + tag, options: .init(), dark: false)
            let shown = blocks.flatMap { block -> [InlineRun] in
                if case .paragraph(let runs) = block { return runs }
                return []
            }
            let visibleText = shown.compactMap { run -> String? in
                if case .text(let value) = run { return String(value.characters) }; return nil
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(visibleText, caption, "Parser lost or shortened text before the sticker")
            XCTAssertEqual(shown.filter { if case .media = $0 { return true }; return false }.count, 1)
        }

        let probe = MixedHeightProbe()
        let window = try host(ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(captions.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        DisclosureGroup("思考过程", isExpanded: .constant(false)) { Text("折叠的推理") }
                        RichMessageBody(captions[index] + " " + tag, expandsToFill: true)
                    }
                    .font(.system(size: 17))
                    .lineLimit(1)
                    .environment(\.scenePhase, .active)
                    .environment(\.messageTextSelectionEnabled, false)
                    .frame(width: 214, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        probe.heights[index] = h
                    }
                }
            }
        })
        defer { window.isHidden = true }
        try await eventually("Chinese and uninterrupted filename both grow by several visible lines above the 36pt sticker") {
            guard let short = probe.heights[0], short > 55,
                  let paragraph = probe.heights[1], let filename = probe.heights[2] else { return false }
            return paragraph > short + 50 && filename > short + 35
        }
    }

    @MainActor func testAttachmentFilenameUsesMoreThanOneLineInHistory() {
        let name = "GEM_PHOTO_" + String(repeating: "9B641CD8", count: 14) + "_END.GIF"
        func height(_ name: String) -> CGFloat {
            let item = ChatAttachment(name: name, mime: "image/gif", kind: "image")
            let view = AttachmentStrip(attachments: [item]).frame(width: 218)
            return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 218, height: 700)).height
        }
        let short = height("short.gif"), long = height(name)
        XCTAssertGreaterThan(short, 10)
        XCTAssertGreaterThan(long, short + 25, "A sent attachment's full filename must wrap within the bubble")
    }

    func testDisplayRulesRenderOrdinaryPairedHTMLBesideTextAndAnImage() async throws {
        var card = RegexRule()
        card.findPattern = #"/\[卡:([^\]]+)\]/g"#
        card.replaceWith = #"<details data-note="a > b"><summary>角色</summary><strong>$1</strong></details>"#
        let image = "![合成表情](https://fixtures.invalid/img/sample.png)"
        let original = "前文[卡:星河]后文 " + image
        let renderer = MessageRenderer()
        for live in [true, false] {
            let blocks = try await renderer.render(original, options: .init(), dark: false, streaming: live, rules: [card])
            let cards = blocks.compactMap { block -> String? in if case .html(let body) = block { return body }; return nil }
            XCTAssertEqual(cards, [card.replaceWith.replacingOccurrences(of: "$1", with: "星河")])
            guard let i = blocks.firstIndex(where: { if case .html = $0 { return true }; return false }) else { return }
            func inline(_ range: ArraySlice<RenderBlock>) -> [InlineRun] {
                range.flatMap { if case .paragraph(let runs) = $0 { return runs }; return [] }
            }
            let before = inline(blocks[..<i]), after = inline(blocks[(i + 1)...])
            XCTAssertTrue(before.contains { if case .text(let t) = $0 { return String(t.characters).contains("前文") }; return false })
            XCTAssertTrue(after.contains { if case .text(let t) = $0 { return String(t.characters).contains("后文") }; return false })
            XCTAssertEqual(after.compactMap { if case .media(let m) = $0 { return m.source }; return nil }, ["https://fixtures.invalid/img/sample.png"])
        }
        var disabled = RenderOptions(); disabled.html = false
        let disabledBlocks = try await renderer.render(original, options: disabled, dark: false, rules: [card])
        XCTAssertFalse(disabledBlocks.contains { if case .html = $0 { return true }; return false })
        let changed = try await RegexEngine().apply(original, rules: [card], scope: "context", role: "assistant")
        XCTAssertEqual(changed, original, "A display card must not turn into prompt HTML")
    }

    @MainActor func testRegexDetailsOutputCanActuallyOpenInItsWebView() async throws {
        var rule = RegexRule(); rule.findPattern = #"/\[状态:(.*?)\]/g"#
        rule.replaceWith = #"<details id="fixture-regex-details" title="a > b"><summary>状态</summary><p>$1</p></details>"#
        let window = try host(RichMessageBody("前文[状态:星河]后文", rules: [rule]).environment(\.scenePhase, .active))
        defer { window.isHidden = true }
        try await eventually("regex-produced card mounted its own WKWebView") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Regex card page did not finish loading") }
            try await Task.sleep(for: .milliseconds(200))
        }
        _ = try await observeIsland(web, "regex capture rendered in a working HTML disclosure", condition: """
        const card = document.getElementById('fixture-regex-details');
        if (!card || card.querySelector('p')?.textContent !== '星河') return false;
        if (card.title !== 'a > b' || card.querySelector('summary')?.textContent !== '状态')
            throw new Error('HTML attributes or summary changed');
        if (!card.open) card.querySelector('summary').click();
        return card.open && card.querySelector('p').getBoundingClientRect().height > 0;
        """)
    }

    func testDisplayRegexLeavesReceiptsIntactAndContinuesAfterInvalidRule() async throws {
        var broken = RegexRule(); broken.findPattern = "/(/g"; broken.title = "损坏的规则"
        var a = RegexRule(); a.findPattern = "READY"; a.replaceWith = "stage1"
        var b = RegexRule(); b.findPattern = "stage1"; b.replaceWith = "完成"
        var context = RegexRule(); context.findPattern = "READY"; context.replaceWith = "提示词"; context.applyToFrontend = false; context.applyToContext = true
        a.minDepth = 1; a.maxDepth = 2; b.minDepth = 1; b.maxDepth = 2
        let raw = "READY\n" + batch("READY", id: receiptID) + "\nREADY"
        let renderer = MessageRenderer(), rules = [broken, a, b, context]
        let displayed = try await renderer.render(raw, options: .init(), dark: false, rules: rules, role: "assistant", depth: 1)
        let text = displayed.flatMap { block -> [String] in
            guard case .paragraph(let runs) = block else { return [] }
            return runs.compactMap { if case .text(let t) = $0 { return String(t.characters) }; return nil }
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        XCTAssertEqual(text, "完成完成")
        XCTAssertTrue(displayed.contains(.vcp(.batch([.note("READY")], true))), "Display replacements must not rewrite the authenticated receipt boundary or payload")
        for (role, depth) in [("user", 1), ("assistant", 3)] {
            let blocks = try await renderer.render("READY", options: .init(), dark: false, rules: rules, role: role, depth: depth)
            guard case .paragraph(let runs) = blocks.first, case .text(let t) = runs.first else { return XCTFail("Expected original prose") }
            XCTAssertEqual(String(t.characters), "READY")
        }
        let prompt = try await RegexEngine().apply("READY", rules: [a, b, context], scope: "context", role: "assistant", depth: 1)
        XCTAssertEqual(prompt, "提示词")
    }

    func testHTMLRuleInsideCodeRemainsALiteralExample() async throws {
        var rule = RegexRule(); rule.findPattern = "TOKEN"; rule.replaceWith = "<section><b>示例</b></section>"
        let fenced = String(repeating: "`", count: 3)
        let source = fenced + "html\nTOKEN\n" + fenced + "\n\n\u{60}TOKEN\u{60}\n\nTOKEN"
        let blocks = try await MessageRenderer().render(source, options: .init(), dark: false, rules: [rule])
        let html = blocks.filter { if case .html = $0 { return true }; return false }
        XCTAssertEqual(html.count, 1, "Only the unfenced occurrence becomes a card")
        XCTAssertTrue(blocks.contains { if case .code("html", let literal, _) = $0 { return !literal.isEmpty }; return false })
        let hasInlineExample = blocks.contains { block in
            guard case .paragraph(let runs) = block else { return false }
            return runs.contains { run in
                guard case .text(let text) = run else { return false }
                return text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }
            }
        }
        XCTAssertTrue(hasInlineExample, "The inline code sample must remain a code span")
    }

    @MainActor func testStandaloneRoleMarkerCannotGrowIntoAnEmptyPanel() {
        let content=VCPCardView(segment:.divider("user",false),options:.init())
        let controller=UIHostingController(rootView:content)
        let size=controller.sizeThatFits(in:CGSize(width:340,height:600))
        XCTAssertGreaterThan(size.height,5)
        XCTAssertLessThan(size.height,45)
    }

    @MainActor func testRemotePhotoFitsBubbleButStickerKeepsAuthoredWidth() throws {
        let picture=try XCTUnwrap(MessageMedia.html(#"<img src="https://fixtures.invalid/pw=fixture/images/generated/portrait.png" width="110">"#))
        let sticker=try XCTUnwrap(MessageMedia.html(#"<img src="https://fixtures.invalid/pw=fixture/images/测试表情包/笑.png" width="110">"#))
        func measure(_ media: MessageMedia,_ pixels:CGSize,_ width:CGFloat) -> CGSize {
            let layout=MessageImageLayout(pixels:pixels,widthLimit:media.inlineWidthLimit) { Color.red }
            return UIHostingController(rootView:layout).sizeThatFits(in:CGSize(width:width,height:2000))
        }
        for width in [CGFloat(248),338] {
            let size=measure(picture,CGSize(width:512,height:768),width)
            XCTAssertEqual(size.width,width,accuracy:1)
            XCTAssertEqual(size.height,width*1.5,accuracy:1)
        }
        let landscape=measure(picture,CGSize(width:1000,height:500),320)
        XCTAssertEqual(landscape.height,160,accuracy:1)
        XCTAssertEqual(measure(sticker,CGSize(width:512,height:512),320).width,110,accuracy:1)
        let tall=measure(picture,CGSize(width:500,height:5000),338)
        XCTAssertLessThanOrEqual(tall.height,721)
        XCTAssertEqual(tall.width/tall.height,0.1,accuracy:0.002)
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
                keyboard.didClearDraft()
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
        XCTAssertEqual(editor.text, "")
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

    @MainActor func testRemoteImageSurvivesReopenAndCoalescesRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(URL(string: "https://fixtures.invalid/pw=fixture-a/images/test/card.png?revision=1"))
        let origin = ImageOriginFixture(), payload = pixelPNG(.purple)
        await origin.set(source, payload)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        async let first = online.resource(source)
        async let second = online.resource(source)
        let pair = try await (first, second)
        XCTAssertEqual(pair.0.data, payload)
        XCTAssertEqual(pair.1.data, payload)
        let count = await origin.count(source)
        XCTAssertEqual(count, 1, "two views for one URL must share the download")

        let offline = ImageOriginFixture()
        let reopened = RemoteImageStore(directory: directory) { try await offline.get($0) }
        let restored = try await reopened.resource(source)
        XCTAssertEqual(restored.data, payload)
        let attempts = await offline.count(source)
        XCTAssertEqual(attempts, 0, "the second store has no memory cache and no available network")

        for changed in [
            "https://fixtures.invalid/pw=fixture-b/images/test/card.png?revision=1",
            "https://fixtures.invalid/pw=fixture-a/images/test/card.png?revision=2"
        ] {
            let url = try XCTUnwrap(URL(string: changed))
            do { _ = try await reopened.resource(url); XCTFail("a different resource must not get the first image") }
            catch { /* the fixture is offline */ }
            let requests = await offline.count(url)
            XCTAssertEqual(requests, 1)
        }
    }

    @MainActor func testInvalidResponsesAreRetriedAndNoStoreIsNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/demo/card.png"))
        let bytes = pixelPNG(.orange), origin = ImageOriginFixture()
        let store = RemoteImageStore(directory: directory) { try await origin.get($0) }
        await origin.set(url, bytes, status: 403)
        do { _ = try await store.resource(url); XCTFail("denied content must not be cached as an image") }
        catch { }
        await origin.set(url, Data("<html>sign in</html>".utf8))
        do { _ = try await store.resource(url); XCTFail("HTTP 200 from a login page is not an image") }
        catch { }
        await origin.set(url, bytes, control: "private, no-store")
        let privateImage = try await store.resource(url)
        XCTAssertEqual(privateImage.data, bytes)
        let newProcess = RemoteImageStore(directory: directory) { try await origin.get($0) }
        _ = try await newProcess.resource(url)
        let count = await origin.count(url)
        XCTAssertEqual(count, 4, "no-store content needs the network after reopening")
    }

    @MainActor func testZeroMaxAgeOnlyPersistsVCPStickersWithoutRevalidationRestrictions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = ImageOriginFixture(), offline = ImageOriginFixture(), bytes = pixelPNG(.blue)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        // All cases use valid identical images. Only URL shape and HTTP cache policy differ.
        for (path, control, shouldPersist) in [
            ("pw=fixture/images/测试表情包/固定.png", "public, max-age=0", true),
            ("pw=fixture/images/photos/plain.png", "public, max-age=0", false),
            ("images/测试表情包/无前缀.png", "public, max-age=0", false),
            ("pw=fixture/images/测试表情包/禁止保存.png", "public, max-age=0, NO-STORE", false),
            ("pw=fixture/images/测试表情包/必须验证.png", "public, No-Cache, max-age=0", false),
            ("pw=fixture/images/测试表情包/必须重验.png", "public, max-age=0, must-revalidate", false)
        ] {
            let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/" + path))
            await origin.set(url, bytes, control: control)
            let live = try await online.resource(url)
            XCTAssertEqual(live.data, bytes)
            let cold = RemoteImageStore(directory: directory) { try await offline.get($0) }
            do {
                let fromDisk = try await cold.resource(url)
                XCTAssertTrue(shouldPersist, "unexpected persisted response for \(path), \(control)")
                XCTAssertEqual(fromDisk.data, bytes)
            } catch {
                XCTAssertFalse(shouldPersist, "valid VCP sticker was unavailable offline: \(error.localizedDescription)")
            }
            let networkAttempts = await offline.count(url)
            XCTAssertEqual(networkAttempts, shouldPersist ? 0 : 1, "wrong cold-load policy: \(path), \(control)")
        }
    }

    @MainActor func testStickerCatalogRepairsOnlyStickerNamesAndPackages() throws {
        let library = EmoticonCatalog(entries: ["猫表情包": ["开心.webp", "吃鱼.png"], "兔表情包": ["开心.gif"]])
        func source(_ package: String, _ filename: String) throws -> URL {
            let base = try XCTUnwrap(URL(string: "https://fixtures.invalid:8443/pw=fixture/images/"))
            return base.appendingPathComponent(package)
                .appendingPathComponent(filename)
                .appending(queryItems: [URLQueryItem(name: "revision", value: "abc")])
        }
        let missingExtension = try source("猫表情包", "开心.jpg")
        let expected = try source("猫表情包", "开心.webp")
        XCTAssertEqual(library.repair(missingExtension), expected, "same stem: choose the existing item in the named package")
        let inventedPackage = try source("虚构表情包", "吃鱼.gif")
        XCTAssertEqual(library.repair(inventedPackage), try source("猫表情包", "吃鱼.png"), "a unique stem can recover another package")
        let typo = try source("猫表情包", "吃小鱼.gif")
        XCTAssertEqual(library.repair(typo), try source("猫表情包", "吃鱼.png"), "unknown stem first searches the same package")
        let ordinary = try source("photos", "开心.jpg")
        XCTAssertEqual(library.repair(ordinary), ordinary)
        XCTAssertEqual(EmoticonCatalog(entries: [:]).repair(missingExtension), missingExtension)
    }

    @MainActor func testStickerResolutionStaysOnTheConfiguredOrigin() throws {
        let server = try XCTUnwrap(URL(string: "https://fixtures.invalid/v1/chat/completions"))
        let catalog = EmoticonCatalog(entries: ["猫表情包": ["笑.png"]])
        let context = StickerContext(server: server, fileKey: "fixture-ticket", catalog: catalog)
        let resolved = try XCTUnwrap(context.resolve("images/猫表情包/笑.gif"))
        XCTAssertEqual(resolved.host, server.host)
        XCTAssertEqual(resolved.path, "/pw=fixture-ticket/images/猫表情包/笑.png")

        let old = "https://fixtures.invalid:6005/pw=older/images/猫表情包/笑.gif?revision=5"
        let fixed = try XCTUnwrap(context.resolve(old))
        XCTAssertEqual(fixed.scheme, "https")
        XCTAssertNil(fixed.port)
        XCTAssertEqual(fixed.path, "/pw=older/images/猫表情包/笑.png")
        XCTAssertEqual(fixed.query, "revision=5")

        let foreign = try XCTUnwrap(URL(string: "https://elsewhere.invalid:6005/pw=other/images/猫表情包/笑.gif"))
        XCTAssertEqual(context.resolve(foreign.absoluteString), foreign)
        XCTAssertNil(context.resolve("//elsewhere.invalid/images/猫表情包/笑.png"))
    }

    @MainActor func testStableCodePrefixAppendsThenYieldsToTheCanonicalParser() throws {
        let prefix = "正文\n\n", opener = "~~~swift\n"
        let first = try XCTUnwrap(StreamFenceTail.split(prefix + opener + "let x"))
        let next = try XCTUnwrap(StreamFenceTail.split(prefix + opener + "let x = 1\nlet y"))
        XCTAssertEqual(first.prefix, prefix)
        XCTAssertEqual(next.prefix, first.prefix)
        XCTAssertEqual(next.language, "swift")
        XCTAssertEqual(next.body, "let x = 1\nlet y")
        XCTAssertNil(StreamFenceTail.split(prefix + opener + next.body + "\n~~~"))
        XCTAssertNil(StreamFenceTail.split(prefix + "    ~~~swift\nexample"), "indented code is not a top-level streaming fence")
    }

    @MainActor func testLooseStickerTagRendersButCodeExamplesStayLiteral() async throws {
        let source = "https://fixtures.invalid/images/sample/card.png"
        let tag = "< img src=\"\(source)\" width=\"110\" style=\"border-radius:10px;display:block;flex-shrink:0;\" alt=\"笑\">"
        let renderer = MessageRenderer(), options = RenderOptions()
        let blocks = try await renderer.render(tag, options: options, dark: false)
        let images: [MessageMedia] = blocks.flatMap { block -> [MessageMedia] in
            guard case .paragraph(let runs) = block else { return [] }
            return runs.compactMap { run in if case .media(let media) = run { return media }; return nil }
        }
        XCTAssertEqual(images.map(\.source), [source])
        XCTAssertEqual(images.first?.caption, "笑")
        XCTAssertEqual(images.first?.preferredWidth, 110)
        XCTAssertEqual(images.first?.cornerRadius, 10)

        let fence = String(repeating: "`", count: 3)
        let open = fence + "html\n" + tag
        for (frame, expected, live) in [
            (open, tag, true),
            (open + "\n第二行", tag + "\n第二行", true),
            (open + "\n第二行\n" + fence, tag + "\n第二行", false)
        ] {
            let blocks = try await renderer.render(frame, options: options, dark: false, streaming: live)
            guard case .code(let language, let literal, _) = blocks.first else { return XCTFail("expected a literal code block") }
            XCTAssertEqual(language, "html")
            XCTAssertEqual(literal.trimmingCharacters(in: .newlines), expected)
        }
        let inline = try await renderer.render("示例：`" + tag + "`", options: options, dark: false)
        guard case .paragraph(let runs) = inline.first else { return XCTFail("expected inline code") }
        let text = runs.compactMap { run -> String? in if case .text(let t) = run { return String(t.characters) }; return nil }.joined()
        XCTAssertTrue(text.contains(tag))
        XCTAssertFalse(runs.contains { if case .media = $0 { true } else { false } })
    }

    // Keep native waiting bounded even if the simulator's WebContent process stops.
    // Once the native page starts loading, one isolated-world observer per phase
    // checks actual DOM changes without repeatedly bridging arbitrary script.
    @MainActor private func observeIsland(_ web: WKWebView, _ phase: String, condition: String,
                                          file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
        let script = """
        return await new Promise((resolve, reject) => {
            const matches = () => { \(condition) };
            const observer = new MutationObserver(check);
            const timer = setTimeout(() => { observer.disconnect(); reject(new Error('island condition not reached')); }, 30000);
            function check() {
                try {
                    if (!matches()) return;
                    observer.disconnect(); clearTimeout(timer); resolve(true);
                } catch (error) { observer.disconnect(); clearTimeout(timer); reject(error); }
            }
            observer.observe(document, { attributes: true, childList: true, subtree: true, characterData: true });
            check();
        });
        """
        var rendered: Result<Any, any Error>?
        web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { rendered = $0 }
        let clock = ContinuousClock(), deadline = clock.now + .seconds(45)
        while rendered == nil && clock.now < deadline { try await Task.sleep(for: .milliseconds(200)) }
        guard let rendered else { XCTFail("WebContent did not finish: " + phase, file: file, line: line); return false }
        switch rendered {
        case .success(let value):
            guard value as? Bool == true else { XCTFail("Unexpected WebKit response: " + phase, file: file, line: line); return false }
            return true
        case .failure(let error):
            XCTFail(phase + ": " + error.localizedDescription, file: file, line: line)
            return false
        }
    }

    @MainActor func testStreamedIslandKeepsItsImageAndInitializesOnceThroughFinal() async throws {
        let state = IslandFixtureState(image: pixelPNG(.green))
        let window = try host(IslandFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("island mounts its web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Island document did not finish navigation") }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard try await observeIsland(web, "closed streaming island has started", condition: """
        const photo = document.getElementById('fixture-photo');
        if (!photo || document.documentElement.dataset.fixtureStarts !== '1') return false;
        window.__fixturePhoto = photo;
        return true;
        """) else { return }

        state.source += "\n<script>document.documentElement.dataset.fixtureNext = 'yes';</script>"
        guard try await observeIsland(web, "later frame retains the original image", condition: """
        if (document.documentElement.dataset.fixtureNext !== 'yes') return false;
        if (document.getElementById('fixture-photo') !== window.__fixturePhoto) throw new Error('image replaced during append');
        if (document.documentElement.dataset.fixtureStarts !== '1') throw new Error('script ran twice during append');
        return true;
        """) else { return }

        state.streaming = false
        _ = try await observeIsland(web, "canonical terminal retains the same image and script", condition: """
        if (document.documentElement.dataset.fixtureTerminal !== 'yes') return false;
        if (document.getElementById('fixture-photo') !== window.__fixturePhoto) throw new Error('image replaced at terminal');
        if (document.documentElement.dataset.fixtureStarts !== '1') throw new Error('script reran at terminal');
        return true;
        """)
    }

    @MainActor func testDesktopCanvasWaitsForOuterSealAndSurvivesTerminal() async throws {
        let open = """
        ### 阶段一

        <div class="desktop-stage"><style>.indicator { color: teal }</style>
        <div><canvas width="8" height="8"></canvas><span class="indicator">waiting</span></div>
        <script>
        const card = container.querySelector('.desktop-stage');
        if (!card) return;
        const canvas = card.querySelector('canvas');
        document.documentElement.dataset.starts = String(Number(document.documentElement.dataset.starts || 0) + 1);
        document.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.terminal = 'yes'; }, {once:true});
        requestAnimationFrame(() => {
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = '#00ff00'; ctx.fillRect(0, 0, 8, 8);
            card.querySelector('.indicator').textContent = 'drawn';
        });
        </script>
        """
        let state = IslandFixtureState(source: open)
        let window = try host(IslandFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("desktop canvas island mounts a web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Desktop island navigation never finished") }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard try await observeIsland(web, "open outer DIV does not activate a closed inline script", condition: """
        const card = document.querySelector('.desktop-stage');
        if (!card?.querySelector('script') || !card.querySelector('canvas')) return false;
        if (document.documentElement.dataset.starts) throw new Error('script started before closing outer DIV');
        return card.querySelector('.indicator').textContent === 'waiting';
        """) else { return }

        state.source += "</div>"
        guard try await observeIsland(web, "complete idle island can find its own outer container and paint", condition: """
        const card = document.querySelector('.desktop-stage'), canvas = card?.querySelector('canvas');
        if (!canvas || card.querySelector('.indicator').textContent !== 'drawn') return false;
        if (document.documentElement.dataset.starts !== '1') throw new Error('early script should run once');
        if (canvas.getContext('2d').getImageData(0, 0, 1, 1).data[1] !== 255) throw new Error('canvas never painted');
        window.__fixtureCard = card; window.__fixtureCanvas = canvas;
        return true;
        """) else { return }
        state.source += "\n\n~~~swift\nlet x = 1\n~~~"
        state.streaming = false
        _ = try await observeIsland(web, "canonical final still owns the original painted canvas", condition: """
        if (document.documentElement.dataset.terminal !== 'yes') return false;
        const card = document.querySelector('.desktop-stage'), canvas = card?.querySelector('canvas');
        if (card !== window.__fixtureCard || canvas !== window.__fixtureCanvas || document.documentElement.dataset.starts !== '1')
            throw new Error('canonical pass replaced or reinitialised the mounted island');
        return canvas.getContext('2d').getImageData(0, 0, 1, 1).data[1] === 255;
        """)
    }

    @MainActor private func renderFixtureImage(_ url: URL, using store: RemoteImageStore) async throws {
        let handler = IslandImageScheme(store: store)
        handler.mediaEnabled = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.removeAllUserScripts()
        configuration.setURLSchemeHandler(handler, forURLScheme: IslandImageScheme.name)
        let web = WKWebView(frame: .zero, configuration: configuration)
        let window = try host(SchemeImageFixture(view: web))
        defer { web.stopLoading(); handler.invalidate(); window.isHidden = true }

        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = try XCTUnwrap(url.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved))
        let image = "<img id=\"fixture\" src=\"\(IslandImageScheme.name)://asset?\(encoded)\" onload=\"this.dataset.loaded='yes'\" onerror=\"this.dataset.failed='yes'\">"
        let html = HTMLIslandPolicy.document(image, motion: false, media: true, dark: false)
        web.loadHTMLString(html, baseURL: nil)
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Image scheme fixture navigation never finished") }
            try await Task.sleep(for: .milliseconds(200))
        }
        _ = try await observeIsland(web, "WKWebView decodes the image supplied by the persistent store", condition: """
        const img = document.getElementById('fixture');
        if (img?.dataset.failed === 'yes') throw new Error('WebKit image load failed');
        return img?.dataset.loaded === 'yes' && img.complete && img.naturalWidth > 0;
        """)
    }

    @MainActor func testHTMLImagesUseTheSamePersistentStoreAsNativeRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/img/card.png?size=2"))
        let origin = ImageOriginFixture(), payload = pixelPNG(.green)
        await origin.set(url, payload)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        try await renderFixtureImage(url, using: online)
        let initialDownloads = await origin.count(url)
        XCTAssertEqual(initialDownloads, 1)

        let offline = ImageOriginFixture()
        let coldStore = RemoteImageStore(directory: directory) { try await offline.get($0) }
        try await renderFixtureImage(url, using: coldStore)
        let nativeBytes = try await coldStore.resource(url)
        XCTAssertEqual(nativeBytes.data, payload)
        let extraDownloads = await offline.count(url)
        XCTAssertEqual(extraDownloads, 0, "new ephemeral WebKit and native store must reload from disk while offline")
    }
}

@MainActor private final class MixedHeightProbe { var heights: [Int: CGFloat] = [:] }

@MainActor private final class KeyboardFixtureState: ObservableObject {
    @Published var draft = "草稿"
    let keyboard = ComposerKeyboard()
    var acceptsSend = true
    var sent: [String] = []

    func send() {
        guard acceptsSend, !draft.isEmpty else { return }
        sent.append(draft)
        draft = ""
        keyboard.didClearDraft()
    }
}

private struct KeyboardFixture: View {
    @ObservedObject var state: KeyboardFixtureState
    var enterSends = true
    var body: some View {
        NativeComposer(text: $state.draft, enterSends: enterSends, insertNewline: 0, keyboard: state.keyboard, onSend: state.send)
    }
}

// Use only synthetic image bytes and URLs. No server or Keychain configuration is needed.
@MainActor private func pixelPNG(_ color: UIColor) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
}

private actor ImageOriginFixture {
    private var requests: [URL:Int] = [:]
    private var replies: [URL:RemoteImageReply] = [:]
    func set(_ url: URL, _ data: Data, status: Int = 200, control: String = "") {
        replies[url] = RemoteImageReply(data: data, status: status, cacheControl: control)
    }
    func count(_ url: URL) -> Int { requests[url, default: 0] }
    func get(_ url: URL) async throws -> RemoteImageReply {
        requests[url, default: 0] += 1
        guard let reply = replies[url] else { throw URLError(.notConnectedToInternet) }
        // Ensure two simultaneous views can overlap before their first response arrives.
        try await Task.sleep(for: .milliseconds(100))
        return reply
    }
}


@MainActor private final class IslandFixtureState: ObservableObject {
    @Published var source: String
    @Published var streaming = true
    init(source: String) { self.source = source }
    init(image: Data) {
        source = """
        <div id="vcp-root"><img id="fixture-photo" alt="sticker" src="data:image/png;base64,\(image.base64EncodedString())"></div>
        <script>
        document.documentElement.dataset.fixtureStarts = String(1 + Number(document.documentElement.dataset.fixtureStarts || 0));
        document.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.fixtureTerminal = 'yes'; }, { once: true });
        </script>
        """
    }
}

private struct IslandFixture: View {
    @ObservedObject var state: IslandFixtureState
    var body: some View {
        RichMessageBody(state.source, streaming: state.streaming)
            .environment(\.scenePhase, .active)
    }
}


private struct SchemeImageFixture: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
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
