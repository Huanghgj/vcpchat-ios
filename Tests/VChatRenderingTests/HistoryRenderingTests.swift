import Foundation
import Testing
@testable import VChatRendering

struct HistoryRenderingTests {
    private let first = #"<style>p{color:red}</style><div id="vcp-root">你好</div>"#
    private let second = #"<style>p{color:blue}</style><div id="vcp-root">☕</div>"#

    @Test(arguments: [
        ("中文**“加粗”**继续", "中文“加粗”继续", "“加粗”"),
        ("😀**加粗**", "😀加粗", "加粗"),
        ("**加粗**👨‍👩‍👧‍👦", "加粗👨‍👩‍👧‍👦", "加粗")
    ])
    func historicalBold(_ example: (input: String, text: String, bold: String)) async throws {
        let blocks = try await MessageRenderer().render(example.input, options: .init(), dark: false)
        let inline = try #require(blocks.first)
        guard case .paragraph(let runs) = inline else { Issue.record("Expected a paragraph"); return }
        let attributed = runs.compactMap { run in
            if case .text(let text) = run { return text }
            return nil
        }
        #expect(attributed.map { String($0.characters) }.joined() == example.text)
        let bold = attributed.flatMap { text in
            text.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
                .map { String(text[$0.range].characters) }
        }
        #expect(bold.joined() == example.bold)
    }

    @Test func severalStyledCardsDoNotShareOffsetsOrConsumeProse() async throws {
        let source = first + "\n\n" + second
        let renderer = MessageRenderer()
        let options = RenderOptions()
        let blocks = try await renderer.render(source, options: options, dark: false)
        #expect(blocks == [.html(first), .html(second)])
        let isolated = "<style>p{color:green}</style>"
        #expect(HTMLIslandPolicy.extractSections(from: first + "\n\n正文\n\n" + isolated + "\n\n后文\n\n" + second) == [
            .island(first), .markdown("\n\n正文\n\n" + isolated + "\n\n后文\n\n"), .island(second)
        ])
    }

    @Test func fencedExamplesAndExistingScriptsKeepTheirMeaning() async throws {
        let script = "<script>window.counter = 1;</script>"
        let bare = #"<div id="vcp-root">你好</div>"#
        let renderer = MessageRenderer()
        let single = try await renderer.render(bare + script, options: .init(), dark: false)
        #expect(single == [.html(bare + script)])
        let multiple = try await renderer.render(first + script + "\n\n" + second, options: .init(), dark: false)
        #expect(multiple == [.html(first + script), .html(second)])
        let code = "```html\n" + first + "\n```"
        #expect(HTMLIslandPolicy.extractSections(from: code) == [.markdown(code)])
        let fakeID = #"<div title='id="vcp-root"'>伪造根节点</div>"#
        #expect(HTMLIslandPolicy.extractSections(from: fakeID) == [.markdown(fakeID)])
    }
}
