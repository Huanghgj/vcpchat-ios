import Foundation
import SwiftUI
import CryptoKit
import VChatCore

/// Desktop's filename-first / category-second repair. Store names only, never catalog URLs or file keys.
public final class EmoticonCatalog: @unchecked Sendable, Equatable {
    public static func == (lhs: EmoticonCatalog, rhs: EmoticonCatalog) -> Bool { lhs === rhs }
    public let entries: [String:[String]]
    public let count: Int
    private struct Entry: Sendable { let pack, file, packKey, stem: String }
    private let items: [Entry]
    private let stems: [String:[Entry]], packs: [String:[Entry]]
    private static func key(_ name: String) -> String { name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased() }
    private static func safe(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 300 && ![".",".."].contains(s) && !s.contains("/") && !s.contains("\\") && !s.unicodeScalars.contains(where: { $0.value < 32 })
    }
    public init(entries: [String:[String]]) {
        var list: [Entry] = [], clean: [String:[String]] = [:]
        for pack in entries.keys.sorted() where Self.safe(pack) {
            for file in (entries[pack] ?? []) where Self.safe(file) && list.count < 20000 {
                let ext = (file as NSString).pathExtension.lowercased()
                guard ["png","jpg","jpeg","gif","webp","heic","avif","bmp","apng"].contains(ext) else { continue }
                list.append(Entry(pack: pack,file: file,packKey: Self.key(pack),stem: Self.key((file as NSString).deletingPathExtension)))
                clean[pack,default: []].append(file)
            }
        }
        self.entries = clean; items = list; count = list.count
        stems = Dictionary(grouping: list, by: \.stem); packs = Dictionary(grouping: list, by: \.packKey)
        matches.countLimit = 256
    }

    private static func similarity(_ a: String,_ b: String) -> Double {
        if a == b { return 1 }
        let x = Array(a.utf16), y = Array(b.utf16)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = Array(0...y.count)
        for i in x.indices {
            var diagonal = row[0]; row[0] = i + 1
            for j in y.indices {
                let above = row[j+1]
                row[j+1] = min(above+1, row[j]+1, diagonal + (x[i] == y[j] ? 0 : 1))
                diagonal = above
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count,y.count))
    }

    static func pair(_ url: URL) -> (pack: String,file: String)? {
        guard let c = URLComponents(url: url,resolvingAgainstBaseURL: false) else { return nil }
        let seg = c.percentEncodedPath.split(separator: "/")
        guard seg.count >= 2, let pack = String(seg[seg.count-2]).removingPercentEncoding,
              pack.contains("表情包"), let file = String(seg.last!).removingPercentEncoding, safe(pack), safe(file) else { return nil }
        return (pack,file)
    }

    // A catalog is immutable; repeated stream frames typically ask for the same small set of URLs.
    // NSCache is thread-safe; the other stored properties are immutable.
    private let matches = NSCache<NSString, NSString>()
    private func match(_ pack: String,_ file: String) -> Entry? {
        let pk = Self.key(pack), stem = Self.key((file as NSString).deletingPathExtension)
        if let exact = stems[stem] {
            if let full = exact.first(where: { $0.packKey == pk && $0.file == file }) { return full }
            if let same = exact.first(where: { $0.packKey == pk }) { return same }
            var best = exact[0], score = -1.0
            for e in exact { let s = Self.similarity(pk,e.packKey); if s > score { best = e; score = s } }
            return best
        }
        let group = packs[pk]
        var winner: Entry?, score = -1.0, packScores: [String:Double] = [:]
        for e in group ?? items {
            var s = Self.similarity(stem,e.stem)
            if group == nil {
                let ps = packScores[e.packKey] ?? Self.similarity(pk,e.packKey)
                packScores[e.packKey] = ps; s = 0.8*s + 0.2*ps
            }
            if s > score { winner = e; score = s }
        }
        return winner
    }
    public func repair(_ url: URL) -> URL {
        guard let pair=Self.pair(url), !items.isEmpty, var c=URLComponents(url:url,resolvingAgainstBaseURL:false) else { return url }
        let key = (pair.pack + "/" + pair.file) as NSString
        let suffix: String
        if let hit = matches.object(forKey:key) { suffix = hit as String }
        else {
            guard let entry=match(pair.pack,pair.file) else { return url }
            suffix = Self.encode(entry.pack) + "/" + Self.encode(entry.file)
            matches.setObject(suffix as NSString,forKey:key)
        }
        let path=c.percentEncodedPath
        guard let end=path.lastIndex(of:"/"), let prev=path[..<end].lastIndex(of:"/") else { return url }
        c.percentEncodedPath = String(path[...prev]) + suffix
        return c.url ?? url
    }
    static func encode(_ value:String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }
}

