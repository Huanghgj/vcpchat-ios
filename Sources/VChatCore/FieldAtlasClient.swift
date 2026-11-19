import Foundation

public enum FieldAtlasResponseLimit: Int, CaseIterable, Sendable {
    case standard = 32, larger = 64, large = 128, unlimited = 0

    var bytes: Int { self == .unlimited ? .max : rawValue * 1024 * 1024 }
}

/// Only the packaged atlas page may ask for these read-only WarpedFieldAtlas routes.
public final class FieldAtlasClient: Sendable {
    private let configuration: ConnectionConfiguration
    private let key: String
    private let session: URLSession

    private let responseLimit: FieldAtlasResponseLimit

    public convenience init(configuration: ConnectionConfiguration, key: String, responseLimit: FieldAtlasResponseLimit = .standard) {
        self.init(configuration: configuration, key: key, responseLimit: responseLimit, sessionConfiguration: .ephemeral)
    }

    init(configuration: ConnectionConfiguration, key: String, responseLimit: FieldAtlasResponseLimit, sessionConfiguration config: URLSessionConfiguration) {
        self.responseLimit = responseLimit
        self.configuration = configuration
        self.key = key
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    static func endpoint(_ route: String, configuration: ConnectionConfiguration) throws -> URL {
        // Search terms come from encodeURIComponent. Do not allow raw separators, extra
        // parameters, arbitrary paths, hosts or schemes in a request carrying the chat key.
        let pattern = #"\A/(?:status|messages(?:\?q=(?:[A-Za-z0-9_.!~*'()-]|%[A-Fa-f0-9]{2})*)?|field/(?:tag|chunk)(?:/node/[0-9]{1,15}|/query\?(?:node=[0-9]{1,15}|message=[A-Za-z0-9_-]{8,128}(?:&radius=0\.[0-9]{1,4})?))?)\z"#
        guard route.utf8.count <= 612, route.range(of: pattern, options: .regularExpression) != nil
        else { throw ClientError.server("不支持的场图请求") }
        let parts = route.split(separator: "?", maxSplits: 1)
        let path = try configuration.endpoint("api/plugins/WarpedFieldAtlas" + String(parts[0]))
        guard var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else { throw ClientError.invalidConfiguration }
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        guard let url = components.url else { throw ClientError.invalidConfiguration }
        return url
    }

    public func get(_ route: String) async throws -> String {
        let url = try Self.endpoint(route, configuration: configuration)
        guard !key.isEmpty else { throw ClientError.server("请先在服务器设置中填写聊天 API Key。") }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        // Large snapshots must not grow the native buffer without bound before WebKit draws them.
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ClientError.server("未收到有效的服务器响应。") }
        let success = (200..<300).contains(http.statusCode)
        let limit = success ? responseLimit.bytes : 64 * 1024
        let oversized = success ? "场图响应超过 \(responseLimit.rawValue) MiB，请在场图右上角调高响应上限。" : "服务器返回的错误响应过大。"
        guard http.expectedContentLength <= Int64(limit) else { throw ClientError.server(oversized) }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(min(http.expectedContentLength, 32 * 1024 * 1024))) }
        for try await byte in bytes {
            guard data.count < limit else { throw ClientError.server(oversized) }
            data.append(byte)
        }
        if !success {
            if [401, 403].contains(http.statusCode) { throw ClientError.server("无权读取双曲场图，请检查聊天 API Key。") }
            if (300..<400).contains(http.statusCode) { throw ClientError.server("服务器返回重定向，请填写 VCP 的直接地址。") }
            if data.count < 64_000, let error = try? JSONDecoder().decode(PluginError.self, from: data), !error.message.isEmpty {
                throw ClientError.server(String(error.message.prefix(300)))
            }
            throw ClientError.server(http.statusCode == 404 ? "未找到双曲场图，请检查 VCP 服务器是否启用了 WarpedFieldAtlas 插件。" : "读取双曲场图失败（HTTP \(http.statusCode)）。")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ClientError.server("场图数据不是有效的 UTF-8。") }
        return text
    }

    public func close() { session.invalidateAndCancel() }
    private struct PluginError: Decodable { let message: String }
}
