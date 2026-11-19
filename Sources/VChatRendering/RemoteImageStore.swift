import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VChatCore

struct RemoteImageReply: Sendable {
    let data: Data
    let status: Int
    let cacheControl: String
}
struct CachedRemoteImage: Sendable {
    let data: Data
    let mime: String
    let expires: Date
}

/// Encoded image bytes, shared by native messages and the isolated HTML renderer.
/// The filename is a digest of the *whole* URL, including its access path and query.
actor RemoteImageStore {
    static let shared: RemoteImageStore = {
        let http = VCPHTTP(allowingRedirects: false)
        return RemoteImageStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VChat-MessageImages-v1", isDirectory: true)) { url in
            let r = try await http.response(url, limit: 20_000_000)
            return RemoteImageReply(data: r.data, status: r.status, cacheControl: r.cacheControl)
        }
    }()

    let directory: URL
    private let fetch: @Sendable (URL) async throws -> RemoteImageReply
    private var pending: [String: Task<CachedRemoteImage, any Error>] = [:]
    private var generation = UUID()
    private var index: [URL:(size:Int, used:Date)] = [:]
    private var indexed = false
    private var diskBytes = 0
    private let budget = 128 * 1024 * 1024

    init(directory: URL, fetch: @escaping @Sendable (URL) async throws -> RemoteImageReply) {
        self.directory = directory; self.fetch = fetch
    }

    func resource(_ url: URL) async throws -> CachedRemoteImage {
        guard MessageMedia.isSafe(url.absoluteString), ["https","http"].contains(url.scheme?.lowercased() ?? "") else {
            throw ClientError.server("图片地址无效")
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        guard let canonical = parts?.url else { throw ClientError.invalidConfiguration }
        let id = SHA256.hash(data: Data(canonical.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        if let task = pending[id] { return try await task.value }
        let file = directory.appendingPathComponent(id)
        if let cached = read(file) { return cached }
        let own = generation
        let task = Task { () throws -> CachedRemoteImage in
            defer { if generation == own { pending[id] = nil } }
            let reply = try await fetch(canonical)
            try Task.checkCancellation()
            guard reply.status == 200 else { throw ClientError.http(reply.status) }
            guard let mime = Self.imageType(reply.data) else { throw ClientError.server("响应不是可显示的图片") }
            let expires = Date().addingTimeInterval(Self.lifetime(reply.cacheControl, url:canonical))
            let value = CachedRemoteImage(data: reply.data, mime: mime, expires: expires)
            if own == generation && expires > Date() { write(value, file: file) }
            return value
        }
        pending[id] = task
        return try await task.value
    }

    static func imageType(_ bytes: Data) -> String? {
        guard !bytes.isEmpty, bytes.count <= 20_000_000,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let raw = CGImageSourceGetType(source), let type = UTType(raw as String),
              type.conforms(to: .image), !type.conforms(to: .svg),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
              let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = props[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 60_000_000,
              let mime = type.preferredMIMEType, mime.hasPrefix("image/") else { return nil }
        return mime
    }

    private static func lifetime(_ control: String, url:URL) -> TimeInterval {
        let directives = control.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let names = directives.map { $0.components(separatedBy: "=")[0].trimmingCharacters(in: .whitespaces) }
        if names.contains("no-store") || names.contains("no-cache") { return 0 }
        let maximum: TimeInterval = 7 * 86400
        if let index = names.firstIndex(of: "max-age") {
            let parts = directives[index].components(separatedBy: "=")
            guard parts.count == 2, let age = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))) else { return 0 }
            // VCP ImageFileServer uses Express' default "public, max-age=0".
            // A named sticker is an offline conversation asset, not a live HTTP
            // preview. Scope this snapshot policy to unsigned-query VCP library URLs;
            // explicit privacy/revalidation rules and ordinary URLs keep HTTP behavior.
            let path=url.pathComponents
            if age==0, names.contains("public"), !names.contains("private"),
               !names.contains("must-revalidate"), !names.contains("proxy-revalidate"), url.query == nil,
               path.count==5, path[1].hasPrefix("pw="), path[1].count>3, path[2]=="images",
               EmoticonCatalog.pair(url) != nil { return maximum }
            return min(maximum, max(0, Double(age)))
        }
        return maximum
    }

    // One atomic file: ASCII expiration, newline, validated raster payload.
    private func read(_ file: URL) -> CachedRemoteImage? {
        let fm = FileManager.default
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_032,
              let raw = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        guard let split = raw.prefix(32).firstIndex(of: 10),
              let time = Double(String(decoding: raw[..<split], as: UTF8.self)), time.isFinite,
              time > Date().timeIntervalSince1970 else { discard(file); return nil }
        let data = raw.subdata(in: (split + 1)..<raw.endIndex)
        guard let mime = Self.imageType(data) else { discard(file); return nil }
        let now = Date()
        if indexed { record(file,size:raw.count,used:now) }
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        return CachedRemoteImage(data: data, mime: mime, expires: Date(timeIntervalSince1970: time))
    }

    private func discard(_ file:URL) {
        try? FileManager.default.removeItem(at:file)
        if let old=index.removeValue(forKey:file) { diskBytes -= old.size }
    }
    private func record(_ file:URL, size:Int, used:Date) {
        diskBytes += size - (index[file]?.size ?? 0)
        index[file]=(size,used)
    }
    private func loadIndex() throws {
        guard !indexed else { return }
        let keys:Set<URLResourceKey>=[.fileSizeKey,.contentModificationDateKey]
        for url in try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(keys),options:[.skipsHiddenFiles]) {
            if let meta=try? url.resourceValues(forKeys:keys), let size=meta.fileSize {
                record(url,size:size,used:meta.contentModificationDate ?? .distantPast)
            }
        }
        indexed=true
    }
    private func write(_ value: CachedRemoteImage, file: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try loadIndex()
            var bytes = Data((String(value.expires.timeIntervalSince1970) + "\n").utf8); bytes.append(value.data)
            #if os(iOS)
            try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try bytes.write(to: file, options: .atomic)
            #endif
            record(file,size:bytes.count,used:Date())
            if diskBytes > budget || index.count > 2048 {
                for (url, info) in index.sorted(by: { $0.value.used < $1.value.used }) {
                    guard diskBytes > budget || index.count > 2048 else { break }
                    if fm.fileExists(atPath:url.path) { try fm.removeItem(at:url) }
                    diskBytes -= info.size; index[url]=nil
                }
            }
        } catch { /* A full or protected cache must not break a successful image load. */ }
    }

    func clear() {
        generation = UUID(); for task in pending.values { task.cancel() }; pending.removeAll()
        index.removeAll(); diskBytes=0; indexed=false
        try? FileManager.default.removeItem(at: directory)
    }
}
