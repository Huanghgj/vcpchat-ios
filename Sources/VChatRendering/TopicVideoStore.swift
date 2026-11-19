import Foundation
import VChatCore

/// Finite movie files are fetched on demand. HLS and oversized/live streams stay
/// with AVPlayer; they are not silently downloaded in their entirety.
actor TopicVideoStore {
    static let shared = TopicVideoStore()
    static let limit = 64 * 1024 * 1024
    typealias Fetch = @Sendable (URL) async throws -> (Data,Int,String,String)
    private let fetch:Fetch
    init(fetch:@escaping Fetch) { self.fetch=fetch }
    init() { fetch=Self.download }
    private final class DownloadPolicy: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let lock=NSLock()
        private var exceeded=false
        var tooLarge:Bool { lock.withLock { exceeded } }
        func urlSession(_ session:URLSession, downloadTask:URLSessionDownloadTask, didFinishDownloadingTo location:URL) {}
        func urlSession(_ session:URLSession, downloadTask:URLSessionDownloadTask, didWriteData bytesWritten:Int64,
                        totalBytesWritten:Int64, totalBytesExpectedToWrite:Int64) {
            if totalBytesWritten > TopicVideoStore.limit || totalBytesExpectedToWrite > TopicVideoStore.limit { lock.withLock { exceeded=true }; downloadTask.cancel() }
        }
        func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                        newRequest request:URLRequest,completionHandler:@escaping @Sendable (URLRequest?)->Void) { completionHandler(nil) }
    }
    private static func download(_ url:URL) async throws -> (Data,Int,String,String) {
        let cfg=URLSessionConfiguration.ephemeral
        cfg.urlCache=nil; cfg.httpShouldSetCookies=false;cfg.urlCredentialStorage=nil
        let session=URLSession(configuration:cfg)
        defer { session.finishTasksAndInvalidate() }
        let policyDelegate=DownloadPolicy()
        let tmp:URL, raw:URLResponse
        do { (tmp,raw)=try await session.download(for: URLRequest(url:url),delegate:policyDelegate) }
        catch { if policyDelegate.tooLarge { throw URLError(.dataLengthExceedsMaximum) }; throw error }
        defer { try? FileManager.default.removeItem(at:tmp) }
        guard let http=raw as? HTTPURLResponse, let n=try tmp.resourceValues(forKeys:[.fileSizeKey]).fileSize, n<=limit else { throw URLError(.dataLengthExceedsMaximum) }
        let policy = http.value(forHTTPHeaderField:"Vary")?.trimmingCharacters(in:.whitespaces) == "*" ? "no-store" : http.value(forHTTPHeaderField:"Cache-Control") ?? ""
        return (try Data(contentsOf:tmp,options:.mappedIfSafe),http.statusCode,http.value(forHTTPHeaderField:"Content-Type") ?? "",policy)
    }
    private var flights: [String:Task<(TopicResource,Bool),any Error>] = [:]

    static func fileExtension(_ mime:String) -> String {
        switch mime { case "video/webm": "webm"; case "video/ogg": "ogv"; case "video/quicktime": "mov"; default: "mp4" }
    }
    func resource(_ url:URL, owner:TopicMediaScope) async throws -> TopicResource {
        guard MessageMedia.isSafe(url.absoluteString), ["https","http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let key="video:"+RemoteImageStore.key(url)
        if let copy=try await owner.store.localResource(key:key,owner:owner.token) { return copy }
        let flight:Task<(TopicResource,Bool),any Error>
        if let current=flights[key] { flight=current }
        else {
            flight=Task {
                defer { flights[key]=nil }
                let (data,status,contentType,control)=try await fetch(url)
                guard status==200 else { throw ClientError.http(status) }
                guard data.count<=Self.limit else { throw URLError(.dataLengthExceedsMaximum) }
                let type=contentType.components(separatedBy:";")[0].lowercased()
                let mime:String
                if data.count>=12, data[4..<8].elementsEqual("ftyp".utf8) { mime = url.pathExtension.lowercased()=="mov" ? "video/quicktime" : "video/mp4" }
                else if data.starts(with:[0x1a,0x45,0xdf,0xa3]) { mime="video/webm" }
                else if data.starts(with:"OggS".utf8) { mime="video/ogg" }
                else { throw ClientError.server("该视频无法保存为离线文件") }
                guard type.isEmpty || type.hasPrefix("video/") || type=="application/octet-stream" || type=="application/ogg" else { throw ClientError.invalidResponse }
                return (TopicResource(data:data,mime:mime), RemoteImageStore.mayArchive(control))
            }
            flights[key]=flight
        }
        let (resource,save)=try await flight.value
        if save { try await owner.store.saveLocalResource(resource,key:key,owner:owner.token) }
        return resource
    }
}
