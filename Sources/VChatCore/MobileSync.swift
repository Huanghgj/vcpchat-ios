import Foundation
import ImageIO
import UniformTypeIdentifiers
public enum MobileSyncMode: String, Sendable { case pull,both }
public struct MobileSyncResult: Sendable { public var profile: SyncProfile; public var after: SyncSnapshot; public var attachmentWarnings: Int }
/// The entire sync state machine and canonicalization live off MainActor.
public actor MobileSync {
    private var running = false
    public init() {}
    public func run(settings: MobileSyncSettings,token: String,mode: MobileSyncMode,profile original: SyncProfile,local: SyncSnapshot,versions: [String:Double] = [:],progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> MobileSyncResult {
        guard !running else { throw SyncWire.fail("同步正在进行") }; running = true
        do {
            guard !token.isEmpty else { throw SyncWire.fail("请填写桌面同步 Token") }
            let endpoint = try MobileSyncSettings.endpoint(settings.httpURL); guard endpoint.absoluteString == original.endpoint else { throw SyncWire.fail("同步来源已改变") }
            var baseline = original
            baseline.adaptGroupDTOsToWire16()
            var p = baseline; try p.overlay(local,versions: versions)
            if mode == .pull,p != baseline { throw SyncWire.fail("此同步来源在本机有改动，请选双向同步；本次未覆盖内容") }
            let channel = SyncChannel(); await channel.open(try MobileSyncSettings.socket(settings.socketURL,token: token))
            let http = SyncHTTP(endpoint: endpoint,token: token)
            do {
                await progress("正在核对同步协议…")
                try await negotiate(channel)
                await progress("正在同步联系人与群组…"); p = try await metadata("owner",profile: p,channel: channel,http: http,mode: mode)
                await progress("正在同步头像…"); p = try await avatars(profile: p,channel: channel,http: http,mode: mode)
                try await channel.send(.object(["type":.string("PHASE_COMPLETED"),"phase":.string("owner_metadata")]))
                await progress("正在同步会话列表…"); p = try await metadata("topic",profile: p,channel: channel,http: http,mode: mode)
                try await channel.send(.object(["type":.string("PHASE_START"),"phase":.string("messages")]))
                let topics = p.entities.values.filter { $0.identity.entityType == "topic" && $0.deletedAt == nil && p.entities[$0.identity.owner.key]?.deletedAt == nil && p.entities[$0.identity.owner.key] != nil }.sorted { $0.identity.key < $1.identity.key }
                let changed = try await changedTopics(topics,channel: channel)
                // Matching live roots do not rule out a local tombstone still owed to the peer.
                let toSync = topics.filter { changed.contains($0.identity) || !(p.messageDeletes[$0.identity.topicKey] ?? [:]).isEmpty }
                var warningCount = 0
                for (index,e) in toSync.enumerated() {
                    try Task.checkCancellation()
                    await progress("正在同步消息 \(index+1)/\(toSync.count)…")
                    let (messages,deletions,warnings) = try await syncMessages(
                        e, messages: p.messages[e.identity.topicKey] ?? [],
                        deletions: p.messageDeletes[e.identity.topicKey] ?? [:],
                        channel: channel,http: http,mode: mode
                    )
                    p.messages[e.identity.topicKey] = messages
                    p.messageDeletes[e.identity.topicKey] = deletions
                    warningCount += warnings
                }
                let session = SyncWire.now,nonce = UUID().uuidString
                let ack = try await channel.request(.object(["type":.string("PHASE_COMPLETED"),"phase":.string("messages"),"sessionId":.number(session),"attemptId":.number(1),"nonce":.string(nonce)]),expected: "PHASE_ACK")
                guard ack["phase"].text == "messages",ack["sessionId"].number == session,ack["attemptId"].number == 1,ack["nonce"].text == nonce else { throw SyncWire.fail("同步最终确认不匹配，未写入本机") }
                try Task.checkCancellation(); p.refreshRoots(); p.lastSync = SyncWire.now; let result = MobileSyncResult(profile: p,after: p.toLocal(extras: local),attachmentWarnings: warningCount)
                await channel.close(); running = false; return result
            } catch { await channel.close(); throw error }
        } catch { running = false; throw error }
    }
    private func negotiate(_ channel: SyncChannel) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let reply = try await channel.request(.object(["type":.string("VERSION_CHECK"),"versions":.array([
            .object(["component":.string("mobile_app"),"version":.string(version)]),
            .object(["component":.string("wire"),"version":.string(SyncWire.version)])
        ])]),expected: "VERSION_ACK")
        let versions = try SyncWire.rows(reply["versions"])
        guard versions.count == 2,versions.allSatisfy({ Set($0.object.keys) == ["component","version"] }),
              versions.contains(where: { $0["component"] == .string("wire") && $0["version"] == .string(SyncWire.version) }),
              versions.contains(where: { row in
                  guard row["component"] == .string("desktop_plugin"),case .string(let v) = row["version"] else { return false }
                  return !v.isEmpty
              }),
              ["cds","legacy"].contains(reply["backendMode"].text) else {
            throw SyncWire.fail("桌面同步协议不兼容，需要 Wire " + SyncWire.version)
        }
    }

    private func changedTopics(_ topics: [SyncEntity],channel: SyncChannel) async throws -> Set<SyncIdentity> {
        var changed = Set<SyncIdentity>()
        for offset in stride(from: 0,to: topics.count,by: 100) {
            let batch = topics[offset..<min(offset+100,topics.count)]
            let requested = Set(batch.map(\.identity))
            let values: [JSONValue] = batch.map { e in
                var row = e.identity.json
                row.removeValue(forKey: "entityType")
                row["configHash"] = .string(e.configHash); row["contentHash"] = .string(e.contentHash)
                return .object(row)
            }
            let reply = try await channel.request(.object(["type":.string("SYNC_TOPIC_DIFF_REQUEST"),"topics":.array(values)]),expected: "SYNC_TOPIC_DIFF_RESULT")
            for row in try SyncWire.rows(reply["changedTopics"]) {
                let id = try SyncIdentity(row,kind: "topic")
                guard Set(row.object.keys) == ["ownerType","ownerId","topicId"],requested.contains(id),changed.insert(id).inserted else {
                    throw SyncWire.fail("话题差分身份无效或重复")
                }
            }
        }
        return changed
    }

    private func syncMessages(_ entity: SyncEntity,messages: [JSONValue],deletions: [String:Double],
                              channel: SyncChannel,http: SyncHTTP,mode: MobileSyncMode) async throws
        -> ([JSONValue],[String:Double],Int) {
        let id = entity.identity
        guard let topicID = id.topicId else { throw SyncWire.fail("同步话题身份不完整") }
        var live: [String:JSONValue] = [:],manifest: [String:JSONValue] = [:]
        for message in messages {
            let mid = message["id"].text
            guard !mid.isEmpty,live.updateValue(message,forKey: mid) == nil,deletions[mid] == nil else { throw SyncWire.fail("本机消息身份重复") }
            manifest[mid] = .object(["messageHash":message["contentHash"],"updatedAt":message["updatedAt"]])
        }
        for (mid,at) in deletions { manifest[mid] = .object(["deletedAt":.number(at)]) }

        var identity = id.json
        identity.removeValue(forKey: "entityType")
        var request = identity
        request["contentHash"] = .string(entity.contentHash); request["messages"] = .object(manifest)
        let response = try await channel.request(.object(["type":.string("SYNC_MESSAGE_DIFF_REQUEST"),"topics":.array([.object(request)])]),expected: "SYNC_MESSAGE_DIFF_RESULT")
        let results = try SyncWire.rows(response["results"])
        guard results.count == 1 else { throw SyncWire.fail("话题缺少唯一的消息差分") }
        let plan = try SyncMessagePlan(results[0],topic: id,live: live,deleted: deletions)
        let needsPush = !plan.push.isEmpty || !plan.pushDeleted.isEmpty
        guard mode == .both || !needsPush else { throw SyncWire.fail("此会话有待写回消息，请使用双向同步；本机内容已保留") }

        var tombstones = deletions,warnings = 0
        if plan.pullAll || !plan.pull.isEmpty {
            var selector = identity
            selector["messageIds"] = .array(plan.pull.sorted().map(JSONValue.string))
            let raw = try await http.topicFrame("/messages/pull",.object(["topics":.array([.object(selector)])]))
            guard try SyncIdentity(raw,kind: "topic") == id else { throw SyncWire.fail("消息返回身份不符") }
            if raw["legacyAttachmentWarnings"] != .null { warnings = Int(try SyncWire.integer(raw["legacyAttachmentWarnings"])) }
            if raw["warningSamples"] != .null {
                guard case .array(let samples) = raw["warningSamples"],
                      samples.allSatisfy({ if case .string = $0 { true } else { false } }) else { throw SyncWire.fail("附件告警列表无效") }
            }
            var seen = Set<String>()
            for row in try SyncWire.rows(raw["messages"]) {
                guard row["topicId"] == .null || row["topicId"] == .string(topicID) else { throw SyncWire.fail("消息返回话题错误") }
                var message = try SyncWire.message(row,topic: topicID,warnings: &warnings).object
                let mid = row["id"].text
                guard seen.insert(mid).inserted,plan.pullAll || plan.pull.contains(mid),
                      row["contentHash"] == .string(SyncWire.fingerprint(.object(message))) else { throw SyncWire.fail("消息指纹或身份校验失败") }
                message["updatedAt"] = .number(try SyncWire.time(row["updatedAt"]))
                message["contentHash"] = row["contentHash"]
                message["localId"] = live[mid]?.object["localId"]
                live[mid] = .object(message)
            }
            guard plan.pullAll || seen == plan.pull else { throw SyncWire.fail("消息返回不完整") }
        }
        for (mid,at) in plan.delete {
            live.removeValue(forKey: mid)
            tombstones[mid] = at
        }

        if needsPush {
            var frame = identity
            frame["kind"] = .string("topic")
            frame["messages"] = .array(try plan.push.sorted().map { mid in
                guard var body = live[mid]?.object else { throw SyncWire.fail("拟写回的消息缺失，未上传") }
                body.removeValue(forKey: "localId")
                return .object(body)
            })
            frame["deletedMessages"] = .array(plan.pushDeleted.sorted(by: { $0.key < $1.key }).map { mid,at in
                .object(["msgId":.string(mid),"deletedAt":.number(at)])
            })
            var data = try JSONEncoder().encode(JSONValue.object(frame)); data.append(10)
            let ack = try await http.topicFrame("/messages/push",data: data)
            guard try SyncIdentity(ack,kind: "topic") == id else { throw SyncWire.fail("消息写回未确认") }
        }
        let ordered = live.values.sorted { ($0["timestamp"].number ?? 0,$0["id"].text) < ($1["timestamp"].number ?? 0,$1["id"].text) }
        return (ordered,tombstones,warnings)
    }

    private func metadata(_ kind: String,profile: SyncProfile,channel: SyncChannel,http: SyncHTTP,mode: MobileSyncMode) async throws -> SyncProfile {
        var p = profile; let phase = kind == "owner" ? "owner_metadata" : "topic_metadata"
        try await channel.send(.object(["type":.string("PHASE_START"),"phase":.string(phase)]))
        let owners = p.entities.values.filter { $0.identity.entityType == "owner" && $0.deletedAt == nil }.map(\.identity)
        let items = p.entities.values.filter { $0.identity.entityType == kind && (kind == "owner" || owners.contains($0.identity.owner)) }.sorted { $0.identity.key < $1.identity.key }.map(\.manifest)
        var manifest: [String:JSONValue] = ["type":.string("SYNC_MANIFEST_REQUEST"),"manifestType":.string(kind),"items":.array(items)]
        if kind == "topic" { manifest["targetedOwners"] = .array(owners.map { .object(["ownerType":.string($0.ownerType),"ownerId":.string($0.ownerId)]) }) }
        let response = try await channel.request(.object(manifest),expected: "SYNC_MANIFEST_RESULT"); guard response["manifestType"].text == kind else { throw SyncWire.fail("同步清单类型不符") }
        var seen = Set<String>(),pulls: [SyncIdentity] = [],pushes: [SyncEntity] = []
        for action in try SyncWire.rows(response["results"]) {
            let id = try SyncIdentity(action,kind: kind); guard seen.insert(id.key).inserted,kind != "topic" || owners.contains(id.owner) else { throw SyncWire.fail("同步清单重复或超出来源范围") }; let e = p.entities[id.key]
            switch action["action"].text {
            case "PULL": pulls.append(id)
            case "PUSH": guard mode == .both,let e,e.deletedAt == nil else { throw SyncWire.fail("桌面缺少本机项，请使用双向同步；本机内容已保留") }; pushes.append(e)
            case "PULL_DELETE": let at = try SyncWire.time(action["deletedAt"]); p.entities[id.key]?.deletedAt = at
            case "PUSH_DELETE": guard mode == .both,let at = e?.deletedAt else { throw SyncWire.fail("删除写回需要双向同步及本机删除记录") }; var v = id.json; v.removeValue(forKey: "entityType"); v["type"] = .string("SYNC_ENTITY_DELETE"); v["targetType"] = .string(kind); v["deletedAt"] = .number(at); try await channel.send(.object(v))
            case "SKIP": break
            default: throw SyncWire.fail("桌面返回未知同步动作")
            }
        }
        for offset in stride(from: 0,to: pulls.count,by: 40) {
            let wanted = Array(pulls[offset..<min(offset+40,pulls.count)]); let result = try await http.json("/entities/pull",.object(["items":.array(wanted.map { .object($0.json) })]))
            let rows = try SyncWire.rows(result["results"]); var remaining = Set(wanted)
            guard rows.count == wanted.count else { throw SyncWire.fail("实体拉取不完整") }
            for row in rows {
                let id = try SyncIdentity(row,kind: kind); guard remaining.remove(id) != nil,row["ok"].bool == true else { throw SyncWire.fail("实体返回身份重复、越界或未成功") }
                _ = try SyncWire.object(row["data"]); var e = SyncEntity(identity: id,data: row["data"],updatedAt: (try? SyncWire.time(row["data"]["updatedAt"])) ?? 0)
                e.localId = p.entities[id.key]?.localId; e.contentHash = p.entities[id.key]?.contentHash ?? ""
                if kind == "topic" { guard row["data"]["configHash"].text == e.configHash else { throw SyncWire.fail("会话版本校验失败，未写入") }; e.updatedAt = try SyncWire.time(row["data"]["updatedAt"]) }
                p.entities[id.key] = e
            }
        }
        for e in pushes {
            var data = e.data.object; if kind == "topic" { data["configHash"] = .string(e.configHash); data["updatedAt"] = .number(e.updatedAt) }
            var item = e.identity.json; item["data"] = .object(data)
            let reply = try await http.json("/entities/push",.object(["items":.array([.object(item)])])); let rows = try SyncWire.rows(reply["results"])
            guard rows.count == 1,rows[0]["ok"].bool == true,try SyncIdentity(rows[0],kind: kind) == e.identity else { throw SyncWire.fail("实体写回未确认") }
        }
        if kind == "topic" { try await channel.send(.object(["type":.string("PHASE_COMPLETED"),"phase":.string(phase)])) }; return p
    }
    private func avatars(profile: SyncProfile,channel: SyncChannel,http: SyncHTTP,mode: MobileSyncMode) async throws -> SyncProfile {
        var p = profile
        let items = p.avatars.values.map { value -> JSONValue in var v = value.object; v.removeValue(forKey: "image"); if v["deletedAt"] != nil { v.removeValue(forKey: "binaryHash"); v.removeValue(forKey: "updatedAt") }; return .object(v) }
        let reply = try await channel.request(.object(["type":.string("SYNC_MANIFEST_REQUEST"),"manifestType":.string("avatar"),"items":.array(items)]),expected: "SYNC_MANIFEST_RESULT")
        guard reply["manifestType"].text == "avatar" else { throw SyncWire.fail("头像清单类型不符") }; var seen = Set<String>()
        for action in try SyncWire.rows(reply["results"]) {
            let type = action["ownerType"].text,id = action["ownerId"].text,key = type + "\0" + id
            guard ["agent","group","user"].contains(type),!id.isEmpty,type != "user" || id == "user_avatar",seen.insert(key).inserted else { throw SyncWire.fail("头像身份重复或无效") }
            var c = URLComponents(); c.queryItems = [URLQueryItem(name: "ownerType",value: type),URLQueryItem(name: "ownerId",value: id)]
            let path = "/avatars/" + (action["action"].text == "PUSH" ? "push" : "pull") + "?" + c.percentEncodedQuery!
            switch action["action"].text {
            case "PULL":
                let reply = try await http.binary(path); guard let source = CGImageSourceCreateWithData(reply.data as CFData,nil),CGImageSourceGetCount(source) > 0,let identifier = CGImageSourceGetType(source),let mime = UTType(identifier as String)?.preferredMIMEType else { throw SyncWire.fail("同步头像不是可识别图片") }
                p.avatars[key] = .object(["ownerType":.string(type),"ownerId":.string(id),"binaryHash":.string(SyncWire.sha(reply.data)),"updatedAt":.number(0),"image":.string("data:\(mime);base64," + reply.data.base64EncodedString())])
            case "PUSH":
                guard mode == .both,let image = p.avatars[key]?["image"].text,let comma = image.firstIndex(of: ","),let bytes = Data(base64Encoded: String(image[image.index(after: comma)...])),bytes.count <= 20_000_000 else { throw SyncWire.fail("头像需要双向同步写回") }
                let mime = String(image.prefix(while: { $0 != ";" }).dropFirst(5)); let ack = try StrictJSON.decode(await http.binary(path,data: bytes,mime: mime).data)
                guard ack["ok"].bool == true,ack["ownerType"].text == type,ack["ownerId"].text == id else { throw SyncWire.fail("头像写回未确认") }
            case "PULL_DELETE": let at = try SyncWire.time(action["deletedAt"]); if var v = p.avatars[key]?.object { v["deletedAt"] = .number(at); v.removeValue(forKey: "image"); p.avatars[key] = .object(v) }
            case "PUSH_DELETE": guard mode == .both,let old = p.avatars[key] else { throw SyncWire.fail("头像删除需要双向同步") }; let at = try SyncWire.time(old["deletedAt"]); try await channel.send(.object(["type":.string("SYNC_ENTITY_DELETE"),"targetType":.string("avatar"),"ownerType":.string(type),"ownerId":.string(id),"deletedAt":.number(at)]))
            case "SKIP": break
            default: throw SyncWire.fail("头像同步动作无效")
            }
        }; return p
    }
}
