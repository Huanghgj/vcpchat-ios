import SwiftUI
import VChatCore

private struct TopicOwnerKey: EnvironmentKey { static let defaultValue:TopicMediaScope? = nil }
private struct LayoutMemoryKey: EnvironmentKey { static let defaultValue:TranscriptLayoutMemory? = nil }
private struct RenderMessageKey: EnvironmentKey { static let defaultValue = "" }
public extension EnvironmentValues {
    var topicMediaOwner:TopicMediaScope? { get { self[TopicOwnerKey.self] } set { self[TopicOwnerKey.self]=newValue } }
    var messageLayoutMemory:TranscriptLayoutMemory? { get { self[LayoutMemoryKey.self] } set { self[LayoutMemoryKey.self]=newValue } }
    var renderedMessageID:String { get { self[RenderMessageKey.self] } set { self[RenderMessageKey.self]=newValue } }
}

/// Numeric layout hints owned by the chat room, not by a recycled List row.
/// Width and presentation settings are part of the key; an old width is never replayed after rotation.
@MainActor public final class TranscriptLayoutMemory {
    let finishedReplies = NSCache<NSString,FinishedReply>()
    private let heights = NSCache<NSString,NSNumber>()
    private let images = NSCache<NSString,NSValue>()
    public init() { heights.countLimit=512; images.countLimit=1024; finishedReplies.countLimit=24; finishedReplies.totalCostLimit=3*1024*1024 }
    public func clear() { finishedReplies.removeAllObjects(); heights.removeAllObjects(); images.removeAllObjects() }
    private func key(_ id:String,_ source:String,_ width:CGFloat,_ variant:String) -> NSString {
        "\(id):\(source.hashValue):\(Int(width.rounded())):\(variant)" as NSString
    }
    public func islandHeight(messageID:String,source:String,width:CGFloat,variant:String) -> CGFloat? {
        guard width>0,width.isFinite else { return nil }
        return heights.object(forKey:key(messageID,source,width,variant)).map { CGFloat($0.doubleValue) }
    }
    public func rememberIslandHeight(_ height:CGFloat,messageID:String,source:String,width:CGFloat,variant:String) {
        guard height.isFinite,height>0,width.isFinite,width>0 else { return }
        heights.setObject(NSNumber(value:Double(height)),forKey:key(messageID,source,width,variant))
    }
    func imageSize(_ id:String,_ source:String) -> CGSize? {
        guard let v=images.object(forKey:key(id,source,1,"image")) else { return nil }
        #if os(iOS)
        return v.cgSizeValue
        #else
        return v.sizeValue
        #endif
    }
    func rememberImage(_ size:CGSize,_ id:String,_ source:String) {
        #if os(iOS)
        let v=NSValue(cgSize:size)
        #else
        let v=NSValue(size:size)
        #endif
        images.setObject(v,forKey:key(id,source,1,"image"))
    }
}
