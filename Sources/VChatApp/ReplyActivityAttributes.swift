#if os(iOS)
import ActivityKit
import Foundation

struct ReplyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case waiting, complete, interrupted, stopped }
        var phase: Phase
        var label: String {
            switch phase {
            case .waiting: "正在等待 AI 回复"
            case .complete: "AI 回复已收到"
            case .interrupted: "回复已中断"
            case .stopped: "已停止生成"
            }
        }
        var symbol: String {
            switch phase {
            case .waiting: "ellipsis.message"
            case .complete: "checkmark.message"
            case .interrupted: "exclamationmark.bubble"
            case .stopped: "stop.circle"
            }
        }
    }
    let jobID: String
    let topicID: String
    let started: Date

    var url: URL? {
        var link = URLComponents()
        link.scheme = "vchat"; link.host = "reply"; link.queryItems = [URLQueryItem(name: "topic", value: topicID)]
        return link.url
    }
    static func topic(in url: URL) -> String? {
        guard url.scheme == "vchat", url.host == "reply" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "topic" }?.value
    }
}
#endif
