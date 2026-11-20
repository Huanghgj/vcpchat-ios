import SwiftUI
import WebKit
import VChatCore
#if os(iOS)
import UIKit
#endif

public enum TranscriptPreloadDepth {
    public static let key = "transcript.preloadDepth"
    public static let standard = 10
    public static let range = 10...20
    public static func clamped(_ value:Int) -> Int { min(range.upperBound,max(range.lowerBound,value)) }

    /// Enumerate only the visible rows and their neighbours; a scroll jump must
    /// not visit the whole span between a disappearing and an arriving cell.
    public static func indices(count: Int, visible: [Int], depth: Int) -> [Int] {
        let depth = clamped(depth)
        guard count > 0 else { return [] }
        var seen = Set(visible.filter { (0..<count).contains($0) })
        if seen.isEmpty { seen.insert(count - 1) }
        let anchors = seen.sorted()
        var result = anchors
        for step in 1...depth {
            for anchor in anchors {
                for index in [anchor - step, anchor + step] where (0..<count).contains(index) && seen.insert(index).inserted {
                    result.append(index)
                }
            }
        }
        return result
    }
}

public struct TranscriptRenderItem: Equatable {
    let id: String
    let source: String
    let role: String
    let depth: Int
    let rules: [RegexRule]
    let streaming: Bool

    public init(id: String, source: String, role: String, depth: Int, rules: [RegexRule], streaming: Bool) {
        self.id = id; self.role = role; self.depth = rules.isEmpty ? 0 : depth; self.rules = rules
        // Only the displayed streaming row consumes live frames.
        self.source = streaming ? "" : source
        self.streaming = streaming
    }
}

struct IslandSlot: Hashable {
    let message: String
    let index: Int
    var path: String = ""
    func child(_ name: String) -> IslandSlot { .init(message:message,index:index,path:path + "/" + name) }
}
private struct ParentIslandKey: EnvironmentKey { static let defaultValue: IslandSlot? = nil }
extension EnvironmentValues {
    var parentIsland: IslandSlot? {
        get { self[ParentIslandKey.self] }
        set { self[ParentIslandKey.self] = newValue }
    }
}
private struct BufferKey: EnvironmentKey { static let defaultValue: TranscriptRenderBuffer? = nil }
public extension EnvironmentValues {
    var transcriptRenderBuffer: TranscriptRenderBuffer? {
        get { self[BufferKey.self] }
        set { self[BufferKey.self] = newValue }
    }
}

private struct PreparationContext: Equatable {
    var options: RenderOptions
    var shell: String
    var dark: Bool
    var stickers: StickerContext
    var owner: TopicMediaScope?
    var width: CGFloat
}

@MainActor public final class TranscriptRenderBuffer {
    @MainActor @Observable final class Window {
        var ids: Set<String> = []
    }
    let window = Window()
    #if os(iOS)
    weak var parkingView: UIView?
    #else
    weak var parkingView: NSView?
    #endif
    func attachParkedPages() {
        guard let parkingView else { return }
        for host in parked.values {
            if let web = host.view, web.superview !== parkingView { parkingView.addSubview(web) }
        }
    }
    private var generation = UUID()
    private var parked: [IslandSlot:IslandController] = [:]
    private var checkedOut: [IslandSlot:UUID] = [:]
    private struct Assets {
        var item: TranscriptRenderItem
        var islands: [(IslandSlot,String)] = []
        var images: [MessageMedia] = []
    }
    private var assets: [String:Assets] = [:]
    private var context: PreparationContext?
    private struct ImageKey: Hashable { var message: String; var source: String }
    private var attemptedImages: Set<ImageKey> = []
    private var images: [ImageKey:(raster: MediaRaster, expires: Date, cost: Int)] = [:]
    public init() {}

    func parkedController(at slot: IslandSlot) -> IslandController? { parked[slot] }

    func checkout(_ slot: IslandSlot) -> IslandController {
        let host = parked.removeValue(forKey: slot) ?? IslandController()
        checkedOut[slot] = host.id
        return host
    }

    func checkin(_ host: IslandController, at slot: IslandSlot) {
        guard checkedOut[slot] == host.id else { host.unmount(); return }
        checkedOut[slot] = nil
        guard window.ids.contains(slot.message), host.view != nil, !host.failed
        else { host.unmount(); return }
        park(host, at:slot)
    }

