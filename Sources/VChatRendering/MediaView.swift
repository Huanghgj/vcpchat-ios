import SwiftUI
import Observation
import AVKit
import VChatCore
@MainActor @Observable private final class VideoState {
    var player: AVPlayer?; var error: String?; var loading = false
    @ObservationIgnored private var worker: Task<Void,Never>?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var resource: VideoResource?
    @ObservationIgnored private var generation = UUID()
    func play(_ source: String, owner:TopicMediaScope?) {
        close(); error = nil; loading = true; let own = generation
        worker = Task {
            do {
                let resource = try await NativeMediaLoader.shared.video(source,owner:owner)
                guard generation == own,!Task.isCancelled else { await NativeMediaLoader.shared.release(resource); return }
                self.resource = resource
                let asset = AVURLAsset(url: resource.url)
                guard try await asset.load(.isPlayable) else { throw ClientError.server("当前设备不支持此视频格式") }
                try Task.checkCancellation(); guard generation == own else { return }
                let item = AVPlayerItem(asset: asset)
                observation = item.observe(\.status,options: [.new]) { [weak self] item,_ in
                    let failed = item.status == .failed,reason = item.error?.localizedDescription ?? "视频播放失败"
                    if failed { Task { @MainActor in if self?.generation == own { self?.error = reason; self?.loading = false } } }
                }
                player = AVPlayer(playerItem: item); player?.play(); loading = false
            } catch { if generation == own,!Task.isCancelled { loading = false; self.error = error.localizedDescription } }
        }
    }
    func close() {
        generation = UUID(); worker?.cancel(); worker = nil; loading = false; observation?.invalidate(); observation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let value = resource { resource = nil; Task { await NativeMediaLoader.shared.release(value) } }
    }
}
/// An inline remote photo uses the width proposed by its chat bubble, not a
/// thumbnail width copied from a model's HTML. Stickers keep their intended size.
struct MessageImageLayout: Layout {
    static let maximumHeight: CGFloat = 720
    let pixels: CGSize
    let widthLimit: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposed = proposal.width.flatMap { $0.isFinite ? max(0,$0) : nil }
        let width = min(proposed ?? min(pixels.width,widthLimit ?? 320), widthLimit ?? .greatestFiniteMagnitude)
        guard pixels.width > 0, pixels.height > 0 else { return .zero }
        let scale = min(width / pixels.width, Self.maximumHeight / pixels.height)
        return CGSize(width:pixels.width * scale, height:pixels.height * scale)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at:bounds.origin,anchor:.topLeading,proposal:ProposedViewSize(bounds.size))
    }
}

