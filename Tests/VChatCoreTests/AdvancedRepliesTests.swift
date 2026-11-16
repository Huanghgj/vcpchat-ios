import Foundation
import Testing
@testable import VChatCore

struct AdvancedRepliesTests {
    private let agent = VCPAgent(id: "shared-id",name: "Test Assistant",systemPrompt: "PERSONA")
    private let configuration = ConnectionConfiguration(model: "fixture")
    private let topicID = "topic"
    private var history: [StoredMessage] {
        [
            StoredMessage(id: "old",topicID: topicID,role: "user",content: "old question",createdAt: 1),
            StoredMessage(id: "answer",topicID: topicID,role: "assistant",content: "earlier response",createdAt: 2),
            StoredMessage(id: "current",topicID: topicID,role: "user",content: "new question",createdAt: 3,
                          attachments: [ChatAttachment(id: "image",name: "fixture.png",mime: "image/png",kind: "image",
                                                       dataUrl: "data:image/png;base64,iVBORw0KGgo=")]),
            StoredMessage(id: "next",topicID: topicID,role: "assistant",content: "group member response",createdAt: 4)
        ]
    }

    private func request(_ settings: AdvancedReplyConfiguration?,group: VCPGroup? = nil,output: OutputPreferences = .init(),
                         messages: [StoredMessage]? = nil,currentID: String? = "current",continuation: String? = nil,
                         locationPolicy: String? = nil) async throws -> ChatRequest {
        try await ConversationBuilder().request(configuration: configuration,apiKey: "fixture",
            profile: UserProfile(),agent: agent,group: group,messages: messages ?? history,output: output,
            locationPolicy: locationPolicy,advancedReplies: settings,currentUserMessageID: currentID,transientUserPrompt: continuation)
    }

    @Test func bundledPresetsPreserveOptInAndLegacyRequest() async throws {
        let fresh = try AdvancedReplyConfiguration.seeded(legacy: .init())
        #expect(fresh.rules.count == 9)
        #expect(fresh.rules.allSatisfy { $0.isBuiltin && !$0.enabled })
        #expect(fresh.rules.contains { $0.content.contains("{{VarDivRender}}") })
        #expect(fresh.rules.contains { $0.content.contains("Loom") })
        #expect(fresh.rules.contains { $0.content.contains("Scriptorium") })
        let unchanged = try await request(nil)
        let newInstall = try await request(fresh)
        #expect(newInstall.messages == unchanged.messages)

        var old = OutputPreferences()
        old.animatedBubbles = true
        var migrated = try AdvancedReplyConfiguration.seeded(legacy: old)
        #expect(migrated.animatedBubbles)
        let previous = try await request(nil,output: old,locationPolicy: "location fixture")
        let updated = try await request(migrated,locationPolicy: "location fixture")
        #expect(updated.messages == previous.messages)
        #expect(updated.messages[0].content.components(separatedBy: "{{VarDivRender}}").count == 2)
        migrated.animatedBubbles = false
        #expect(migrated.rules.allSatisfy { !$0.enabled })
    }

