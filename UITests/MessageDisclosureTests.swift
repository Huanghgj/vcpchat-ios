import XCTest

final class MessageDisclosureTests: XCTestCase {
    @MainActor func testTappingOneHeaderChangesOnlyThatSection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["VCHAT_TEST_DISCLOSURE_MESSAGE"] = """
        <<<[TOOL_REQUEST]>>>
        tool_name:「始」天气「末」
        command:「始」查询「末」
        <<<[END_TOOL_REQUEST]>>>
        <<<[TOOL_REQUEST]>>>
        tool_name:「始」时钟「末」
        <<<[END_TOOL_REQUEST]>>>
        <<<[VCP_TOOL_BATCH_START:example]>>>
        [[VCP调用结果信息汇总:
        - 工具名称: 天气
        - 执行状态: 成功
        - 返回内容: 小雨
        VCP调用结果结束]]
        [[VCP调用结果信息汇总:
        - 工具名称: 时钟
        - 执行状态: 成功
        - 返回内容: 九点
        VCP调用结果结束]]
        [本轮工具调用摘要:]
        两次调用成功
        [本轮工具调用摘要结束]
        <<<[VCP_TOOL_BATCH_END:example]>>>
        [--- VCP元思考链: "推理片段" ---]
        独立的一段思考
        [--- 元思考链结束 ---]
        """
        app.launch()
        let titles = ["思考过程","天气","时钟","工具结果 · 天气","工具结果 · 时钟","本轮工具调用摘要","推理片段"]
        let buttons = titles.map { app.buttons[$0].firstMatch }
        XCTAssertTrue(buttons[5].waitForExistence(timeout:20))
        func check(_ open: Set<Int>, file: StaticString = #filePath, line: UInt = #line) {
            for (index, button) in buttons.enumerated() {
                XCTAssertEqual(button.value as? String, open.contains(index) ? "已展开" : "已收起", titles[index], file:file,line:line)
            }
        }
        func tap(_ index: Int) {
            let b = buttons[index]
            if !b.isHittable {
                let list = app.collectionViews.firstMatch
                if b.frame.midY < list.frame.midY { list.swipeDown() } else { list.swipeUp() }
            }
            b.tap()
        }
        check([])
        tap(6); check([6]); tap(6); check([])
        tap(1); check([1])
        tap(0); check([0,1])
        tap(1); check([0])
        tap(0); check([])
        tap(3); check([3]); XCTAssertTrue(app.staticTexts["小雨"].exists); XCTAssertFalse(app.staticTexts["九点"].exists)
        tap(4); check([3,4]); XCTAssertTrue(app.staticTexts["九点"].exists)
        tap(3); check([4])
        tap(4); tap(5); check([5]); XCTAssertTrue(app.staticTexts["两次调用成功"].exists)
    }
}
