import SwiftUI
import VChatCore
#if os(iOS)
import UIKit
#endif

public enum TranscriptPreloadDepth {
    public static let key = "transcript.preloadDepth"
    public static let standard = 10
    public static let range = 0...20

    /// Enumerate only the visible rows and their neighbours; a scroll jump must
    /// not visit the whole span between a disappearing and an arriving cell.
    public static func indices(count: Int, visible: [Int], depth: Int) -> [Int] {
        let depth = min(range.upperBound,max(0,depth))
        guard depth > 0, count > 0 else { return [] }
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

struct IslandSlot: Hashable { let message: String; let index: Int }
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
    static let parkedLimit = 10
    static let visibleLimit = parkedLimit + 3
    private var generation = UUID()
    private var eligible: Set<String> = []
    private var parked: [IslandSlot:IslandController] = [:]
    // Preserve interaction state ahead of speculative documents when the window is full.
    private var lastViewed: [IslandSlot] = []
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
        lastViewed.removeAll { $0 == slot }
        IslandPool.shared.attach(host.id)
        checkedOut[slot] = host.id
        return host
    }

    func checkin(_ host: IslandController, at slot: IslandSlot) {
        guard checkedOut[slot] == host.id else { host.unmount(); return }
        checkedOut[slot] = nil
        guard eligible.contains(slot.message), host.view != nil, !host.failed
        else { host.unmount(); return }
        if parked.count >= Self.parkedLimit,
           let victim = parked.keys.first(where: { !lastViewed.contains($0) }) ?? lastViewed.first {
            discard(victim)
        }
        lastViewed.removeAll { $0 == slot }
        lastViewed.append(slot)
        park(host, at:slot)
    }

    private func park(_ host: IslandController, at slot: IslandSlot) {
        parked[slot] = host
        host.view?.setAllMediaPlaybackSuspended(true)
        IslandPool.shared.park(host.id) { [weak self] in self?.discard(slot) }
    }

    private func discard(_ slot: IslandSlot) {
        lastViewed.removeAll { $0 == slot }
        parked.removeValue(forKey:slot)?.unmount()
    }

    func clear() {
        generation = UUID()
        eligible.removeAll()
        for host in parked.values { host.unmount() }
        parked.removeAll(); lastViewed.removeAll(); assets.removeAll(); images.removeAll(); attemptedImages.removeAll(); context = nil
        // Visible hosts remain owned by their rows until checkin.
    }

    func image(message: String, source: String, owner: TopicMediaScope?, stickers: StickerContext) -> MediaRaster? {
        guard context?.owner == owner, context?.stickers == stickers,
              let entry = images[ImageKey(message: message, source: source)], entry.expires > Date() else { return nil }
        return entry.raster
    }

    fileprivate func prepare(_ items: [TranscriptRenderItem], context next: PreparationContext, memory: TranscriptLayoutMemory?) async {
        if context != next { clear(); context = next }
        let session = generation
        func current() -> Bool { !Task.isCancelled && generation == session }
        eligible = Set(items.map(\.id))
        assets = assets.filter { eligible.contains($0.key) }
        images = images.filter { eligible.contains($0.key.message) && $0.value.expires > Date() }
        for key in Array(parked.keys) where !eligible.contains(key.message) { discard(key) }

        for item in items where assets[item.id]?.item != item {
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

        // Resolve priority after the asynchronous parse pass, using the latest row leases.
        var wanted = Set(lastViewed)
        for item in items {
            for (slot,html) in assets[item.id]?.islands ?? [] where checkedOut[slot] == nil {
                if !wanted.contains(slot) {
                    guard wanted.count < Self.parkedLimit else { continue }
                    wanted.insert(slot)
                }
                guard parked[slot] == nil else { continue }
                if parked.count >= Self.parkedLimit, let victim = parked.keys.first(where: { !wanted.contains($0) }) {
                    discard(victim)
                }
                let host = IslandController()
                let variant = String(next.shell.hashValue)
                host.remember = { [weak memory] height,width in
                    memory?.rememberIslandHeight(height,messageID:slot.message,source:html,width:width,variant:variant)
                }
                host.mount(next.shell,source:html,streaming:false,media:next.options.media,stickers:next.stickers,
                           owner:next.owner,speculative:true,initialWidth:next.width)
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
            guard let url = await StickerResolver.shared.url(key.source,in:next.stickers), MessageMedia.isSafe(url.absoluteString),
                  current(), let reply = try? await RemoteImageStore.shared.resource(url,owner:next.owner), current()
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
        Color.clear.accessibilityHidden(true).allowsHitTesting(false)
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