    @Test func buildsExactMessageRolesOrderWrappingAndImagePayload() async throws {
        var settings = AdvancedReplyConfiguration(rules: [
            .init(name: "B",content: "SYSTEM B",wrap: false),
            .init(name: "A",content: "SYSTEM A"),
            .init(name: "user",type: .userSuffix,content: "CURRENT ONLY",wrap: false),
            .init(name: "gap B",type: .context,content: "GAP B",wrap: false,role: .assistant,depth: 1),
            .init(name: "gap A",type: .context,content: "GAP A",wrap: false,role: .user,depth: 1),
            .init(name: "tail",type: .context,content: "TAIL",wrap: false),
            .init(name: "empty",content: " \n",wrap: false)
        ])
        let built = try await request(settings)
        #expect(built.messages.map(\.role) == ["system","user","assistant","user","assistant","user","assistant","user"])
        #expect(built.messages.map(\.content) == [
            "PERSONA\n\nSYSTEM B\n\n[本信息由VCPChat客户端注入]\nSYSTEM A\n[临时注入结束]",
            "old question","earlier response","new question\n\nCURRENT ONLY","GAP B","GAP A","group member response","TAIL"
        ])
        let sent = try JSONDecoder().decode([ChatTurn].self,from: JSONEncoder().encode(built.messages))
        #expect(sent == built.messages)
        #expect(sent[3].parts?.map(\.type) == ["text","image_url"])
        #expect(sent[3].parts?.first?.text == "new question\n\nCURRENT ONLY")
        settings.rules.swapAt(0,1)
        settings.rules.swapAt(3,4)
        let reordered = try await request(settings)
        #expect(reordered.messages[0].content.hasSuffix("[临时注入结束]\n\nSYSTEM B"))
        #expect(reordered.messages[4].content == "GAP A")
        #expect(reordered.messages[5].content == "GAP B")
    }

    @Test func agentAndGroupOverridesAreIndependentAndRespectScope() async throws {
        let agentOwner = ReplyRuleOwner(.agent,id: agent.id)
        let groupOwner = ReplyRuleOwner(.group,id: agent.id)
        let group = VCPGroup(id: agent.id,name: "Test Group",memberIds: [agent.id])
        var settings = AdvancedReplyConfiguration(rules: [
            .init(id: "inherited",content: "GLOBAL",wrap: false),
            .init(id: "selective",enabled: false,content: "GROUP OVERRIDE",wrap: false),
            .init(id: "single",content: "SINGLE ONLY",scope: .agent,wrap: false),
            .init(id: "group",content: "GROUP ONLY",scope: .group,wrap: false)
        ])
        settings.setOverride(false,for: "inherited",owner: agentOwner)
        settings.setOverride(true,for: "selective",owner: groupOwner)
        settings.setOverride(true,for: "single",owner: groupOwner)
        #expect(settings.override(for: "single",owner: groupOwner) == nil)
        let singleRequest = try await request(settings)
        let groupRequest = try await request(settings,group: group)
        #expect(singleRequest.messages.first?.content == "PERSONA\n\nSINGLE ONLY")
        #expect(groupRequest.messages.first?.content.hasSuffix("PERSONA\n\nGLOBAL\n\nGROUP OVERRIDE\n\nGROUP ONLY") == true)
        settings.setOverride(nil,for: "inherited",owner: agentOwner)
        let restored = try await request(settings)
        #expect(restored.messages.first?.content == "PERSONA\n\nGLOBAL\n\nSINGLE ONLY")
    }

    @Test func continuationIsRequestOnlyAndDeepRulesDoNotCrossSystem() async throws {
        let settings = AdvancedReplyConfiguration(rules: [
            .init(type: .context,content: "DEEP A",wrap: false,depth: 100),
            .init(type: .context,content: "DEEP B",wrap: false,depth: 100),
            .init(type: .userSuffix,content: "suffix",wrap: false),
            .init(type: .context,content: "END",wrap: false,depth: 0)
        ])
        let built = try await request(settings,messages: Array(history.prefix(2)),currentID: "old",continuation: "continue")
        #expect(built.messages.map(\.content) == [
            "PERSONA","DEEP A","DEEP B","old question","earlier response","continue\n\nsuffix","END"
        ])
        let noCurrentUser = try await request(settings,messages: Array(history.prefix(2)),currentID: nil)
        #expect(!noCurrentUser.messages.contains { $0.content.contains("suffix") })
    }

    @Test func persistsOrderAndOverridesWithoutChangingStoredHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AdvancedRepliesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("fixture.sqlite").path
        let store = try await ChatStore.open(path: path)
        for message in history { try await store.save(message) }
        let old = try await store.messages(topicID: topicID)
        var settings = AdvancedReplyConfiguration(rules: [
            .init(id: "first",type: .userSuffix,content: "transient",wrap: false),
            .init(id: "second",content: "request only",wrap: false)
        ])
        let owner = ReplyRuleOwner(.agent,id: agent.id)
        settings.rules.swapAt(0,1)
        settings.setOverride(false,for: "second",owner: owner)
        try await store.put(settings,kind: "advanced-replies",id: "rules")

        let reopened = try await ChatStore.open(path: path)
        let records = try await reopened.records(AdvancedReplyConfiguration.self,kind: "advanced-replies")
        let readBack = try #require(records.first)
        #expect(readBack == settings)
        #expect(readBack.rules.map(\.id) == ["second","first"])
        #expect(readBack.override(for: "second",owner: owner) == false)
        let built = try await request(readBack,messages: old)
        #expect(built.messages[3].content == "new question\n\ntransient")
        #expect(built.messages.first?.content == "PERSONA")
        let historyAfter = try await reopened.messages(topicID: topicID)
        #expect(historyAfter == old)
    }
}
