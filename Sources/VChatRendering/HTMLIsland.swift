import SwiftUI
import WebKit
import VChatCore
import Observation

public enum IslandSection: Sendable, Equatable {
    case markdown(String)
    case island(String)
}
public enum HTMLIslandPolicy {
    public static let root = "<div id=\"vcp-root\">"
    public static func accepts(_ source: String) -> Bool { divAttributes(source)?.root == true }
    private static func divAttributes(_ source: String, tag:String = "div") -> (root: Bool, styled: Bool, selectors:Set<String>)? {
        // Read just the first opening tag. Attribute order and CSS do not change
        // a root's identity; attribute text containing a fake id does not count.
        let prefix = String(source.prefix(8192))
        let scanner = Scanner(string: prefix)
        scanner.charactersToBeSkipped = nil; scanner.caseSensitive = false
        let whitespace = CharacterSet.whitespacesAndNewlines
        _ = scanner.scanCharacters(from: whitespace.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let indentation = prefix[..<scanner.currentIndex].components(separatedBy: .newlines).last ?? ""
        guard !indentation.contains("\t"),indentation.filter({ $0 != "\u{FEFF}" }).count < 4,
              scanner.scanString("<") != nil,scanner.scanString(tag) != nil else { return nil }
        let names = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:-.")
        let unquoted = whitespace.union(CharacterSet(charactersIn: "\"'`=<>")).inverted
        var rootID: String?
        var styled = false, selectors=Set<String>()
        while !scanner.isAtEnd {
            let separator = scanner.scanCharacters(from: whitespace)
            if scanner.scanString(">") != nil { return (tag=="div" && rootID == "vcp-root", styled, selectors) }
            guard separator != nil,let name = scanner.scanCharacters(from: names) else { return nil }
            let afterName = scanner.currentIndex
            _ = scanner.scanCharacters(from: whitespace)
            var value: String?
            if scanner.scanString("=") != nil {
                _ = scanner.scanCharacters(from: whitespace)
                if let quote = scanner.scanString("\"") ?? scanner.scanString("'") {
                    value = scanner.scanUpToString(quote) ?? ""
                    guard scanner.scanString(quote) != nil else { return nil }
                } else {
                    guard let raw = scanner.scanCharacters(from: unquoted) else { return nil }
                    value = raw
                }
            } else { scanner.currentIndex = afterName }
            if ["style","class"].contains(name.lowercased()), let value, !value.isEmpty { styled = true }
            if name.lowercased()=="class", let value { for part in value.split(whereSeparator:{ $0.isWhitespace }) { selectors.insert("."+part) } }
            if name.lowercased() == "id" {
                if let value { selectors.insert("#"+value) }
                guard rootID == nil,let value else { return nil }
                rootID = value
            }
        }
        return nil
    }
    public static func containsIsland(_ source: String) -> Bool {
        extractSections(from:source).contains { if case .island = $0 { return true }; return false }
    }

    // Tokenize complete tags (including unrelated tags) so markup-looking strings
    // inside quoted attributes, comments and raw-text elements cannot open a card.
    private static let tagTokens = try! NSRegularExpression(pattern: #"(?is)<!--.*?(?:-->|$)|<(script|style|pre|code|textarea)\b(?:"[^"]*"|'[^']*'|[^'">])*>.*?(?:</\1\s*>|$)|(`+)(?!`).*?\2(?!`)|<(/?)([a-z][a-z0-9:-]*)(?=[\s/>])(?:"[^"]*"|'[^']*'|[^'">])*>"#)
    private static let possibleRoot = try! NSRegularExpression(pattern: #"(?i)<(?:div|details|section|article|aside|figure|svg|span|p|table|ul|ol|blockquote)(?=[\s>])"#)
    private static let cssIdentifier = try! NSRegularExpression(pattern:#"[.#][\p{L}_-][\p{L}\p{N}_-]*"#)
    private static let blockRoots: Set<String> = ["div","details","section","article","aside","figure","svg"]
    private static let regexRoots: Set<String> = ["div","details","section","article","aside","figure","svg","span","p","table","ul","ol","blockquote"]
    private struct Container { let tag: String; let opening: NSRange; var end: Int? }

    /// Paired fragments become their own WebKit document; neighboring prose and
    /// standalone images still go through the native Markdown/media renderer.
    public static func extractSections(from source: String, regexOutput: Bool = false, streaming: Bool = false, unchangedFragments: Set<String> = []) -> [IslandSection] {
        let s=source as NSString
        guard source.contains("<"), possibleRoot.firstMatch(in:source,range:NSRange(location:0,length:s.length)) != nil else { return [.markdown(source)] }
        let fences=codeFences(source), roots=regexOutput ? regexRoots : blockRoots
        var fence=0, candidates:[Container]=[], stacks:[String:[Int]]=[:]
        var detached:[(range:NSRange, selectors:Set<String>)]=[], openCount=0, cssBytes=0
        var prefixEndingAt:[Int:NSRange]=[:], styleStartingAt:[Int:NSRange]=[:]
        func skipWhitespace(_ index:Int, backwards:Bool) -> Int {
            var p=index
            while backwards ? p>0 : p<s.length {
                let c=s.character(at:backwards ? p-1 : p)
                guard let scalar=UnicodeScalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
                p += backwards ? -1 : 1
            }
            return p
        }
        // Scan gaps independently: triple-backtick code must never absorb HTML after the fence.
        func scan(_ range:NSRange) {
            guard range.length>0 else { return }
            for m in tagTokens.matches(in:source,range:range) {
                if m.range(at:1).location != NSNotFound {
                    if s.substring(with:m.range(at:1)).lowercased()=="style" {
                        let token=s.substring(with:m.range)
                        if token.range(of:#"(?i)</style\s*>\z"#,options:.regularExpression) != nil {
                            prefixEndingAt[NSMaxRange(m.range)]=m.range; styleStartingAt[m.range.location]=m.range
                            if openCount==0, detached.count<32, cssBytes+token.utf8.count <= 128*1024 {
                                let ns=token as NSString
                                let ids=Set(cssIdentifier.matches(in:token,range:NSRange(location:0,length:ns.length)).map { ns.substring(with:$0.range) })
                                if !ids.isEmpty { detached.append((m.range,ids));cssBytes += token.utf8.count }
                            }
                        }
                    }
                    continue
                }
                if s.character(at:m.range.location)==60 && s.substring(with:NSRange(location:m.range.location,length:min(4,m.range.length)))=="<!--" {
                    prefixEndingAt[NSMaxRange(m.range)]=m.range;continue
                }
                guard m.range(at:4).location != NSNotFound else { continue }
                let tag=s.substring(with:m.range(at:4)).lowercased()
                guard roots.contains(tag) else { continue }
                if m.range.location>0 && s.character(at:m.range.location-1)==92 { continue }
                if m.range(at:3).length>0 {
                    guard let index=stacks[tag]?.popLast() else { continue }
                    candidates[index].end=NSMaxRange(m.range);openCount -= 1
                } else {
                    let selfClosingSVG = tag=="svg" && s.character(at:NSMaxRange(m.range)-2)==47
                    if !selfClosingSVG { stacks[tag,default:[]].append(candidates.count);openCount += 1 }
                    candidates.append(Container(tag:tag,opening:m.range,end:selfClosingSVG ? NSMaxRange(m.range) : nil))
                }
            }
        }
        for range in fences {
            scan(NSRange(location:fence,length:range.location-fence))
            fence=NSMaxRange(range)
        }
        scan(NSRange(location:fence,length:s.length-fence))

        var sections:[IslandSection]=[], cursor=0
        var inheritedStyles=""
        var usedSheets=Set<Int>(), proseRanges:[(index:Int,range:NSRange)]=[]
        for card in candidates where card.opening.location >= cursor {
            let at=card.opening.location
            var line=at
            while line>0 && (s.character(at:line-1)==9 || s.character(at:line-1)==32) { line -= 1 }
            let lineStart=line==0 || s.character(at:line-1)==10
            if lineStart && (at-line >= 4 || s.substring(with:NSRange(location:line,length:at-line)).contains("\t")) { continue }
            let opening=s.substring(with:card.opening)
            let attributes = divAttributes(opening,tag:card.tag)
            let explicit = attributes?.root == true
            // Plain regex wrappers are accepted only when balanced. Legacy explicit
            // roots and streaming visual DIVs may still be presented progressively.
            let end=card.end ?? s.length
            guard explicit || end-at <= 256*1024 else { continue }
            let body=s.substring(with:NSRange(location:at,length:end-at))
            let visual=card.tag=="div" && lineStart &&
                body.range(of:#"(?i)<(?:canvas|script|style|img|svg)\b"#,options:.regularExpression) != nil
            var start=at, probe=skipWhitespace(at,backwards:true), attached:[NSRange]=[]
            while let token=prefixEndingAt[probe], token.location>=cursor {
                if styleStartingAt[token.location] != nil { attached.append(token); start=token.location }
                probe=skipWhitespace(token.location,backwards:true)
            }
            let selectors=attributes?.selectors ?? []
            let scoped=detached.filter {
                (NSMaxRange($0.range)<=start || $0.range.location>=end) && !$0.selectors.isDisjoint(with:selectors)
            }
            let semantic = (blockRoots.contains(card.tag) && card.tag != "div") || start < at || attributes?.styled == true || !scoped.isEmpty
            let promoted = regexOutput && !unchangedFragments.contains(body)
            guard explicit || (streaming && card.tag=="svg") || (visual && (streaming || card.end != nil))
                || (card.end != nil && (promoted || semantic)) else { continue }
            var last=attachedScriptsEnd(in:s,from:end)
            let gap=s.substring(with:NSRange(location:cursor,length:start-cursor))
            if !gap.isEmpty { proseRanges.append((sections.count,NSRange(location:cursor,length:start-cursor))); sections.append(.markdown(gap)) }
            if !gap.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { inheritedStyles="" }
            // A sheet directly above multiple sibling cards must travel with each
            // isolated document. New sheets take precedence; prose ends the group.
            let inherited=attached.isEmpty ? inheritedStyles : ""
            if !attached.isEmpty { inheritedStyles=attached.reversed().map { s.substring(with:$0) }.joined(separator:"\n") }
            // A trailing sheet at the end belongs to this card, not to native Markdown.
            var trailing=last
            while let style=styleStartingAt[skipWhitespace(trailing,backwards:false)] { trailing=NSMaxRange(style) }
            if trailing>last, skipWhitespace(trailing,backwards:false)==s.length { last=trailing }
            // A model may put explanatory prose between a stylesheet and the class
            // that uses it. Copy only sheets naming this root, never styles inside another card.
            var prefix="", suffix=""
            for sheet in scoped {
                usedSheets.insert(sheet.range.location)
                let css=s.substring(with:sheet.range)
                if NSMaxRange(sheet.range)<=start {
                    if !inherited.contains(css) { prefix += css+"\n" }
                } else if sheet.range.location>=last { suffix += "\n"+css }
            }
            sections.append(.island(prefix + inherited + s.substring(with:NSRange(location:start,length:last-start)) + suffix))
            cursor=last
        }
        if sections.isEmpty { return [.markdown(source)] }
        if cursor<s.length { proseRanges.append((sections.count,NSRange(location:cursor,length:s.length-cursor))); sections.append(.markdown(s.substring(from:cursor))) }
        for (index,range) in proseRanges {
            let removed=detached.filter { usedSheets.contains($0.range.location) && $0.range.location>=range.location && NSMaxRange($0.range)<=NSMaxRange(range) }
            if !removed.isEmpty {
                let text=NSMutableString(string:s.substring(with:range))
                for sheet in removed.reversed() { text.deleteCharacters(in:NSRange(location:sheet.range.location-range.location,length:sheet.range.length)) }
                sections[index] = .markdown(text as String)
            }
        }
        return sections
    }

    static func codeFences(_ source: String) -> [NSRange] {
        guard source.contains("```") || source.contains("~~~") else { return [] }
        var ranges: [NSRange] = []; var opened: (Int, String, Int)?; var offset = 0
        let s = source as NSString
        for raw in source.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let (start, marker, count) = opened {
                if let m = matchPattern("^ {0,3}(`+|~+)[ \\t]*$", line), m.count > 1, m[1].hasPrefix(marker), m[1].count >= count {
                    ranges.append(NSRange(location: start, length: min(s.length, offset + raw.utf16.count + 1) - start))
                    opened = nil
                }
            } else if let m = matchPattern("^ {0,3}(`{3,}|~{3,})(.*)$", line), m.count > 2, !(m[1].hasPrefix("`") && m[2].contains("`")) {
                opened = (offset, String(m[1].prefix(1)), m[1].count)
            }
            offset += raw.utf16.count + 1
        }
        if let (start, _, _) = opened { ranges.append(NSRange(location: start, length: s.length - start)) }
        return ranges
    }

    private static func matchPattern(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return nil }
        let s = text as NSString
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : s.substring(with: m.range(at: $0)) }
    }

    private static let trailingScript = try! NSRegularExpression(
        pattern: #"(?is)\s*<script\b[^>]*>.*?</script\s*>"#
    )
    private static func attachedScriptsEnd(in text: NSString, from start: Int) -> Int {
        var end = start
        while end < text.length,
              let match = trailingScript.firstMatch(in: text as String, options: .anchored,
                                                    range: NSRange(location: end, length: text.length - end)) {
            end = NSMaxRange(match.range)
        }
        return end
    }

    public static func document(_ source: String, motion: Bool, media: Bool, dark: Bool, emphasisColor: String? = nil, topicMedia: Bool = false) -> String {
        let color = dark ? "dark" : "light"
        let image = media ? (topicMedia ? "data: vchat-image:" : "https: data: vchat-image:") : "'none'"
        let emphasis = emphasisColor ?? (dark ? "#88d6b0" : "#278752")
        let noMotion = motion ? "" : "*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}"
        return """
        <!doctype html><html data-vcp-host-theme="\(color)" data-vcp-motion="\(motion ? "on" : "off")"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src \(image); media-src \(media ? "https: data: vchat-image:" : "'none'"); font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><style>:root{color-scheme:\(color)}html,body{background:transparent;color:CanvasText;margin:0;padding:0;font:16px -apple-system;overflow-wrap:anywhere}body{display:flow-root}#vcp-root{max-width:100%;box-sizing:border-box}img,video,svg,canvas{max-width:100%}svg[viewBox]:not([height]){height:auto}img.vcp-standalone-photo{display:block;width:100%!important;height:auto!important;max-height:720px;object-fit:contain}pre{white-space:pre-wrap}:root{--vcp-md-emphasis:\(emphasis)}strong.vcp-md-strong{color:var(--vcp-md-emphasis);font-weight:700}\(noMotion)</style></head><body>\(source)</body></html>
        """
    }
}

private enum IslandScripts {
    static let runtime: String? = load(["marked.min", "morphdom.min", "bubble-markdown", "bubble-resources", "bubble-stream"])
    static func load(_ names: [String]) -> String? {
        var scripts: [String] = []
        for name in names {
            guard let url = Bundle.module.url(forResource: name,withExtension: "js"),let source = try? String(contentsOf: url,encoding: .utf8) else { return nil }
            scripts.append(source)
        }
        return scripts.joined(separator: "\n;\n")
    }
}

extension HTMLIslandPolicy {
    @MainActor static func shell(options: RenderOptions, environment: EnvironmentValues) -> String {
        let color = environment.messageEmphasisColor.resolve(in: environment)
        let hex = String(format: "#%02x%02x%02x",Int(min(1,max(0,color.red)) * 255),Int(min(1,max(0,color.green)) * 255),Int(min(1,max(0,color.blue)) * 255))
        return document("",motion: options.motion && !environment.accessibilityReduceMotion,media: options.media,
                        dark: environment.colorScheme == .dark,emphasisColor: hex,topicMedia: environment.topicMediaOwner != nil)
    }
}

private struct ViewportKey: EnvironmentKey { static let defaultValue: CGRect? = nil }
extension EnvironmentValues { public var messageViewport: CGRect? { get { self[ViewportKey.self] } set { self[ViewportKey.self] = newValue } } }
@MainActor @Observable final class IslandPool {
    static let shared = IslandPool()
    private var idle: [WKWebView] = []
    private var active: [UUID: WKWebView] = [:]
    @ObservationIgnored private var parked: [UUID:() -> Void] = [:]
    var revision = 0
    func attach(_ id: UUID) { parked[id] = nil }
    func park(_ id: UUID, evict: @escaping () -> Void) {
        parked[id] = evict
        revision += 1
    }
    func take(_ id: UUID, speculative: Bool) -> WKWebView? {
        if let view = active[id] { return view }
        let limit = speculative ? TranscriptRenderBuffer.parkedLimit : TranscriptRenderBuffer.visibleLimit
        if !speculative, active.count >= limit { parked.values.first?() }
        guard active.count < limit else { return nil }
        let view: WKWebView
        if let reusable = idle.popLast() { view = reusable }
        else {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(IslandImageScheme(),forURLScheme:IslandImageScheme.name)
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
            #if os(iOS)
            config.allowsInlineMediaPlayback = true; config.mediaTypesRequiringUserActionForPlayback = .all
            #endif
            view = WKWebView(frame: .zero, configuration: config)
            #if os(iOS)
            view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
            view.scrollView.showsVerticalScrollIndicator = false
            view.scrollView.pinchGestureRecognizer?.isEnabled = false
            #else
            view.underPageBackgroundColor = .clear
            #endif
        }
        active[id] = view
        return view
    }
    func release(_ id: UUID) {
        parked[id] = nil
        guard let view = active.removeValue(forKey: id) else { return }
        view.stopLoading(); (view.configuration.urlSchemeHandler(forURLScheme:IslandImageScheme.name) as? IslandImageScheme)?.invalidate(); view.setAllMediaPlaybackSuspended(true)
        view.navigationDelegate = nil; view.uiDelegate = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.configuration.userContentController.removeAllUserScripts()
        view.loadHTMLString("", baseURL: nil)
        if idle.count < 3 { idle.append(view) }
        revision += 1
    }
}
@MainActor @Observable final class IslandController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private struct Input: Equatable { var source: String; var streaming: Bool }
    let id = UUID()
    var view: WKWebView?
    var height: CGFloat = 180
    @ObservationIgnored var remember: ((CGFloat,CGFloat)->Void)?
    var failed = false
    var failureMessage = "气泡已暂停，重新进入可加载"
    @ObservationIgnored private var document = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var navigation: WKNavigation?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var latest: Input?
    @ObservationIgnored private var pending: Input?
    @ObservationIgnored private var updateTask: Task<Void,Never>?
    func mount(_ document: String, source: String, streaming: Bool, media: Bool, stickers: StickerContext, owner:TopicMediaScope?, speculative: Bool = false, initialWidth: CGFloat? = nil) {
        guard let runtime = IslandScripts.runtime else { failed = true; failureMessage = "气泡渲染组件缺失，请更新 App"; return }
        guard let web = view ?? IslandPool.shared.take(id, speculative: speculative) else { return }
        if view == nil, let initialWidth { web.frame = CGRect(x: 0,y: 0,width: initialWidth,height: height) }
        let imageScheme=web.configuration.urlSchemeHandler(forURLScheme:IslandImageScheme.name) as? IslandImageScheme
        let contextChanged=imageScheme?.stickers != stickers || imageScheme?.owner != owner
        imageScheme?.stickers=stickers;imageScheme?.owner=owner;imageScheme?.mediaEnabled=media
        let input = Input(source: source,streaming: streaming)
        let editingCompleted = latest.map { $0.source != input.source && (!$0.streaming || !input.source.hasPrefix($0.source)) } ?? false
        if view != nil,self.document == document,!editingCompleted,!contextChanged {
            if latest != input { latest = input; pending = input; drain() }
            return
        }
        updateTask?.cancel(); updateTask = nil; generation = UUID(); ready = false
        view = web; self.document = document; latest = input; pending = input; failed = false
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.add(self,contentWorld: .defaultClient,name: "vcpHeight")
        // The isolated host world exposes only measured height, never native commands.
        let epoch = generation.uuidString
        let script = "window.VCPTopicMedia=" + (owner == nil ? "false;" : "true;") + "window.VCPBubbleEpoch='" + epoch + "';\n" + runtime + "\n;" + """
        (()=>{
            const epoch='\(epoch)'; let painted=false,lastHeight=-1,lastWidth=-1;
            function measure() {
                if (!painted) return;
                const rect=document.body.getBoundingClientRect(), h=Math.ceil(rect.height), w=Math.round(rect.width);
                if (h>0 && w>0 && (lastHeight!==h || lastWidth!==w)) {
                    lastHeight=h;lastWidth=w;window.webkit.messageHandlers.vcpHeight.postMessage({height:h,width:w,epoch});
                }
            }
            document.addEventListener('vcp-bubble-painted',()=>{painted=true; measure()});
            new ResizeObserver(measure).observe(document.body);
        })();
        """
        web.configuration.userContentController.addUserScript(WKUserScript(source: script,injectionTime: .atDocumentEnd,forMainFrameOnly: true,in: .defaultClient))
        web.navigationDelegate = self; web.setAllMediaPlaybackSuspended(!media)
        navigation = web.loadHTMLString(document,baseURL: nil)
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) {
        guard webView === view,navigation === self.navigation else { return }
        ready = true; drain()
    }
    private func drain() {
        guard ready,updateTask == nil,let web = view,pending != nil else { return }
        let own = generation
        updateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,generation == own,let input = pending {
                pending = nil
                do {
                    // The public refined Objective-C entry point avoids Xcode 16.4's
                    // missing Swift WebKit overlay in older simulator runtimes.
                    try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void,any Error>) in
                        web.__callAsyncJavaScript("window.VCPBubbleStream.update(source,streaming,epoch)",arguments: ["source":input.source,"streaming":input.streaming,"epoch":own.uuidString],inFrame: nil,in: .defaultClient) { _,error in
                            if let error { reply.resume(throwing: error) } else { reply.resume() }
                        }
                    }
                } catch {
                    if generation == own,!Task.isCancelled { failed = true; failureMessage = "气泡更新失败，重新进入可加载"; unmount() }
                    break
                }
            }
            if generation == own { updateTask = nil }
        }
    }
    func unmount() {
        generation = UUID(); updateTask?.cancel(); updateTask = nil; pending = nil; latest = nil; ready = false; navigation = nil
        view = nil; document = ""; IslandPool.shared.release(id)
    }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,let payload = message.body as? [String:Any],payload["epoch"] as? String == generation.uuidString,let number = payload["height"] as? NSNumber else { return }
        let value = number.doubleValue
        if value.isFinite, value > 0, let w=(payload["width"] as? NSNumber)?.doubleValue, w.isFinite, w>0 {
            let measured = CGFloat(max(44,value))
            if abs(height-measured)>=1 { height=measured }
            remember?(measured,CGFloat(w))
        }
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" && navigationAction.navigationType == .other ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true; unmount() }
}