    private func park(_ host: IslandController, at slot: IslandSlot) {
        parked[slot] = host
        if let parkingView, let web = host.view {
            web.autoresizingMask = []
            parkingView.addSubview(web)
        }
    }

    private func discard(_ slot: IslandSlot) {
        parked.removeValue(forKey:slot)?.unmount()
    }

    func clear() {
        generation = UUID()
        window.ids.removeAll()
        for host in parked.values { host.unmount() }
        parked.removeAll(); assets.removeAll(); images.removeAll(); attemptedImages.removeAll(); context = nil
        // Visible hosts remain owned by their rows until checkin.
    }

    func image(message: String, source: String, owner: TopicMediaScope?, stickers: StickerContext) -> MediaRaster? {
        guard context?.owner == owner, context?.stickers == stickers,
              let entry = images[ImageKey(message: message, source: source)], entry.expires > Date() else { return nil }
        return entry.raster
    }

    fileprivate func prepare(_ items: [TranscriptRenderItem], context next: PreparationContext, memory: TranscriptLayoutMemory?) async {
        // A keyboard/width change should resize a live document, not restart it.
        var previous = context
        previous?.width = next.width
        if previous != next { clear() }
        if context?.width != next.width {
            for host in parked.values { host.view?.frame.size.width = next.width }
        }
        context = next
        let session = generation
        func current() -> Bool { !Task.isCancelled && generation == session }
        let eligible = Set(items.map(\.id))
        if window.ids != eligible { window.ids = eligible }
        assets = assets.filter { eligible.contains($0.key) }
        images = images.filter { eligible.contains($0.key.message) && $0.value.expires > Date() }
        for key in Array(parked.keys) where !eligible.contains(key.message) { discard(key) }

        for item in items where assets[item.id] != nil && assets[item.id]?.item != item {
            images = images.filter { $0.key.message != item.id }
            attemptedImages = attemptedImages.filter { $0.message != item.id }
            for slot in Array(parked.keys) where slot.message == item.id { discard(slot) }
        }

        // Let visible work begin first; fast flings cancel before launching speculative work.
        do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
        for item in items {
            guard current() else { return }
            if assets[item.id]?.item != item {
                var result = Assets(item: item)
                if !item.streaming, item.source.utf8.count < 200_000,
                   !RichMessageBody.isPlain(item.source, options: next.options, rules: item.rules) {
                    let input = RenderState.Input(source: item.source, options: next.options, dark: next.dark,
                                                  streaming: false, rules: item.rules, role: item.role, depth: item.depth)
                    let blocks: [RenderBlock]
                    if let hit = memory?.finishedReplies.object(forKey: item.id as NSString), hit.input == input { blocks = hit.blocks }
                    else {
                        guard let rendered = try? await MessageRenderer.shared.render(item.source, options: next.options, dark: next.dark,
                                                      rules: item.rules, role: item.role, depth: item.depth), current() else { continue }
                        blocks = rendered
                        if FinishedReply.admits(blocks) {
                            memory?.finishedReplies.setObject(FinishedReply(input,blocks),forKey:item.id as NSString,cost:2 * item.source.utf8.count)
                        }
                    }
                    for (index, block) in blocks.enumerated() {
                        if case .html(let html) = block,
                           html.range(of: #"<(?:video|audio)\b"#,options:[.regularExpression,.caseInsensitive]) == nil {
                            result.islands.append((IslandSlot(message:item.id,index:index),html))
                        }
                        block.collectImages(into: &result.images)
                    }
                }
                assets[item.id] = result
            }
        }
        guard current() else { return }

        // Budget speculative work per message. One card-heavy reply must not evict
        // the next ten replies; documents the reader already visited stay live within the window.
        for item in items {
            for (slot,html) in (assets[item.id]?.islands ?? []).prefix(2) where checkedOut[slot] == nil {
                guard parked[slot]?.view == nil else { continue }
                let host = IslandController()
                let variant = String(next.shell.hashValue)
                host.remember = { [weak memory] height,width in
                    memory?.rememberIslandHeight(height,messageID:slot.message,source:html,width:width,variant:variant)
                }
                host.mount(next.shell,source:html,streaming:false,media:next.options.media,stickers:next.stickers,
                           owner:next.owner,transcript:true,initialWidth:next.width)
                if host.view != nil { park(host, at:slot) }
            }
        }

        // A single image-heavy message must not start an unbounded series of downloads.
        var seen: Set<ImageKey> = [], candidates: [ImageKey] = []
        for item in items {
            for media in assets[item.id]?.images ?? [] {
                let key = ImageKey(message:item.id,source:media.source)
                if seen.insert(key).inserted { candidates.append(key) }
                if candidates.count == 16 { break }
            }
            if candidates.count == 16 { break }
        }
        attemptedImages.formIntersection(seen)
        images = images.filter { seen.contains($0.key) }
        for key in candidates where !attemptedImages.contains(key) {
            guard current() else { return }
            // A slow photo cannot delay another card's HTML or Markdown.
            guard let reply = try? await StickerResolver.shared.loadImage(key.source,in:next.stickers,fetch: { [owner = next.owner] url in
                try await RemoteImageStore.shared.resource(url,owner:owner)
            }), current()
            else { if current() { attemptedImages.insert(key) }; continue }
            guard reply.expires > Date(), let raster = try? await NativeMediaLoader.shared.localImage(reply.data), current()
            else { if current() { attemptedImages.insert(key) }; continue }
            memory?.rememberImage(CGSize(width:raster.width,height:raster.height),key.message,key.source)
            let cost = raster.image.bytesPerRow * raster.image.height + (raster.animation?.count ?? 0)
            if cost + images.values.reduce(0, { $0 + $1.cost }) <= 16 * 1024 * 1024 {
                images[key] = (raster, reply.expires, cost)
            }
            attemptedImages.insert(key)
        }
    }
}

