import Foundation
import GRDB

public enum TopicSortMode: String, Codable, Sendable {
    case created, activity

    public func date(for topic: ChatTopic, lastMessage: Double?) -> Double {
        self == .created ? topic.createdAt : max(topic.createdAt, lastMessage ?? topic.createdAt)
    }

    public func sorted(_ topics: [ChatTopic], lastMessages: [String: Double]) -> [ChatTopic] {
        topics.sorted { a, b in
            let lhs = date(for: a, lastMessage: lastMessages[a.id])
            let rhs = date(for: b, lastMessage: lastMessages[b.id])
            if lhs != rhs { return lhs > rhs }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id < b.id
        }
    }
}

/// Device-local presentation only: one automatic preference, manual orders and fixed slots per owner.
public struct TopicOrdering: Codable, Equatable, Sendable {
    public private(set) var automatic: TopicSortMode = .activity
    private var manual: [String: [String]] = [:]
    private var pins: [String: [String: Int]] = [:]
    public init() {}

    public func isManual(_ scope: String) -> Bool { manual[scope] != nil }
    public func isPinned(_ id: String, in scope: String) -> Bool { pins[scope]?[id] != nil }

    public mutating func ring(in scope: String) {
        if manual.removeValue(forKey: scope) == nil {
            automatic = automatic == .created ? .activity : .created
        }
    }

    public mutating func togglePin(_ id: String, at index: Int, in scope: String) {
        if pins[scope]?.removeValue(forKey: id) == nil { pins[scope, default: [:]][id] = index }
    }

    public func sorted(_ topics: [ChatTopic], in scope: String, lastMessages: [String: Double]) -> [ChatTopic] {
        let ordered: [ChatTopic]
        if let manual = manual[scope] {
            let rows = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
            let known = Set(manual)
            // New topics remain visible at the front without disturbing the saved sequence.
            ordered = TopicSortMode.created.sorted(topics.filter { !known.contains($0.id) }, lastMessages: [:])
                + manual.compactMap { rows[$0] }
        } else {
            ordered = automatic.sorted(topics, lastMessages: lastMessages)
        }
        return fixedSlots(ordered, in: scope)
    }

    public mutating func saveMove(_ proposed: [ChatTopic], replacing visible: [ChatTopic], in scope: String) {
        let result = fixedSlots(proposed, in: scope).map(\.id)
        if !result.elementsEqual(visible.lazy.map(\.id)) { manual[scope] = result }
    }

    private func fixedSlots(_ rows: [ChatTopic], in scope: String) -> [ChatTopic] {
        guard let pins = pins[scope], !pins.isEmpty else { return rows }
        let fixed = rows.compactMap { row in pins[row.id].map { (slot: $0, row: row) } }
            .sorted { ($0.slot, $0.row.id) < ($1.slot, $1.row.id) }
        var free = rows.lazy.filter { pins[$0.id] == nil }.makeIterator()
        var next = 0
        return rows.indices.map { index in
            // Clamp slots when deletions shorten the list; keep the relative order of the pins.
            if next < fixed.count && index >= min(fixed[next].slot, rows.count - (fixed.count - next)) {
                defer { next += 1 }
                return fixed[next].row
            }
            return free.next()!
        }
    }
}

extension ChatStore {
    /// Use messages_topic(topicID, createdAt) to seek the newest real utterance per topic.
    /// Imported tool/system messages render as assistants but retain their wire role in originalRole.
    public func topicList() async throws -> (topics: [ChatTopic], lastMessages: [String: Double]) {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.payload, (SELECT m.createdAt FROM messages m
                    WHERE m.topicID=l.id AND coalesce(m.originalRole,m.role) IN ('user','assistant')
                    ORDER BY m.createdAt DESC LIMIT 1) AS lastMessage
                FROM library l WHERE l.kind='topic'
                """)
            var topics: [ChatTopic] = [], times: [String: Double] = [:]
            let decoder = JSONDecoder()
            for row in rows {
                let topic = try decoder.decode(ChatTopic.self, from: row["payload"])
                topics.append(topic)
                times[topic.id] = row["lastMessage"] as Double?
            }
            return (topics, times)
        }
    }
}
