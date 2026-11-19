import Foundation
import GRDB

/// A topic incarnation, not just its public ID. Delayed downloads cannot recreate
/// a deleted topic's copies, even if a sync or restore later reuses the same ID.
public struct TopicMediaScope: Sendable, Equatable {
    public let store: ChatStore
    public let topicID: String
    public let token: String
    public let imageSizes: [String:CGSize]
    public static func == (l:Self,r:Self) -> Bool { l.store === r.store && l.token == r.token }
}

public struct TopicResource: Sendable {
    public let data: Data
    public let mime: String
    public let width: Int
    public let height: Int
    public init(data:Data, mime:String, width:Int = 0, height:Int = 0) {
        self.data=data; self.mime=mime; self.width=width; self.height=height
    }
}

extension ChatStore {
    static func installTopicMedia(_ db:Database) throws {
        try db.execute(sql: """
            CREATE TABLE topicMediaOwners (
              topicID TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL DEFAULT 'topic' CHECK(kind='topic'),
              token TEXT NOT NULL UNIQUE, FOREIGN KEY(kind,topicID) REFERENCES library(kind,id) ON DELETE CASCADE
            );
            CREATE TABLE topicMediaObjects (
              resourceKey TEXT PRIMARY KEY NOT NULL, data BLOB NOT NULL, mime TEXT NOT NULL,
              width INTEGER NOT NULL, height INTEGER NOT NULL
            );
            CREATE TABLE topicMediaLinks (
              owner TEXT NOT NULL REFERENCES topicMediaOwners(token) ON DELETE CASCADE,
              resourceKey TEXT NOT NULL REFERENCES topicMediaObjects(resourceKey),
              PRIMARY KEY(owner, resourceKey)
            );
            CREATE INDEX topicMediaLinks_byResource ON topicMediaLinks(resourceKey);
            CREATE TRIGGER pruneUnownedTopicMedia AFTER DELETE ON topicMediaLinks BEGIN
              DELETE FROM topicMediaObjects WHERE resourceKey=OLD.resourceKey AND NOT EXISTS
                (SELECT 1 FROM topicMediaLinks WHERE resourceKey=OLD.resourceKey);
            END;
            """)
    }

    public func topicMediaScope(_ topicID:String) async throws -> TopicMediaScope {
        let (token,sizes): (String,[String:CGSize]) = try await pool.write { db in
            try db.execute(sql:"INSERT INTO topicMediaOwners(topicID,token) VALUES(?,?) ON CONFLICT(topicID) DO NOTHING",
                           arguments:[topicID,UUID().uuidString])
            guard let token=try String.fetchOne(db,sql:"SELECT token FROM topicMediaOwners WHERE topicID=?",arguments:[topicID]) else { throw ClientError.invalidResponse }
            var sizes: [String:CGSize]=[:]
            for r in try Row.fetchAll(db,sql:"SELECT o.resourceKey,o.width,o.height FROM topicMediaObjects o JOIN topicMediaLinks l USING(resourceKey) WHERE l.owner=? AND o.width>0 AND o.height>0",arguments:[token]) {
                let key:String=r["resourceKey"], w:Double=r["width"], h:Double=r["height"]
                sizes[key]=CGSize(width:w,height:h)
            }
            return (token,sizes)
        }
        return TopicMediaScope(store:self,topicID:topicID,token:token,imageSizes:sizes)
    }
    private static func checkOwner(_ db:Database,_ token:String) throws {
        guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM topicMediaOwners WHERE token=?)",arguments:[token]) == true else { throw CancellationError() }
    }

    /// Claiming a known object and testing the owner's lifetime are in one transaction.
    public func localResource(key:String,owner:String) async throws -> TopicResource? {
        try await pool.write { db in
            try Self.checkOwner(db,owner)
            guard let r=try Row.fetchOne(db,sql:"SELECT data,mime,width,height FROM topicMediaObjects WHERE resourceKey=?",arguments:[key]) else { return nil }
            try db.execute(sql:"INSERT OR IGNORE INTO topicMediaLinks(owner,resourceKey) VALUES(?,?)",arguments:[owner,key])
            return TopicResource(data:r["data"],mime:r["mime"],width:r["width"],height:r["height"])
        }
    }
    public func saveLocalResource(_ value:TopicResource,key:String,owner:String) async throws {
        try await pool.write { db in
            try Self.checkOwner(db,owner)
            try db.execute(sql:"INSERT OR IGNORE INTO topicMediaObjects(resourceKey,data,mime,width,height) VALUES(?,?,?,?,?)",arguments:[key,value.data,value.mime,value.width,value.height])
            try db.execute(sql:"INSERT OR IGNORE INTO topicMediaLinks(owner,resourceKey) VALUES(?,?)",arguments:[owner,key])
        }
    }
    public func localResourceCount() async throws -> Int {
        try await pool.read { try Int.fetchOne($0,sql:"SELECT count(*) FROM topicMediaObjects") ?? 0 }
    }
    public func clearLocalResources() async throws {
        try await pool.write { db in
            // Rotate leases, so work already in flight cannot undo the user's action.
            try db.execute(sql:"DELETE FROM topicMediaOwners")
        }
    }
}