private extension RenderBlock {
    func collectImages(into images: inout [MessageMedia]) {
        func append(_ runs: [InlineRun]) {
            for case .media(let media) in runs where media.kind == "image" && !media.source.lowercased().hasPrefix("data:") {
                images.append(media)
            }
        }
        switch self {
        case .paragraph(let runs), .heading(_,let runs): append(runs)
        case .table(let rows): for row in rows { for runs in row { append(runs) } }
        case .list(let lists,_): for list in lists { for block in list { block.collectImages(into: &images) } }
        case .quote(let blocks): for block in blocks { block.collectImages(into: &images) }
        default: break
        }
    }
}

public struct TranscriptPreloader: View {
    let items: [TranscriptRenderItem]
    let options: RenderOptions
    let buffer: TranscriptRenderBuffer
    let width: CGFloat
    let memory: TranscriptLayoutMemory?
    @Environment(\.self) private var environment
    public init(items: [TranscriptRenderItem], options: RenderOptions, buffer: TranscriptRenderBuffer, width: CGFloat, memory: TranscriptLayoutMemory?) {
        self.items = items; self.options = options; self.buffer = buffer; self.width = width; self.memory = memory
    }
    private struct Request: Equatable {
        var items: [TranscriptRenderItem]
        var context: PreparationContext
        var active: Bool
    }
    public var body: some View {
        let request = Request(items:items, context:.init(options:options,shell:HTMLIslandPolicy.shell(options:options,environment:environment),
                              dark:environment.colorScheme == .dark,stickers:environment.stickerContext,owner:environment.topicMediaOwner,width:width.rounded()),
                              active:environment.scenePhase == .active && width > 1)
        IslandParkingView(buffer:buffer).frame(width:1,height:1).clipped()
            .accessibilityHidden(true).allowsHitTesting(false)
            .task(id:request) {
                guard request.active, !request.items.isEmpty else { buffer.clear(); return }
                await buffer.prepare(items, context:request.context,memory:memory)
            }
            .onDisappear { buffer.clear() }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in buffer.clear() }
            #endif
    }
}

// WebKit throttles detached documents. Keep the actual page in the foreground
// window when List recycles a cell, at its measured width but clipped to one point.
#if os(iOS)
private struct IslandParkingView: UIViewRepresentable {
    let buffer: TranscriptRenderBuffer
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.clipsToBounds = true; host.isUserInteractionEnabled = false; host.accessibilityElementsHidden = true
        buffer.parkingView = host; buffer.attachParkedPages()
        return host
    }
    func updateUIView(_ host: UIView, context: Context) {}
}
#else
private struct IslandParkingView: NSViewRepresentable {
    let buffer: TranscriptRenderBuffer
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.wantsLayer = true; host.layer?.masksToBounds = true
        buffer.parkingView = host; buffer.attachParkedPages()
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {}
}
#endif
