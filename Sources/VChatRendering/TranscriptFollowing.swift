import Foundation

/// Manual reading remains sticky until the user explicitly requests the latest reply.
public struct TranscriptFollowing: Equatable, Sendable {
    public enum Mode: Sendable { case following, reading, paused }
    public private(set) var mode = Mode.following
    public private(set) var interacting = false
    public var canScrollToLatest: Bool { mode == .following && !interacting }
    public init() {}
    public mutating func markReading() { if mode == .following { mode = .reading } }
    public mutating func beginInteraction() {
        interacting = true
        markReading()
    }
    public mutating func endInteraction(atLatest: Bool) {
        interacting = false
        // Content growth and a bounce near the bottom are not user consent to resume.
        // Only resume() or entry into a new topic re-enables following.
    }
    public mutating func pause() { mode = .paused }
    public mutating func resume() { mode = .following }
    public mutating func reset() { self = Self() }
}
