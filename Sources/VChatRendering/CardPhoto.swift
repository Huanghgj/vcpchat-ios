#if os(iOS)
import SwiftUI
import WebKit
import VChatCore

/// Hit-test the rendered document only after UIKit receives a real long press.
/// The bubble cannot invoke a Photos operation or open a native sheet by script.
struct CardPhoto: Identifiable {
    let id = UUID()
    let source: String
    let title: String
    static let hitTest = #"""
        const width = document.documentElement.clientWidth;
        const node = document.elementFromPoint(x * width, y * width);
        if (!node) return null;
        const img = node.closest('img');
        if (img && img.complete && img.naturalWidth) {
            const src = img.currentSrc || img.src;
            return src.length <= 28000000 ? [src, (img.alt || '图片').slice(0,80)] : null;
        }
        for (let el = node; el && el !== document.documentElement; el = el.parentElement) {
            const bg = getComputedStyle(el).backgroundImage.match(/^url\(["']?(.+?)["']?\)$/);
            if (bg && bg[1].length <= 28000000) return [bg[1], '背景图片'];
        }
        return null;
        """#
    init?(hit: [String]) {
        guard hit.count == 2 else { return nil }
        let locator = hit[0], raw: String
        if locator.hasPrefix("vchat-image://asset?") {
            let escaped = locator.dropFirst("vchat-image://asset?".count)
            guard escaped.utf8.count <= 32000, let value = escaped.removingPercentEncoding else { return nil }
            raw = value
        } else { raw = locator }
        guard (raw.lowercased().hasPrefix("https://") || raw.lowercased().hasPrefix("data:image/") || MessageMedia.relativeSticker(raw)),
              let media = MessageMedia(source: raw), media.kind == "image" else { return nil }
        source = raw; title = hit[1].isEmpty ? "图片" : String(hit[1].prefix(80))
    }
    func load(owner: TopicMediaScope?, stickers: StickerContext) async throws -> MediaRaster {
        if source.lowercased().hasPrefix("data:image/") { return try await NativeMediaLoader.shared.image(source, owner: owner) }
        return try await StickerResolver.shared.loadImage(source, in: stickers) { url in
            guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
            return try await NativeMediaLoader.shared.image(url.absoluteString, owner: owner)
        }
    }
}
struct CardPhotoPreview: View {
    let photo: CardPhoto, owner: TopicMediaScope?, stickers: StickerContext
    @Environment(\.dismiss) private var dismiss
    @State private var image: MediaRaster?, failed = false
    var body: some View {
        Group {
            if let image { RasterViewer(image: image.image, title: photo.title, animation: image.animation, original: image.original) }
            else {
                NavigationStack {
                    Group {
                        if failed { ContentUnavailableView("无法读取原图", systemImage: "photo", description: Text("图片可能已过期，请检查网络后重试。")) }
                        else { ProgressView("正在读取原图…") }
                    }.navigationTitle("图片").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                }
            }
        }.task(id: photo.id) {
            do { let value = try await photo.load(owner: owner, stickers: stickers); try Task.checkCancellation(); image = value }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}
#endif