struct HTMLIsland: View {
    @Environment(\.self) private var environment
    var source: String
    var options: RenderOptions
    var streaming = false
    var slot: IslandSlot? = nil
    @Environment(\.transcriptRenderBuffer) private var buffer
    @State private var controller: IslandController?
    @State private var reservedHeight: CGFloat = 180
    private struct Visibility: Equatable { var width:CGFloat = 0; var onScreen=false }
    @State private var layout = Visibility()
    @Environment(\.topicMediaOwner) private var owner
    @Environment(\.messageLayoutMemory) private var memory
    @Environment(\.renderedMessageID) private var messageID
    @State private var appeared = false
    @Environment(\.messageViewport) private var viewport
    @Environment(\.scenePhase) private var phase
    @Environment(\.stickerContext) private var stickers
    @Environment(\.messageLongPressAction) private var showMessageActions
    private var visible: Bool { appeared && phase == .active && (viewport == nil || layout.onScreen) }
    private var heightVariant:String { String(document.hashValue) }
    private func restoreSize() {
        if let h=memory?.islandHeight(messageID:messageID,source:source,width:layout.width,variant:heightVariant) { reservedHeight=h; controller?.height=h }
    }
    private var document: String {
        HTMLIslandPolicy.shell(options: options, environment: environment)
    }
    var body: some View {
        Group {
            if let controller, let view = controller.view { IslandNativeView(view: view,showActions: showMessageActions).id(ObjectIdentifier(view)).frame(height: controller.height) }
            else if let controller, controller.failed { Label(controller.failureMessage, systemImage: "arrow.clockwise").font(.callout).frame(height: controller.height) }
            else { Label(visible ? "等待加载视觉气泡" : "视觉气泡已暂停", systemImage: "rectangle.inset.filled").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: controller?.height ?? reservedHeight) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onGeometryChange(for: Visibility.self,of: { [viewport] g in
            let rect=g.frame(in:.named("vcp-message-viewport"))
            return Visibility(width:g.size.width.rounded(),onScreen:viewport?.intersects(rect) ?? true)
        }) { layout=$0 }
        .onChange(of:layout.width) { _,_ in restoreSize() }
        .task(id:visible) {
            if visible { restoreSize(); refresh() }
            else { release() }
        }
        .onAppear { appeared = true; refresh() }.onDisappear { appeared = false; release() }
        .onChange(of: owner) { _,_ in refresh() }
        .onChange(of: stickers) { _, _ in refresh() }
        .onChange(of: document) { _, _ in refresh() }
        .onChange(of: source) { _, _ in refresh() }
        .onChange(of: streaming) { _, _ in refresh() }
        .onChange(of: IslandPool.shared.revision) { _, _ in if visible && controller?.view == nil && controller?.failed != true { refresh() } }
    }
    private func refresh() {
        guard visible else { return }
        let needsAttachment = controller?.view == nil
        let host = controller ?? slot.flatMap { buffer?.checkout($0) } ?? IslandController()
        if controller == nil {
            if host.view == nil { host.height = reservedHeight }
            controller = host
        }
        let id=messageID, value=source, variant=heightVariant
        host.remember = { [weak memory] h,w in memory?.rememberIslandHeight(h,messageID:id,source:value,width:w,variant:variant) }
        host.mount(document,source:source,streaming:streaming,media:options.media,stickers:stickers,owner:owner)
        if needsAttachment { host.view?.setAllMediaPlaybackSuspended(!options.media) }
    }
    private func release() {
        guard let host = controller else { return }
        reservedHeight = host.height
        controller = nil
        if let slot, let buffer { buffer.checkin(host, at: slot) }
        else { host.unmount() }
    }
}
// WebKit consumes SwiftUI ancestor gestures. Keep the recognizer native and
// remove only this host's recognizer when the pooled view is released.
#if os(iOS)
private struct IslandNativeView: UIViewRepresentable {
    var view: WKWebView
    var showActions: (@MainActor @Sendable () -> Void)?
    func makeCoordinator() -> IslandPressHandler { IslandPressHandler() }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.attach(to: view); return view }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.showActions = showActions; context.coordinator.gesture?.isEnabled = showActions != nil }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: IslandPressHandler) { coordinator.detach(from: uiView) }
}
@MainActor private final class IslandPressHandler: NSObject, UIGestureRecognizerDelegate {
    var showActions: (@MainActor @Sendable () -> Void)?
    var gesture: UILongPressGestureRecognizer?
    func attach(to view: WKWebView) {
        let press = UILongPressGestureRecognizer(target: self,action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.5; press.allowableMovement = 10; press.delegate = self
        gesture = press; view.addGestureRecognizer(press)
    }
    func detach(from view: WKWebView) { if let gesture { view.removeGestureRecognizer(gesture) }; gesture = nil; showActions = nil }
    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { showActions?() } }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#else
private struct IslandNativeView: NSViewRepresentable {
    var view: WKWebView
    var showActions: (@MainActor @Sendable () -> Void)?
    func makeCoordinator() -> IslandPressHandler { IslandPressHandler() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.attach(to: view); return view }
    func updateNSView(_ nsView: WKWebView, context: Context) { context.coordinator.showActions = showActions; context.coordinator.gesture?.isEnabled = showActions != nil }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: IslandPressHandler) { coordinator.detach(from: nsView) }
}
@MainActor private final class IslandPressHandler: NSObject, NSGestureRecognizerDelegate {
    var showActions: (@MainActor @Sendable () -> Void)?
    var gesture: NSPressGestureRecognizer?
    func attach(to view: WKWebView) {
        let press = NSPressGestureRecognizer(target: self,action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.5; press.allowableMovement = 10; press.delegate = self
        gesture = press; view.addGestureRecognizer(press)
    }
    func detach(from view: WKWebView) { if let gesture { view.removeGestureRecognizer(gesture) }; gesture = nil; showActions = nil }
    @objc private func pressed(_ gesture: NSPressGestureRecognizer) { if gesture.state == .began { showActions?() } }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
}
#endif