struct NativeMessageMedia: View {
    let item: MessageMedia; var animations: Bool
    @State private var image: MediaRaster?
    @State private var issue: String?
    @State private var appeared = false
    @State private var intersectsViewport = false
    @State private var viewing = false
    @State private var video = VideoState()
    @Environment(\.topicMediaOwner) private var owner
    @Environment(\.renderedMessageID) private var messageID
    @Environment(\.messageLayoutMemory) private var layoutMemory
    @State private var localSize:CGSize?
    @Environment(\.stickerContext) private var stickers
    @Environment(\.messageViewport) private var viewport
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var visible: Bool { appeared && phase != .background && (viewport == nil || intersectsViewport) }
    private struct Load: Equatable { var source: String; var stickers: StickerContext; var visible: Bool; var owner:TopicMediaScope? }
    private var expectedSize:CGSize? {
        if let localSize { return localSize }
        if let known=layoutMemory?.imageSize(messageID,item.source) { return known }
        guard let owner, !item.source.hasPrefix("data:"), let url=URL(string:item.source) else { return nil }
        return owner.imageSizes[RemoteImageStore.key(url)]
    }
    private var imageWidth: CGFloat? { item.inlineWidthLimit }
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            if item.kind == "video" {
                if let player = video.player { NativeVideoPlayer(player: player).frame(height: 220) }
                else { Button { video.play(item.source,owner:owner) } label: { VStack(spacing: 8) { Image(systemName: "play.circle.fill").font(.system(size: 46)); Text(video.loading ? "正在读取视频…" : "播放视频") }.frame(maxWidth: .infinity).frame(height: 180).background(.secondary.opacity(0.08),in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).disabled(video.loading || !visible) }
                if let error = video.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            } else if let image {
                MessageImageLayout(pixels:CGSize(width:image.width,height:image.height),widthLimit:imageWidth) {
                    Button { viewing = true } label: {
                        MediaImage(raster:image,animating:animations && !reduceMotion && visible && phase == .active)
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                            .clipShape(RoundedRectangle(cornerRadius:CGFloat(item.cornerRadius ?? 0)))
                    }.buttonStyle(.plain).accessibilityLabel(item.caption.isEmpty ? "打开图片" : "打开图片：" + item.caption)
                }
            } else if let issue { Label(issue,systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
            else if let size = expectedSize {
                MessageImageLayout(pixels:size,widthLimit:imageWidth) { Color.clear.accessibilityHidden(true) }
            } else { Label(visible ? "正在读取图片…" : "图片已暂停",systemImage: "photo").font(.caption).foregroundStyle(.secondary).frame(height: imageWidth.map { min($0, 180) } ?? 100) }
            if !item.caption.isEmpty && item.preferredWidth == nil { Text(verbatim:item.caption).font(.caption).foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal:false,vertical:true) }
            if issue != nil || video.error != nil,let url = URL(string: item.source),["https","http"].contains(url.scheme) { Link("打开原链接",destination: url).font(.caption) }
        }.frame(maxWidth: .infinity,alignment: .leading)
            .onGeometryChange(for:Bool.self,of:{ g in
                viewport?.intersects(g.frame(in:.named("vcp-message-viewport"))) ?? true
            }) { intersectsViewport=$0 }
            .onAppear { appeared = true }.onDisappear { appeared = false; video.close() }
            .onChange(of: owner) { _,_ in video.close(); image=nil; localSize=nil; issue=nil; viewing=false }
            .onChange(of: stickers) { _,_ in image=nil; localSize=nil; issue=nil; viewing=false }
            .onChange(of: item.id) { _,_ in video.close(); image = nil; localSize=nil; issue = nil; viewing = false }
            .onChange(of: visible) { _,v in if !v { video.close() } }
            .task(id: Load(source:item.id,stickers:stickers,visible:visible,owner:owner)) {
                guard visible,item.kind == "image", image == nil else { return }
                let source: String
                if item.source.lowercased().hasPrefix("data:") { source=item.source }
                else if let url=await StickerResolver.shared.url(item.source,in:stickers) { source=url.absoluteString }
                else { if !Task.isCancelled { issue="表情地址不完整，请设置服务器和 File Key" }; return }
                guard !Task.isCancelled else { return }
                if let owner, !source.hasPrefix("data:"), let url=URL(string:source) {
                    localSize=owner.imageSizes[RemoteImageStore.key(url)] ?? layoutMemory?.imageSize(messageID,item.source)
                }
                do {
                    let value = try await NativeMediaLoader.shared.image(source,owner:owner)
                    if !Task.isCancelled {
                        let size=CGSize(width:value.width,height:value.height)
                        localSize=size; layoutMemory?.rememberImage(size,messageID,item.source)
                        image=value; issue=nil
                    }
                }
                catch { if !Task.isCancelled { issue = error.localizedDescription } }
            }
            .sheet(isPresented: $viewing) { if let image { RasterViewer(image: image.image,title: item.caption.isEmpty ? "图片" : item.caption,animation: image.animation,animations: animations) } }
    }
}
struct MediaImage: View {
    let raster: MediaRaster; var animating: Bool
    var body: some View {
        if let data = raster.animation { RasterImageView(data: data,animating: animating) }
        else { Image(decorative: raster.image,scale: 1).resizable().scaledToFit() }
    }
}
#if os(iOS)
private struct NativeVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController { let view = AVPlayerViewController(); view.player = player; view.showsPlaybackControls = true; view.allowsPictureInPicturePlayback = false; return view }
    func updateUIViewController(_ view: AVPlayerViewController,context: Context) { if view.player !== player { view.player = player } }
    static func dismantleUIViewController(_ view: AVPlayerViewController,coordinator: ()) { view.player = nil }
}
#else
private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let view = AVPlayerView(); view.player = player; view.controlsStyle = .inline; view.showsFullScreenToggleButton = true; view.allowsPictureInPicturePlayback = false; return view }
    func updateNSView(_ view: AVPlayerView,context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView,coordinator: ()) { view.player = nil }
}
#endif
