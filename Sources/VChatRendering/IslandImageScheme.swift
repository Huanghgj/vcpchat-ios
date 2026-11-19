import Foundation
import WebKit
import VChatCore

/// Only the source of an image is transported here, never credentials for VCP APIs.
/// This handler is attached only to the isolated message WebView, not to the browser.
@MainActor final class IslandImageScheme: NSObject, WKURLSchemeHandler {
    static let name = "vchat-image"
    private let store: RemoteImageStore
    init(store: RemoteImageStore = .shared) { self.store=store; super.init() }
    var stickers = StickerContext()
    var mediaEnabled = false
    var owner:TopicMediaScope?
    private var tasks: [ObjectIdentifier:Task<Void,Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard mediaEnabled, let locator=urlSchemeTask.request.url, let kind=locator.host, ["asset","movie"].contains(kind),
              let encoded=URLComponents(url:locator,resolvingAgainstBaseURL:false)?.percentEncodedQuery,
              encoded.utf8.count <= 32000, let raw=encoded.removingPercentEncoding else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
        }
        let context = stickers, scope = owner, movie=locator.host=="movie"
        tasks[id] = Task {
            do {
                guard let target=await StickerResolver.shared.url(raw,in:context),target.scheme?.lowercased()=="https", !Task.isCancelled else {
                    throw URLError(.unsupportedURL)
                }
                let data:Data, mime:String
                if movie {
                    guard let scope else { throw URLError(.unsupportedURL) }
                    let v=try await TopicVideoStore.shared.resource(target,owner:scope)
                    data=v.data;mime=v.mime
                } else {
                    let v=try await store.resource(target,owner:scope)
                    data=v.data;mime=v.mime
                }
                guard !Task.isCancelled, tasks[id] != nil else { return }
                if movie, let header=urlSchemeTask.request.value(forHTTPHeaderField:"Range") {
                    guard let range=Self.byteRange(header,count:data.count),
                          let response=HTTPURLResponse(url:locator,statusCode:206,httpVersion:"HTTP/1.1",
                            headerFields:["Content-Type":mime,"Accept-Ranges":"bytes","Content-Length":String(range.count),
                                          "Content-Range":"bytes \(range.lowerBound)-\(range.upperBound-1)/\(data.count)"]) else { throw URLError(.badServerResponse) }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data.subdata(in:range))
                } else {
                    urlSchemeTask.didReceive(URLResponse(url:locator,mimeType:mime,expectedContentLength:data.count,textEncodingName:nil))
                    urlSchemeTask.didReceive(data)
                }
                tasks[id]=nil;urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled,tasks.removeValue(forKey:id) != nil else { return }
                urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey:ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    static func byteRange(_ header:String,count:Int) -> Range<Int>? {
        guard count>0,header.hasPrefix("bytes=") else { return nil }
        let parts=header.dropFirst(6).split(separator:"-",omittingEmptySubsequences:false)
        guard parts.count==2 else { return nil }
        if parts[0].isEmpty {
            guard let n=Int(parts[1]),n>0 else { return nil };return (count-min(n,count))..<count
        }
        guard let start=Int(parts[0]),start>=0,start<count else { return nil }
        if parts[1].isEmpty { return start..<count }
        guard let end=Int(parts[1]),end>=start else { return nil };return start..<(min(count-1,end)+1)
    }
    func invalidate() {
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        stickers = StickerContext(); owner=nil; mediaEnabled=false
    }
}
