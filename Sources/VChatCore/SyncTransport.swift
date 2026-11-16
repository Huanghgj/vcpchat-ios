import Foundation
public struct MobileSyncSettings: Codable, Sendable, Equatable {
    public var httpURL = ""; public var socketURL = ""; public init() {}
    public static func endpoint(_ raw: String) throws -> URL {
        let base = try ConnectionConfiguration(server: raw).baseURL(); guard let c = URLComponents(url: base,resolvingAgainstBaseURL: false),c.query == nil,c.fragment == nil else { throw SyncWire.fail("同步 HTTP 地址不能带查询参数") }
        var s = c; var path = s.path; while path.hasSuffix("/") { path.removeLast() }; if path.hasSuffix("/api/mobile-sync") { path.removeLast("/api/mobile-sync".count) }; s.path = path + "/api/mobile-sync"; return s.url!
    }
    public static func socket(_ raw: String,token: String) throws -> URL {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),["ws","wss"].contains(c.scheme),c.host != nil,c.user == nil,c.password == nil,c.fragment == nil,["","/","/ws-sync"].contains(c.path) else { throw SyncWire.fail("同步通道请填写 ws(s)://桌面地址:5975/ 或 /ws-sync") }
        var q = c.queryItems ?? []; q.removeAll { $0.name == "token" }; q.append(URLQueryItem(name: "token",value: token)); c.queryItems = q
        // A literal plus in a token must not become a form-urlencoded space.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+",with: "%2B"); guard let url = c.url else { throw ClientError.invalidConfiguration }; return url
    }
}
actor SyncChannel {
    private let socket = JSONSocket(); private var reader: Task<Void,Never>?; private var deadline: Task<Void,Never>?
    private var pending: (UUID,String,CheckedContinuation<JSONValue,Error>)?
    private var failure: (any Error)?
    func open(_ url: URL) async {
        let stream = await socket.connect(url,maximumBytes: 32 * 1024 * 1024,strictJSON: true)
        reader = Task { do { for try await value in stream { receive(value) }; fail(ClientError.interrupted) } catch { fail(error) } }
    }
    private func receive(_ value: JSONValue) {
        let type = value["type"].text
        if ["SYNC_LOG_EVENT","DESKTOP_PHASE_START","DESKTOP_PHASE_COMPLETE"].contains(type) { return }
        if type == "SYNC_ERROR" {
            do { fail(SyncWire.fail(try SyncWire.errorMessage(value["error"]))) }
            catch { fail(error) }
            return
        }
        guard let (_,expected,c) = pending,expected == type else { fail(SyncWire.fail("收到非预期同步帧")); return }
        pending = nil; deadline?.cancel(); deadline = nil; c.resume(returning: value)
    }
    private func fail(_ error: any Error) { failure = error; if let (_,_,c) = pending { pending = nil; c.resume(throwing: error) }; deadline?.cancel(); deadline = nil }
    func send(_ value: JSONValue) async throws { try Task.checkCancellation(); if let failure { throw failure }; try await socket.send(value) }
    func request(_ value: JSONValue,expected: String) async throws -> JSONValue {
        try Task.checkCancellation(); if let failure { throw failure }; guard pending == nil else { throw SyncWire.fail("同步请求尚未完成") }; let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                pending = (id,expected,c)
                // Desktop may reconcile its database before a manifest or topic hash reply.
                if !["SYNC_MANIFEST_RESULT","SYNC_TOPIC_DIFF_RESULT"].contains(expected) {
                    deadline = Task { do { try await Task.sleep(for: .seconds(60)); if pending?.0 == id { fail(ClientError.timeout); await socket.close() } } catch {} }
                }
                Task { do { try await send(value) } catch { if pending?.0 == id { fail(error) } } }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) async { if pending?.0 == id { fail(CancellationError()); await socket.close() } }
    func close() async { fail(CancellationError()); reader?.cancel(); reader = nil; await socket.close() }
}
struct SyncHTTP: Sendable {
    let endpoint: URL; let token: String
    private let network: URLSession
    init(endpoint: URL,token: String) {
        self.endpoint = endpoint; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 30
        network = URLSession(configuration: config,delegate: NoRedirectDelegate(),delegateQueue: nil)
    }

    private func bytes(_ path: String,body: Data?,mime: String,method: String = "POST") async throws
        -> (URLSession.AsyncBytes,HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = URL(string: endpoint.absoluteString + path) else { throw ClientError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + token,forHTTPHeaderField: "Authorization")
        request.setValue(mime,forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString,forHTTPHeaderField: "X-Idempotency-Key")
        let (stream,response) = try await network.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in stream {
                if data.count == 1_048_576 { throw ClientError.http(http.statusCode) }
                data.append(byte)
            }
            if let value = try? StrictJSON.decode(data), value.object["error"] != nil {
                throw SyncWire.fail(try SyncWire.errorMessage(value["error"]))
            }
            throw ClientError.http(http.statusCode)
        }
        return (stream,http)
    }
    private func response(_ path: String,body: Data?,mime: String,method: String = "POST",limit: Int) async throws -> HTTPDataReply {
        let (stream,http) = try await bytes(path,body: body,mime: mime,method: method)
        var data = Data()
        for try await byte in stream {
            data.append(byte)
            guard data.count <= limit else { throw ClientError.tooLarge }
        }
        return HTTPDataReply(data: data,status: http.statusCode,contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }
    func json(_ path: String,_ body: JSONValue) async throws -> JSONValue {
        try StrictJSON.decode(await response(path,body: JSONEncoder().encode(body),mime: "application/json",limit: 30_000_000).data)
    }
    func topicFrame(_ path: String,_ body: JSONValue) async throws -> JSONValue {
        try await topicFrame(path,data: JSONEncoder().encode(body),mime: "application/json")
    }
    func topicFrame(_ path: String,data: Data,mime: String = "application/x-ndjson") async throws -> JSONValue {
        let (stream,http) = try await bytes(path,body: data,mime: mime)
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("application/x-ndjson") == true else {
            throw SyncWire.fail("同步服务未返回 NDJSON")
        }
        var line = Data(), result: JSONValue?
        for try await byte in stream {
            guard byte == 10 else { line.append(byte); continue }
            defer { line.removeAll() }
            if line.allSatisfy({ [9,13,32].contains($0) }) { continue }
            let value = try StrictJSON.decode(line)
            if value["kind"] == .string("streamError") || value["ok"].bool == false {
                throw SyncWire.fail(try SyncWire.errorMessage(value["error"]))
            }
            guard result == nil,value["kind"] == .string("topic"),value["ok"].bool == true else {
                throw SyncWire.fail("同步 NDJSON 话题帧无效或重复")
            }
            result = value
        }
        guard line.isEmpty,let result else { throw SyncWire.fail("同步 NDJSON 不完整，未写入本机") }
        return result
    }
    func binary(_ path: String,data: Data? = nil,mime: String = "application/octet-stream") async throws -> HTTPDataReply {
        try await response(path,body: data,mime: mime,method: data == nil ? "GET" : "POST",limit: 20_000_000)
    }
}