public struct StickerContext: Sendable, Equatable {
    public let server: URL?
    private let fileKey: String
    public let catalog: EmoticonCatalog?
    public init(server: URL? = nil, fileKey: String = "", catalog: EmoticonCatalog? = nil) {
        self.server=server; self.fileKey=fileKey; self.catalog=catalog
    }
    func resolve(_ source: String) -> URL? {
        guard var url=URL(string:source) else { return nil }
        guard let pair=EmoticonCatalog.pair(url), let server, server.user == nil, server.password == nil,
              var root=URLComponents(url:server,resolvingAgainstBaseURL:false), let host=root.host else {
            return MessageMedia.isSafe(source) ? url : nil
        }
        let parts=url.pathComponents
        if url.scheme == nil {
            guard url.host == nil, !source.hasPrefix("//"), !fileKey.isEmpty, MessageMedia.relativeSticker(source) else { return nil }
            root.query=nil;root.fragment=nil
            root.percentEncodedPath="/pw=" + EmoticonCatalog.encode(fileKey) + "/images/" + EmoticonCatalog.encode(pair.pack) + "/" + EmoticonCatalog.encode(pair.file)
            guard let absolute=root.url else { return nil };url=absolute
        } else {
            guard MessageMedia.isSafe(source) else { return nil }
            guard url.host?.lowercased() == host.lowercased() else { return url }
            // VCP sometimes publishes its backend port behind a same-host HTTPS reverse proxy.
            // Never carry a source credential to another host or downgrade TLS.
            if url.scheme == "https",root.scheme == "https",url.port == 6005,(root.port == nil || root.port == 443),
               parts.count == 5,parts[1].hasPrefix("pw="),parts[2]=="images",
               var c=URLComponents(url:url,resolvingAgainstBaseURL:false) { c.port=root.port;url=c.url ?? url }
            guard url.scheme?.lowercased()==root.scheme?.lowercased(),
                  (url.port ?? (url.scheme=="https" ? 443 : 80)) == (root.port ?? (root.scheme=="https" ? 443 : 80)) else { return url }
        }
        return catalog?.repair(url) ?? url
    }
    func imageCandidates(_ source: String) -> [URL] {
        guard let first = resolve(source) else { return [] }
        guard let url = URL(string:source), url.query == nil, let pair = EmoticonCatalog.pair(url) else { return [first] }
        var urls = [first]
        let parts = url.pathComponents
        let legacy = url.scheme == "https" && url.port == 6005 && parts.count == 5 &&
            parts[1].hasPrefix("pw=") && parts[1].count > 3 && parts[2] == "images"
        let sameHost = url.host?.lowercased() == server?.host?.lowercased()
        // The image server in a message need not be the chat API host. Only the
        // embedded ticket follows this same-host HTTPS proxy route, never an app secret.
        if legacy, var proxy = URLComponents(url:url,resolvingAgainstBaseURL:false) {
            proxy.port = nil
            if let publicURL = proxy.url {
                if sameHost && server?.port == 6005 { urls.append(publicURL) }
                else if first == url { urls.insert(publicURL,at:0) }
                urls.append(url)
            }
        }
        if sameHost || url.scheme == nil || legacy, let catalog, !fileKey.isEmpty, let server,
           var root = URLComponents(url:server,resolvingAgainstBaseURL:false), root.host != nil,
           root.user == nil, root.password == nil, ["http","https"].contains(root.scheme) {
            root.percentEncodedPath = "/pw=" + EmoticonCatalog.encode(fileKey) + "/images/" + EmoticonCatalog.encode(pair.pack) + "/" + EmoticonCatalog.encode(pair.file)
            root.query = nil; root.fragment = nil
            if let base = root.url {
                let canonical = catalog.repair(base)
                urls.insert(canonical,at:0)
            }
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

}
private struct StickerContextKey: EnvironmentKey { static let defaultValue=StickerContext() }
public extension EnvironmentValues {
    var stickerContext: StickerContext { get { self[StickerContextKey.self] } set { self[StickerContextKey.self]=newValue } }
}

public actor StickerDirectories {
    public static let shared = StickerDirectories()
    private let http = VCPHTTP(allowingRedirects: false)
    public static func origin(_ server: URL?) -> URL? {
        guard let server, var c=URLComponents(url:server,resolvingAgainstBaseURL:false),
              c.user == nil, c.password == nil, c.host != nil, ["http","https"].contains(c.scheme) else { return nil }
        c.path = ""; c.query=nil;c.fragment=nil
        return c.url
    }
    private func file(_ origin: URL) throws -> URL {
        let folder=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("VChat-StickerDirectories",isDirectory:true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories:true)
        let hash=SHA256.hash(data:Data(origin.absoluteString.utf8)).map{String(format:"%02x",$0)}.joined()
        return folder.appendingPathComponent(hash)
    }
    public func saved(_ origin: URL) -> EmoticonCatalog? {
        guard let url=try? file(origin), let bytes=try? Data(contentsOf:url),
              let entries=try? JSONDecoder().decode([String:[String]].self,from:bytes) else { return nil }
        return EmoticonCatalog(entries:entries)
    }
    private func save(_ entries: [String:[String]], for origin: URL) throws -> EmoticonCatalog {
        let catalog=EmoticonCatalog(entries:entries)
        guard catalog.count > 0 else { throw ClientError.server("没有可用的表情包分类和图片文件名") }
        try JSONEncoder().encode(catalog.entries).write(to: file(origin),options:.atomic)
        return catalog
    }
    public func refresh(origin: URL, username: String, password: String) async throws -> EmoticonCatalog {
        guard Self.origin(origin)==origin else { throw ClientError.invalidConfiguration }
        var headers: [String:String] = [:]
        if !username.isEmpty, !password.isEmpty {
            headers["Authorization"] = "Basic " + Data((username+":"+password).utf8).base64EncodedString()
        }
        let r=try await http.response(origin.appendingPathComponent("admin_api/emojis/list"),headers:headers,limit:4_000_000)
        if r.status == 401 || r.status == 403 { throw ClientError.server("表情目录需要授权。请在“身份与日记”保存管理员账号，或导入桌面表情目录。") }
        guard r.status==200 else { throw ClientError.server("表情目录接口 HTTP \(r.status)，可改用导入目录。") }
        try Task.checkCancellation()
        struct Response: Decodable { let success:Bool; let data:[String:[String]] }
        guard let result=try? JSONDecoder().decode(Response.self,from:r.data),result.success else { throw ClientError.server("服务器未返回表情目录") }
        return try save(result.data,for:origin)
    }
    public func importFile(_ url: URL, for origin: URL) throws -> EmoticonCatalog {
        let scoped=url.startAccessingSecurityScopedResource();defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size<=4_000_000 else { throw ClientError.server("目录上限为 4 MB") }
        let data=try Data(contentsOf:url)
        struct Entry: Decodable { let category:String; let filename:String }
        if let list=try? JSONDecoder().decode([Entry].self,from:data) {
            return try save(Dictionary(grouping:list,by:\.category).mapValues { $0.map(\.filename) },for:origin)
        }
        return try save(JSONDecoder().decode([String:[String]].self,from:data),for:origin)
    }
}

/// Fuzzy lookup can scan a catalog; never do it from a SwiftUI getter or a WebKit delegate.
actor StickerResolver {
    static let shared = StickerResolver()
    func loadImage<T:Sendable>(_ source:String, in context:StickerContext,
                               fetch: @Sendable (URL) async throws -> T) async throws -> T {
        let urls = context.imageCandidates(source)
        var last: any Error = ClientError.server("表情地址不完整，请检查服务器和 File Key")
        for url in urls {
            try Task.checkCancellation()
            do { return try await fetch(url) }
            catch is CancellationError { throw CancellationError() }
            catch { last = error }
        }
        throw last
    }

}
