import SwiftUI
import UIKit
import WebKit
import XCTest
import SQLite3
@testable import VChatCore
@testable import VChatRendering
@testable import VChat

final class PhoneInteractionTests: XCTestCase {
    @MainActor private func host<V: View>(_ content: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    @MainActor private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let found = root as? T { return found }
        for child in root.subviews {
            if let found = find(type, in: child) { return found }
        }
        return nil
    }

    @MainActor private func eventually(_ description: String, file: StaticString = #filePath, line: UInt = #line, _ check: @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        while clock.now < deadline {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTFail("Timed out: " + description, file: file, line: line)
    }

    @MainActor private func makeMediaDatabase() async throws -> (URL, ChatStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try await ChatStore.open(path: root.appendingPathComponent("chat.sqlite").path))
    }

    @MainActor private func addMediaTopic(_ db: ChatStore, ownerID: String = "fixture") async throws -> ChatTopic {
        let topic = ChatTopic(ownerId: ownerID)
        try await db.put(topic, kind: "topic", id: topic.id)
        return topic
    }

    @MainActor func testTopicMediaSurvivesColdReopenAndDeletesOnlyLastReference() async throws {
        let (root, db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await addMediaTopic(db)
        let second = try await addMediaTopic(db)
        let a = try await db.topicMediaScope(first.id)
        let b = try await db.topicMediaScope(second.id)
        let link = try XCTUnwrap(URL(string:"https://fixtures.invalid/artwork/offline.png"))
        let bytes = pixelPNG(.red)
        let network = ImageOriginFixture()
        await network.set(link,bytes,control:"public, max-age=0")
        let cache = root.appendingPathComponent("evictable", isDirectory:true)
        let renderer = RemoteImageStore(directory:cache) { try await network.get($0) }
        let fetched = try await renderer.resource(link,owner:a)
        XCTAssertEqual(fetched.data,bytes)
        let shared = try await renderer.resource(link,owner:b)
        XCTAssertEqual(shared.data,bytes)
        let unique = try await db.localResourceCount()
        XCTAssertEqual(unique,1,"Two topic owners of the same URL share a single stored original")
        try await db.removeTopic(first.id)
        let afterFirst = try await db.localResourceCount()
        XCTAssertEqual(afterFirst,1)
        // A new DB/loader with a different cache directory cannot use the first
        // loader's in-memory or HTTP cache. The origin below is permanently offline.
        let reopened = try await ChatStore.open(path:root.appendingPathComponent("chat.sqlite").path)
        let offline = ImageOriginFixture()
        let reader = RemoteImageStore(directory:root.appendingPathComponent("empty-cache")) { try await offline.get($0) }
        let remainingOwner = try await reopened.topicMediaScope(second.id)
        let read = try await reader.resource(link,owner:remainingOwner)
        XCTAssertEqual(read.data,bytes)
        let offlineCalls = await offline.count(link)
        XCTAssertEqual(offlineCalls,0,"Reopening a saved topic must not issue a network request")
        try await reopened.removeTopic(second.id)
        let none = try await reopened.localResourceCount()
        XCTAssertEqual(none,0)
    }

    @MainActor func testLateDownloadCannotRecreateDeletedTopicOrClaimReusedID() async throws {
        let (root, db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let topic = try await addMediaTopic(db)
        let originalScope = try await db.topicMediaScope(topic.id)
        let link = try XCTUnwrap(URL(string:"https://fixtures.invalid/gallery/delayed.png"))
        let gate = DelayedMediaOrigin(bytes:pixelPNG(.green))
        let renderer = RemoteImageStore(directory:root.appendingPathComponent("cache")) { _ in await gate.fetch() }
        let transfer = Task { try await renderer.resource(link,owner:originalScope) }
        try await eventually("synthetic transfer entered the origin") { await gate.entered }
        try await db.removeTopic(topic.id)
        try await db.put(topic,kind:"topic",id:topic.id)
        _ = try await db.topicMediaScope(topic.id)
        await gate.release()
        do { _ = try await transfer.value; XCTFail("A transfer from the retired topic generation completed") } catch {}
        let orphanCount = try await db.localResourceCount()
        XCTAssertEqual(orphanCount,0,"The replacement topic must not inherit a late write")
    }

    @MainActor func testSyncReplacementRetainsMediaOnlyForSurvivingTopicsAndClearHistoryRemovesIt() async throws {
        let (root,db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = SyncProfile(id:"fixture", endpoint:"https://fixtures.invalid")
        let agent = VCPAgent(id:profile.localID("agent","A"),name:"fixture")
        try await db.put(agent,kind:"agent",id:agent.id)
        let keep = try await addMediaTopic(db,ownerID:agent.id)
        let remove = try await addMediaTopic(db,ownerID:agent.id)
        let keepScope = try await db.topicMediaScope(keep.id), removeScope = try await db.topicMediaScope(remove.id)
        let link = try XCTUnwrap(URL(string:"https://fixtures.invalid/a.png"))
        let second = try XCTUnwrap(URL(string:"https://fixtures.invalid/b.png"))
        let origin = ImageOriginFixture(), a = pixelPNG(.red), b = pixelPNG(.blue)
        await origin.set(link,a); await origin.set(second,b)
        let renderer = RemoteImageStore(directory:root.appendingPathComponent("cache")) { try await origin.get($0) }
        _ = try await renderer.resource(link,owner:keepScope)
        _ = try await renderer.resource(second,owner:removeScope)
        let before = try await db.syncSnapshot().managed(by:profile)
        var after=before
        after.topics.removeAll { $0.id==remove.id }
        try await db.commitSync(profile:profile,previous:profile,before:before,after:after)
        let remaining=try await db.localResourceCount()
        XCTAssertEqual(remaining,1,"A temporary topic-row replacement during sync must preserve the retained owner's asset")
        let offline = ImageOriginFixture()
        let fresh = RemoteImageStore(directory:root.appendingPathComponent("different-cache")) { try await offline.get($0) }
        let kept = try await fresh.resource(link,owner:keepScope)
        XCTAssertEqual(kept.data,a)
        let calls = await offline.count(link); XCTAssertEqual(calls,0)
        _ = try await db.clearHistory(replacement:ChatTopic(ownerId:agent.id))
        let afterClear=try await db.localResourceCount()
        XCTAssertEqual(afterClear,0,"A text history archive does not retain the deleted live topics' resource files")
    }

    func testReadingDoesNotResumeWhenReflowPutsTheBottomNearTheViewport() {
        var follow=TranscriptFollowing()
        XCTAssertTrue(follow.canScrollToLatest)
        follow.beginInteraction()
        follow.markReading()
        XCTAssertFalse(follow.canScrollToLatest)
        follow.endInteraction(atLatest:true)
        XCTAssertFalse(follow.canScrollToLatest, "A shrinking placeholder cannot opt the reader back into following")
        follow.beginInteraction()
        follow.endInteraction(atLatest:false)
        XCTAssertFalse(follow.canScrollToLatest)
        follow.resume()
        XCTAssertTrue(follow.canScrollToLatest)
    }

    func testPreloadWindowFollowsVisibleMessagesInBothDirections() {
        func rows(_ count: Int, _ visible: [Int], _ depth: Int) -> Set<Int> {
            Set(TranscriptPreloadDepth.indices(count: count, visible: visible, depth: depth))
        }
        XCTAssertEqual(TranscriptPreloadDepth.standard, 10)
        XCTAssertEqual(rows(100,[42,43],10), Set(32...53))
        XCTAssertEqual(rows(100,[],10), Set(89...99))
        XCTAssertEqual(rows(100,[0],99), Set(0...20))
        XCTAssertEqual(rows(100,[10,90],1), Set(0...20).union(80...99))
        XCTAssertEqual(rows(100,[20],0), Set(10...30), "Build 16 preferences below ten migrate to ten")
        XCTAssertTrue(rows(0,[],10).isEmpty)
    }

    @MainActor func testNativeChatListPreparesBothSidesAfterJumpingIntoHistory() async throws {
        let model = ChatViewModel(), topic = ChatTopic(ownerId:"fixture")
        let messages = (0..<64).map { index in
            StoredMessage(id:"row-\(index)",topicID:topic.id,role:"assistant",
                          content:"**第 \(index) 条**\n" + String(repeating:"读历史记录。\n",count:5))
        }
        let room = ChatRoom(id:topic.id,messages:messages)
        model.rooms = [topic.id:room]; model.activeTopicID = topic.id; model.topics = [topic]; model.loading = false
        let suite = "vchat-test-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(10,forKey:TranscriptPreloadDepth.key)
        let window = try host(ChatView(model:model).frame(height:560).defaultAppStorage(defaults).environment(\.scenePhase,.active))
        defer { window.isHidden = true }
        try await eventually("native transcript ready at the latest message") {
            guard let list = self.find(UICollectionView.self,in:window) else { return false }
            return list.indexPathsForVisibleItems.contains { $0.item >= 62 }
        }
        let list = try XCTUnwrap(find(UICollectionView.self,in:window))
        let section = try XCTUnwrap((0..<list.numberOfSections).first { list.numberOfItems(inSection:$0) >= 64 })
        list.scrollToItem(at:IndexPath(item:32,section:section),at:.centeredVertically,animated:false)
        try await eventually("messages eight rows beyond both visible edges have already been parsed") {
            let indices = list.indexPathsForVisibleItems.filter { $0.section == section }.map(\.item)
            guard indices.contains(32), let lo = indices.min(), let hi = indices.max() else { return false }
            return [lo - 8,hi + 8].allSatisfy {
                room.layoutMemory.finishedReplies.object(forKey: "row-\($0)" as NSString) != nil
            }
        }
    }

    @MainActor func testUnseenCardIsPreparedAndRecycledRowKeepsItsLiveDocument() async throws {
        let state = NearbyCardFixture()
        let window = try host(NearbyCardViews(state:state))
        defer { window.isHidden = true; state.buffer.clear() }
        let slot = IslandSlot(message:"nearby",index:0)
        try await eventually("WKWebView prepared while its transcript row does not exist") {
            state.buffer.parkedController(at:slot)?.view != nil
        }
        let web = try XCTUnwrap(state.buffer.parkedController(at:slot)?.view)
        XCTAssertTrue(web.superview === state.buffer.parkingView && web.window === window)
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Preloaded card did not finish its initial navigation") }
            try await Task.sleep(for:.milliseconds(150))
        }
        guard try await observeIsland(web, "card DOM exists before creating its row", condition:
            "return !!document.querySelector('#nearby-details');") else { return }
        state.showRow = true
        try await eventually("row adopts preloaded web view") { web.superview !== state.buffer.parkingView && web.window === window }
        _ = try await web.evaluateJavaScript("document.querySelector('details').open = true")
        state.showRow = false
        try await eventually("recycled row handed the live document back") {
            state.buffer.parkedController(at:slot)?.view === web && web.superview === state.buffer.parkingView && web.window === window
        }
        let before = try await web.evaluateJavaScript("Number(document.body.dataset.frames || 0)") as? Int ?? 0
        guard try await observeIsland(web,"animation frames advance after the cell was recycled",condition:
            "return Number(document.body.dataset.frames || 0) >= \(before + 3);") else { return }
        state.showRow = true
        try await eventually("row reattaches the same document") { web.superview !== state.buffer.parkingView && web.window === window }
        let open = try await web.evaluateJavaScript("document.querySelector('details')?.open === true")
        XCTAssertEqual(open as? Bool, true)
        state.showRow = false
        state.enabled = false
        try await eventually("leaving the message window releases offscreen WebKit") {
            state.buffer.parkedController(at:slot) == nil && self.find(WKWebView.self,in:window) == nil
        }
    }

    @MainActor func testTenNeighboursDoNotShareTenSlotsWithTheVisibleMessage() async throws {
        let buffer = TranscriptRenderBuffer()
        let items = (0...10).map { i in
            TranscriptRenderItem(id:"bubble-\(i)",source:"<div id=\"vcp-root\">card \(i)</div>",
                                 role:"assistant",depth:0,rules:[],streaming:false)
        }
        let window = try host(TranscriptPreloader(items:items,options:.init(),buffer:buffer,width:260,memory:TranscriptLayoutMemory())
            .environment(\.scenePhase,.active))
        defer { buffer.clear(); window.isHidden = true }
        try await eventually("all eleven distinct message documents stay attached to the same window") {
            items.allSatisfy { buffer.parkedController(at:.init(message:$0.id,index:0))?.view?.window === window }
        }
    }

    @MainActor func testPreloaderDecodesNearbyTopicImageBeforeRowAppears() async throws {
        let (root, store) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at:root) }
        let topic = try await addMediaTopic(store)
        let owner = try await store.topicMediaScope(topic.id)
        let url = try XCTUnwrap(URL(string:"https://fixtures.invalid/preload/photo.png"))
        let bytes = pixelPNG(.orange)
        let seed = RemoteImageStore(directory:root.appendingPathComponent("seed")) { _ in
            RemoteImageReply(data:bytes,status:200,cacheControl:"public, max-age=86400")
        }
        _ = try await seed.resource(url,owner:owner)
        let buffer = TranscriptRenderBuffer()
        let item = TranscriptRenderItem(id:"photo",source:"![预览](\(url.absoluteString))",role:"assistant",depth:0,rules:[],streaming:false)
        let window = try host(TranscriptPreloader(items:[item],options:.init(),buffer:buffer,width:280,memory:TranscriptLayoutMemory())
            .environment(\.topicMediaOwner,owner).environment(\.scenePhase,.active))
        defer { window.isHidden = true; buffer.clear() }
        try await eventually("photo decoded without displaying a message") {
            buffer.image(message:"photo",source:url.absoluteString,owner:owner,stickers:.init()) != nil
        }
        XCTAssertNil(buffer.image(message:"photo",source:url.absoluteString,owner:nil,stickers:.init()))
    }

    @MainActor func testOffscreenIslandRestoresItsMeasuredHeightAfterCellIdentityChanges() async throws {
        let state = OffscreenIslandFixtureState()
        let window = try host(OffscreenIslandFixture(state:state))
        defer { window.isHidden = true }
        // Wait for actual WebKit layout; a cold simulator may take longer than the
        // general UI helper's 12-second budget. The card is taller than any placeholder.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(65)
        while (state.heights[0] ?? 0) < 400 {
            guard clock.now < deadline else { return XCTFail("The online island never measured its 414pt card: \(state.heights)") }
            try await Task.sleep(for:.milliseconds(150))
        }
        let measured = try XCTUnwrap(state.heights[0])
        state.offscreen = true
        state.incarnation += 1
        // The new view is deliberately outside the viewport: it cannot obtain its
        // old height by loading WebKit again. It must reserve the previous layout.
        try await eventually("offscreen replacement reserves the measured card height") {
            guard let height=state.heights[1] else { return false }
            return abs(height-measured)<2
        }
    }

    @MainActor func testOwnedWebKitImageIsAvailableToNativeReaderAfterProcessRestart() async throws {
        let (root,db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at:root) }
        let topic=try await addMediaTopic(db), url=try XCTUnwrap(URL(string:"https://fixtures.invalid/card/photo.png"))
        let owner=try await db.topicMediaScope(topic.id)
        let origin=ImageOriginFixture(), bytes=pixelPNG(.cyan)
        await origin.set(url,bytes,control:"public, max-age=0")
        let store=RemoteImageStore(directory:root.appendingPathComponent("cache-a")) { try await origin.get($0) }
        try await renderFixtureImage(url,using:store,owner:owner)
        let first=await origin.count(url)
        XCTAssertEqual(first,1)
        let reopened=try await ChatStore.open(path:root.appendingPathComponent("chat.sqlite").path)
        let coldOwner=try await reopened.topicMediaScope(topic.id)
        XCTAssertFalse(coldOwner.imageSizes.isEmpty,"Reserve the decoded dimensions on a cold launch")
        let offline=ImageOriginFixture()
        let reader=RemoteImageStore(directory:root.appendingPathComponent("cache-b")) { try await offline.get($0) }
        let saved=try await reader.resource(url,owner:coldOwner)
        XCTAssertEqual(saved.data,bytes)
        let replay=await offline.count(url)
        XCTAssertEqual(replay,0)
    }

    @MainActor func testTopicArchiveDoesNotPersistNoStoreResponsesOrReuseOtherCredentials() async throws {
        let (root,db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let topic=try await addMediaTopic(db), scope=try await db.topicMediaScope(topic.id)
        let origin=ImageOriginFixture(), pixels=pixelPNG(.orange)
        let store=RemoteImageStore(directory:root.appendingPathComponent("http-cache")) { try await origin.get($0) }
        let forbidden=try XCTUnwrap(URL(string:"https://fixtures.invalid/do-not-store.png"))
        await origin.set(forbidden,pixels,control:"private, no-store")
        let permittedForDisplay=try await store.resource(forbidden,owner:scope)
        XCTAssertEqual(permittedForDisplay.data,pixels)
        let before=try await db.localResourceCount()
        XCTAssertEqual(before,0)
        let good=try XCTUnwrap(URL(string:"https://fixtures.invalid/pw=synthetic-a/images/pic.png?v=1"))
        await origin.set(good,pixels)
        _ = try await store.resource(good,owner:scope)
        let offline=ImageOriginFixture()
        let reopened=RemoteImageStore(directory:root.appendingPathComponent("empty")) { try await offline.get($0) }
        for raw in [forbidden.absoluteString,"https://fixtures.invalid/pw=synthetic-b/images/pic.png?v=1","https://fixtures.invalid/pw=synthetic-a/images/pic.png?v=2"] {
            let u=try XCTUnwrap(URL(string:raw))
            do { _ = try await reopened.resource(u,owner:scope);XCTFail("A different access path or no-store response was persisted") } catch {}
            let attempts=await offline.count(u)
            XCTAssertEqual(attempts,1)
        }
    }

    @MainActor func testTopicVideoReopensAsALocalFileAndReleasesPlaybackFile() async throws {
        let (root,db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at:root) }
        let topic=try await addMediaTopic(db), scope=try await db.topicMediaScope(topic.id)
        // Synthetic ISO BMFF file-type box. This verifies storage and materialization;
        // codec support remains the responsibility of AVPlayer.
        let bytes=Data([0,0,0,20, 0x66,0x74,0x79,0x70, 0x69,0x73,0x6f,0x6d,
                        0,0,2,0, 0x69,0x73,0x6f,0x6d])
        let url=try XCTUnwrap(URL(string:"https://fixtures.invalid/media/movie.mp4"))
        let seed=TopicVideoStore { _ in (bytes,200,"video/mp4","public, max-age=0") }
        let copy=try await seed.resource(url,owner:scope)
        XCTAssertEqual(copy.data,bytes)
        XCTAssertEqual(copy.mime,"video/mp4")
        let offline=TopicVideoStore { _ in throw URLError(.notConnectedToInternet) }
        let reopened=try await ChatStore.open(path:root.appendingPathComponent("chat.sqlite").path)
        let fresh=try await reopened.topicMediaScope(topic.id)
        let replay=try await offline.resource(url,owner:fresh)
        XCTAssertEqual(replay.data,bytes)
        let player=NativeMediaLoader(videoCacheDirectory:root.appendingPathComponent("playback"))
        let file=try await player.video(url.absoluteString,owner:fresh)
        XCTAssertTrue(file.url.isFileURL,"Playback of an owned MP4 should come from disk")
        XCTAssertEqual(try Data(contentsOf:file.url),bytes)
        await player.release(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.url.path))
        for (path, type) in [("fake.mp4","text/html"),("not-video.mp4","video/mp4")] {
            let bad=TopicVideoStore { _ in (type=="text/html" ? bytes : Data("login required".utf8),200,type,"") }
            do {
                _ = try await bad.resource(url.deletingLastPathComponent().appendingPathComponent(path),owner:fresh)
                XCTFail("An invalid movie should not become a permanent attachment")
            } catch {}
        }
        let objects=try await reopened.localResourceCount()
        XCTAssertEqual(objects,1)
        try await reopened.removeTopic(topic.id)
        let cleared=try await reopened.localResourceCount()
        XCTAssertEqual(cleared,0)
    }

    @MainActor func testOfflineHTMLClaimsResponsiveBackgroundAndScriptInsertedImages() async throws {
        let (root,db)=try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at:root) }
        let library=try await addMediaTopic(db), destination=try await addMediaTopic(db)
        let seedScope=try await db.topicMediaScope(library.id), shownScope=try await db.topicMediaScope(destination.id)
        // Disabled local port: any route that bypasses the app's resource handler fails.
        // There is no externally reachable URL and no production chat credential.
        let urls=try ["responsive","background","script"].map { try XCTUnwrap(URL(string:"https://127.0.0.1:1/fixture-\($0).png")) }
        let bytes=pixelPNG(.purple)
        let synthetic=RemoteImageStore(directory:root.appendingPathComponent("seed")) { _ in RemoteImageReply(data:bytes,status:200,cacheControl:"public, max-age=0") }
        for url in urls { _ = try await synthetic.resource(url,owner:seedScope) }
        let page="""
        <div id="vcp-root">
        <img id="responsive" srcset="\(urls[0].absoluteString) 1x" alt="responsive">
        <div id="backdrop" style="width:48px;height:48px;background-image:url('\(urls[1].absoluteString)')"></div>
        <script>
        const photo=document.createElement('img');
        photo.id='inserted';
        photo.src='\(urls[2].absoluteString)';
        document.getElementById('vcp-root').append(photo);
        </script>
        </div>
        """
        let window=try host(HTMLIsland(source:page,options:.init())
            .environment(\.scenePhase,.active).environment(\.topicMediaOwner,shownScope))
        defer { window.isHidden=true }
        try await eventually("fixture web view mounts") { self.find(WKWebView.self,in:window) != nil }
        let web=try XCTUnwrap(find(WKWebView.self,in:window))
        let clock=ContinuousClock(), deadline=clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Offline card did not finish navigation") }
            try await Task.sleep(for:.milliseconds(200))
        }
        guard try await observeIsland(web,"offline responsive and script-inserted image bytes are decoded",condition:"""
        const a=document.getElementById('responsive'), b=document.getElementById('inserted');
        return a && b && a.complete && b.complete && a.naturalWidth > 0 && b.naturalWidth > 0;
        """) else { return }
        let keys=Set(urls.map(RemoteImageStore.key))
        // Checking recorded ownership proves the CSS background request took the native path as well.
        try await eventually("all three resources were supplied and linked to this card's topic") {
            guard let refreshed=try? await db.topicMediaScope(destination.id) else { return false }
            return keys.isSubset(of:Set(refreshed.imageSizes.keys))
        }
        try await db.removeTopic(library.id)
        let linked=try await db.localResourceCount()
        XCTAssertEqual(linked,3,"Deleting the seed topic must not remove resources displayed by the other card")
    }

    private var fixtureSVG: String {
        """
        <svg id="fixture-root-svg" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 56" width="100%" role="img">
          <defs><linearGradient id="fixture-gradient"><stop offset="0%" stop-color="#1687a7"/><stop offset="100%" stop-color="#58b490"/></linearGradient></defs>
          <rect x="0" y="0" width="120" height="56" rx="8" fill="url(#fixture-gradient)"/>
          <circle cx="18" cy="27" r="4"><animate attributeName="cx" from="18" to="96" dur="2s" repeatCount="indefinite"/></circle>
        </svg>
        """
    }

    @MainActor private func readyFixtureWeb(_ window:UIWindow, scenario:String) async throws -> WKWebView {
        try await eventually("WebKit mounts for " + scenario) { self.find(WKWebView.self,in:window) != nil }
        let web=try XCTUnwrap(find(WKWebView.self,in:window))
        let clock=ContinuousClock(), deadline=clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { XCTFail("WebKit did not navigate for " + scenario); return web }
            try await Task.sleep(for:.milliseconds(200))
        }
        return web
    }

    @MainActor func testLeadingStylesAndKeyframesSurviveBesideAnimationAndProse() async throws {
        let css="""
        <style>
        @keyframes fixturePulse { from { opacity:.45 } to { opacity:.95 } }
        .regression-fixture-card { padding:13px; border-radius:17px; background:linear-gradient(90deg,#1687a7,#58b490); }
        .regression-fixture-card strong { animation: fixturePulse 2s ease-in-out infinite alternate; }
        </style>
        """
        let card = #"<div class="regression-fixture-card"><strong>内容卡</strong></div>"#
        let ticks = String(repeating:"`", count:3)
        let guide = ticks+"html\n<style>.regression-fixture-card { --fenced: existing-example; }</style>\n"+ticks
        let unrelated = "<style>.totally-unrelated-fixture { --not-for-card: 1; }</style>"
        let rich = ["前段正文",guide,unrelated,css,"中间的 **独立说明** 不能被卷入卡片。",card,fixtureSVG,"后段正文"].joined(separator:"\n\n")
        let blocks = try await MessageRenderer().render(rich,options:.init(),dark:false)
        let islands=blocks.compactMap { block -> String? in if case .html(let src)=block { return src }; return nil }
        let styled=try XCTUnwrap(islands.first { $0.contains("regression-fixture-card") && $0.contains("<strong>") })
        XCTAssertTrue(styled.contains("@keyframes fixturePulse"),"An isolated stylesheet cannot style the following WebView")
        XCTAssertFalse(styled.contains("--fenced") || styled.contains("--not-for-card"),"Code examples and unrelated rules are not inherited")
        XCTAssertFalse(styled.contains("独立说明"),"The intervening paragraph remains native Markdown")
        let svg=try XCTUnwrap(islands.first { $0.contains("<svg") && $0.contains("fixture-root-svg") })
        XCTAssertFalse(svg.contains("fixturePulse"),"A detached style must not leak to the next SVG document")
        XCTAssertTrue(blocks.contains { if case .code(_,let value,_)=$0 {return value.contains("--fenced")};return false })
        let prose=blocks.compactMap { block -> String? in
            guard case .paragraph(let runs)=block else { return nil }
            return runs.compactMap { if case .text(let t)=$0 { return String(t.characters) };return nil }.joined()
        }.joined()
        XCTAssertTrue(["前段正文","独立说明","后段正文"].allSatisfy { prose.contains($0) })
        XCTAssertFalse(prose.contains("fixturePulse"))
        XCTAssertFalse(blocks.contains { if case .literal(let value)=$0 {return value.contains("fixturePulse")};return false },
                       "Applied stylesheet must never also appear as literal source")
        let poststyled = "<div id='solo-id'>后置样式卡</div>\n\n中间段落仍然是正文。\n\n<style>#solo-id { border-radius:9px; }</style>"
        let late = try await MessageRenderer().render(poststyled,options:.init(),dark:false)
        let lateCard = try XCTUnwrap(late.compactMap { block -> String? in
            if case .html(let body)=block { return body }; return nil
        }.first)
        XCTAssertTrue(lateCard.contains("后置样式卡") && lateCard.contains("#solo-id { border-radius:9px; }"))
        XCTAssertFalse(lateCard.contains("中间段落"),"Only the matching stylesheet travels with the id-only card")
        XCTAssertTrue(late.contains { block in
            guard case .paragraph(let runs)=block else {return false}
            return runs.contains { if case .text(let t)=$0 { return String(t.characters).contains("中间段落仍然是正文。") };return false }
        })
        XCTAssertFalse(late.contains { if case .literal(let t)=$0 { return t.contains("#solo-id") }; return false })
        let window=try host(HTMLIsland(source:styled,options:.init()).environment(\.scenePhase,.active))
        defer { window.isHidden=true }
        let web=try await readyFixtureWeb(window,scenario:"styled card")
        _ = try await observeIsland(web,"gradient, DOM and keyframes actually apply to the card",condition:"""
        const card=document.querySelector('.regression-fixture-card');
        if(!card || card.querySelector('strong')?.textContent !== '内容卡') return false;
        const rendered=getComputedStyle(card);
        const keyframes=[...document.styleSheets].some(s=>[...s.cssRules].some(rule=>rule.name==='fixturePulse'));
        return rendered.paddingTop==='13px' && rendered.borderTopLeftRadius==='17px' &&
            rendered.backgroundImage.includes('linear-gradient') && keyframes && card.getBoundingClientRect().width>0;
        """)
    }

    @MainActor func testStandaloneSVGUsesSVGNamespaceAndFenceRemainsSource() async throws {
        let engine=MessageRenderer()
        let open=try await engine.render("图示：\n\n"+fixtureSVG+"\n\n完。",options:.init(),dark:false)
        let raw=try XCTUnwrap(open.compactMap { block -> String? in if case .html(let value)=block {return value}; return nil }.first)
        let ticks=String(repeating:"`", count:3)
        let code=try await engine.render(ticks+"svg\n"+fixtureSVG+"\n"+ticks,options:.init(),dark:false)
        XCTAssertTrue(code.contains { if case .code("svg",let text,_)=$0 { return text.contains("<animate") && text.contains("<svg") }; return false })
        XCTAssertFalse(code.contains { if case .html=$0 {return true};return false })
        let window=try host(HTMLIsland(source:raw,options:.init()).environment(\.scenePhase,.active))
        defer { window.isHidden=true }
        let web=try await readyFixtureWeb(window,scenario:"standalone SVG")
        _ = try await observeIsland(web,"standalone SVG is drawn with native geometry and its gradient and SMIL children",condition:"""
        const svg=document.querySelector('#fixture-root-svg'), ns='http://www.w3.org/2000/svg';
        if(!svg) return false;
        const rect=svg.querySelector('rect'), circle=svg.querySelector('circle'), defs=svg.querySelector('defs');
        const gradient=defs?.querySelector('linearGradient'), animation=circle?.querySelector('animate');
        if(![svg,rect,circle,defs,gradient,animation].every(x=>x?.namespaceURI===ns)) return false;
        return svg.viewBox.baseVal.width===120 && svg.getBoundingClientRect().width>0 &&
            rect.getBBox().width===120 && rect.getAttribute('fill')==='url(#fixture-gradient)' &&
            gradient.querySelectorAll('stop').length===2 && animation.getAttribute('attributeName')==='cx';
        """)
    }

    private let receiptID = "2026-11-19T22:50:25.956+08:00"
    private func batch(_ body: String, id: String, shell: Bool = true) -> String {
        let source = "<<<[VCP_TOOL_BATCH_START:\(id)]>>>\n" + body + "\n<<<[VCP_TOOL_BATCH_END:\(id)]>>>"
        return shell ? "<<<[ROLE_DIVIDE_USER]>>>\n"+source+"\n<<<[END_ROLE_DIVIDE_USER]>>>" : source
    }

    func testToolBatchHidesOnlyItsTransportAndKeepsSummaryAndImage() async throws {
        let tool = "<<<[TOOL_REQUEST]>>>\ntool_name:「始」NovelAIGen「末」\n<<<[END_TOOL_REQUEST]>>>"
        let summary = "[本轮工具调用摘要:]\nNovelAIGen 调用成功。\n[本轮工具调用摘要结束]"
        let picture = "![生成图](https://fixtures.invalid/generated/portrait.png)"
        let source = tool+"\n"+batch(summary,id:receiptID)+"\n"+picture
        let blocks = try await MessageRenderer().render(source, options:.init(), dark:false)
        XCTAssertEqual(blocks.count,3)
        guard blocks.count==3,
              case .vcp(.tool("NovelAIGen", _, _, true)) = blocks[0],
              case .vcp(.batch(let receipts, true)) = blocks[1], receipts.count == 1,
              case .summary(let lines,true) = receipts[0],
              case .paragraph(let runs) = blocks[2] else { return XCTFail("Expected the tool, one receipt and the assistant's image") }
        XCTAssertEqual(lines,["NovelAIGen 调用成功。"])
        XCTAssertTrue(runs.contains { if case .media(let image)=$0 { return image.caption=="生成图" };return false })
        XCTAssertFalse(SpeechText.plain(source).contains("VCP_TOOL_BATCH"))
    }

    func testBatchCloseMatchesIDAndToolPayloadStaysInert() {
        let foreign = "<<<[VCP_TOOL_BATCH_END:wrong]>>>"
        let literal = "<script>sample()</script>\n<<<[TOOL_REQUEST]>>>"
        let result = "[[VCP调用结果信息汇总:\n工具名称: Example\n执行状态: 成功\n返回内容: ok\nVCP调用结果结束]]"
        let full = batch(literal+"\n"+foreign+"\n"+result,id:receiptID,shell:false)+"\n正文"
        let items=VCPMarkup.parse(full)
        guard items.count==2,case .batch(let parts,true)=items[0],case .text(let after)=items[1] else { return XCTFail("Boundary mismatch") }
        XCTAssertEqual(after.trimmingCharacters(in:.whitespacesAndNewlines),"正文")
        XCTAssertTrue(parts.contains { if case .note(let note)=$0 { return note.contains(literal) && note.contains(foreign) };return false })
        XCTAssertTrue(parts.contains { if case .result(let r,true)=$0 { return r.tool=="Example" && r.content=="ok" };return false })
        let partial = "<<<[ROLE_DIVIDE_USER]>>>\n<<<[VCP_TOOL_BATCH_START:\(receiptID)]>>>\n等待\n<<<[VCP_TOOL_BATCH_EN"
        XCTAssertEqual(VCPMarkup.parse(partial,streaming:true),[.batch([.note("等待")],false)])
        XCTAssertEqual(VCPMarkup.parse(batch("",id:receiptID)),[])
        let other = "<<<[ROLE_DIVIDE_USER]>>>你好<<<[END_ROLE_DIVIDE_USER]>>>"
        XCTAssertEqual(VCPMarkup.parse(other),[.divider("user",false),.text("你好"),.divider("user",true)])
    }

    func testDocumentedBatchInMarkdownIsLiteral() async throws {
        let sample=batch("演示",id:receiptID,shell:false)
        let fence=String(repeating:"`",count:3)
        let source=fence+"text\n"+sample+"\n"+fence+"\n\n"+batch("真的回执",id:receiptID,shell:false)
        let blocks=try await MessageRenderer().render(source, options:.init(), dark:false)
        guard blocks.count==2,case .code(_,let code,_)=blocks[0],
              case .vcp(.batch(let parts,true))=blocks[1],parts == [.note("真的回执")] else { return XCTFail("Expected a code example and a separate receipt") }
        XCTAssertTrue(code.contains(sample))
        let inline = "`example <<<[VCP_TOOL_BATCH_START:sample]>>> text`"
        XCTAssertEqual(VCPMarkup.parse(inline),[.text(inline)])
    }

    // The list supplies a finite width; its one-line label environment must not
    // leak into message prose. Compare identical folded headers/images, so the
    // measured difference can only come from the visible, wrapped body text.
    @MainActor func testLongMixedParagraphWrapsBetweenReasoningAndSticker() async throws {
        let file = "GEM_PHOTO_" + String(repeating: "1A2965D5", count: 14) + "_FINAL.PNG"
        let chinese = String(repeating: "这段回复应该在手机气泡内一直换行直到", count: 5) + "最后一字。"
        let captions = ["短句", chinese, file]
        let tag = #"<img width="36" alt="合成表情" src="data:image/png;base64,\#(pixelPNG(.green).base64EncodedString())">"#
        let renderer = MessageRenderer()
        for caption in captions {
            let blocks = try await renderer.render(caption + " " + tag, options: .init(), dark: false)
            let shown = blocks.flatMap { block -> [InlineRun] in
                if case .paragraph(let runs) = block { return runs }
                return []
            }
            let visibleText = shown.compactMap { run -> String? in
                if case .text(let value) = run { return String(value.characters) }; return nil
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(visibleText, caption, "Parser lost or shortened text before the sticker")
            XCTAssertEqual(shown.filter { if case .media = $0 { return true }; return false }.count, 1)
        }

        let probe = MixedHeightProbe()
        let window = try host(ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(captions.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        DisclosureGroup("思考过程", isExpanded: .constant(false)) { Text("折叠的推理") }
                        RichMessageBody(captions[index] + " " + tag, expandsToFill: true)
                    }
                    .font(.system(size: 17))
                    .lineLimit(1)
                    .environment(\.scenePhase, .active)
                    .environment(\.messageTextSelectionEnabled, false)
                    .frame(width: 214, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        probe.heights[index] = h
                    }
                }
            }
        })
        defer { window.isHidden = true }
        try await eventually("Chinese and uninterrupted filename both grow by several visible lines above the 36pt sticker") {
            guard let short = probe.heights[0], short > 55,
                  let paragraph = probe.heights[1], let filename = probe.heights[2] else { return false }
            return paragraph > short + 50 && filename > short + 35
        }
    }

    @MainActor func testAttachmentFilenameUsesMoreThanOneLineInHistory() {
        let name = "GEM_PHOTO_" + String(repeating: "9B641CD8", count: 14) + "_END.GIF"
        func height(_ name: String) -> CGFloat {
            let item = ChatAttachment(name: name, mime: "image/gif", kind: "image")
            let view = AttachmentStrip(attachments: [item]).frame(width: 218)
            return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 218, height: 700)).height
        }
        let short = height("short.gif"), long = height(name)
        XCTAssertGreaterThan(short, 10)
        XCTAssertGreaterThan(long, short + 25, "A sent attachment's full filename must wrap within the bubble")
    }

    func testDisplayRulesRenderOrdinaryPairedHTMLBesideTextAndAnImage() async throws {
        var card = RegexRule()
        card.findPattern = #"/\[卡:([^\]]+)\]/g"#
        card.replaceWith = #"<details data-note="a > b"><summary>角色</summary><strong>$1</strong></details>"#
        let image = "![合成表情](https://fixtures.invalid/img/sample.png)"
        let original = "前文[卡:星河]后文 " + image
        let renderer = MessageRenderer()
        for live in [true, false] {
            let blocks = try await renderer.render(original, options: .init(), dark: false, streaming: live, rules: [card])
            let cards = blocks.compactMap { block -> String? in if case .html(let body) = block { return body }; return nil }
            XCTAssertEqual(cards, [card.replaceWith.replacingOccurrences(of: "$1", with: "星河")])
            guard let i = blocks.firstIndex(where: { if case .html = $0 { return true }; return false }) else { return }
            func inline(_ range: ArraySlice<RenderBlock>) -> [InlineRun] {
                range.flatMap { if case .paragraph(let runs) = $0 { return runs }; return [] }
            }
            let before = inline(blocks[..<i]), after = inline(blocks[(i + 1)...])
            XCTAssertTrue(before.contains { if case .text(let t) = $0 { return String(t.characters).contains("前文") }; return false })
            XCTAssertTrue(after.contains { if case .text(let t) = $0 { return String(t.characters).contains("后文") }; return false })
            XCTAssertEqual(after.compactMap { if case .media(let m) = $0 { return m.source }; return nil }, ["https://fixtures.invalid/img/sample.png"])
        }
        var disabled = RenderOptions(); disabled.html = false
        let disabledBlocks = try await renderer.render(original, options: disabled, dark: false, rules: [card])
        XCTAssertFalse(disabledBlocks.contains { if case .html = $0 { return true }; return false })
        let changed = try await RegexEngine().apply(original, rules: [card], scope: "context", role: "assistant")
        XCTAssertEqual(changed, original, "A display card must not turn into prompt HTML")
    }

    func testUnrelatedDisplayReplacementDoesNotPromoteExistingInlineHTML() async throws {
        let original = "原始<span>原样</span>相邻，卡片标记"
        let renderer = MessageRenderer()
        var rule = RegexRule(); rule.findPattern = "卡片标记"
        for template in ["改过的正文", "<details><summary>标题</summary>新卡片</details>"] {
            rule.replaceWith = template
            let blocks = try await renderer.render(original, options: .init(), dark: false, rules: [rule])
            let html = blocks.compactMap { block -> String? in if case .html(let s) = block { return s }; return nil }
            XCTAssertEqual(html, template.hasPrefix("<") ? [template] : [], "Only newly introduced inline HTML should be promoted")
            let text = blocks.flatMap { block -> [String] in
                guard case .paragraph(let runs) = block else { return [] }
                return runs.compactMap { if case .text(let t) = $0 { return String(t.characters) }; return nil }
            }.joined()
            for piece in ["原始", "原样", "相邻"] { XCTAssertTrue(text.contains(piece), "Original surrounding text was lost: " + piece) }
        }
    }

    @MainActor func testRegexDetailsOutputCanActuallyOpenInItsWebView() async throws {
        var rule = RegexRule(); rule.findPattern = #"/\[状态:(.*?)\]/g"#
        rule.replaceWith = #"<details id="fixture-regex-details" title="a > b"><summary>状态</summary><p>$1</p></details>"#
        let window = try host(RichMessageBody("前文[状态:星河]后文", rules: [rule]).environment(\.scenePhase, .active))
        defer { window.isHidden = true }
        try await eventually("regex-produced card mounted its own WKWebView") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Regex card page did not finish loading") }
            try await Task.sleep(for: .milliseconds(200))
        }
        _ = try await observeIsland(web, "regex capture rendered in a working HTML disclosure", condition: """
        const card = document.getElementById('fixture-regex-details');
        if (!card || card.querySelector('p')?.textContent !== '星河') return false;
        if (card.title !== 'a > b' || card.querySelector('summary')?.textContent !== '状态')
            throw new Error('HTML attributes or summary changed');
        if (!card.open) card.querySelector('summary').click();
        return card.open && card.querySelector('p').getBoundingClientRect().height > 0;
        """)
    }

    func testDisplayRegexLeavesReceiptsIntactAndContinuesAfterInvalidRule() async throws {
        var broken = RegexRule(); broken.findPattern = "/(/g"; broken.title = "损坏的规则"
        var a = RegexRule(); a.findPattern = "READY"; a.replaceWith = "stage1"
        var b = RegexRule(); b.findPattern = "stage1"; b.replaceWith = "完成"
        var context = RegexRule(); context.findPattern = "READY"; context.replaceWith = "提示词"; context.applyToFrontend = false; context.applyToContext = true
        a.minDepth = 1; a.maxDepth = 2; b.minDepth = 1; b.maxDepth = 2
        let raw = "READY\n" + batch("READY", id: receiptID) + "\nREADY"
        let renderer = MessageRenderer(), rules = [broken, a, b, context]
        let displayed = try await renderer.render(raw, options: .init(), dark: false, rules: rules, role: "assistant", depth: 1)
        let text = displayed.flatMap { block -> [String] in
            guard case .paragraph(let runs) = block else { return [] }
            return runs.compactMap { if case .text(let t) = $0 { return String(t.characters) }; return nil }
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        XCTAssertEqual(text, "完成完成")
        XCTAssertTrue(displayed.contains(.vcp(.batch([.note("READY")], true))), "Display replacements must not rewrite the authenticated receipt boundary or payload")
        for (role, depth) in [("user", 1), ("assistant", 3)] {
            let blocks = try await renderer.render("READY", options: .init(), dark: false, rules: rules, role: role, depth: depth)
            guard case .paragraph(let runs) = blocks.first, case .text(let t) = runs.first else { return XCTFail("Expected original prose") }
            XCTAssertEqual(String(t.characters), "READY")
        }
        let prompt = try await RegexEngine().apply("READY", rules: [a, b, context], scope: "context", role: "assistant", depth: 1)
        XCTAssertEqual(prompt, "提示词")
    }

    func testHTMLRuleInsideCodeRemainsALiteralExample() async throws {
        var rule = RegexRule(); rule.findPattern = "TOKEN"; rule.replaceWith = "<section><b>示例</b></section>"
        let fenced = String(repeating: "`", count: 3)
        let source = fenced + "html\nTOKEN\n" + fenced + "\n\n\u{60}TOKEN\u{60}\n\nTOKEN"
        let blocks = try await MessageRenderer().render(source, options: .init(), dark: false, rules: [rule])
        let html = blocks.filter { if case .html = $0 { return true }; return false }
        XCTAssertEqual(html.count, 1, "Only the unfenced occurrence becomes a card")
        XCTAssertTrue(blocks.contains { if case .code("html", let literal, _) = $0 { return !literal.isEmpty }; return false })
        let hasInlineExample = blocks.contains { block in
            guard case .paragraph(let runs) = block else { return false }
            return runs.contains { run in
                guard case .text(let text) = run else { return false }
                return text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }
            }
        }
        XCTAssertTrue(hasInlineExample, "The inline code sample must remain a code span")
    }

    @MainActor func testStandaloneRoleMarkerCannotGrowIntoAnEmptyPanel() {
        let content=VCPCardView(segment:.divider("user",false),options:.init())
        let controller=UIHostingController(rootView:content)
        let size=controller.sizeThatFits(in:CGSize(width:340,height:600))
        XCTAssertGreaterThan(size.height,5)
        XCTAssertLessThan(size.height,45)
    }

    @MainActor func testRemotePhotoFitsBubbleButStickerKeepsAuthoredWidth() throws {
        let picture=try XCTUnwrap(MessageMedia.html(#"<img src="https://fixtures.invalid/pw=fixture/images/generated/portrait.png" width="110">"#))
        let sticker=try XCTUnwrap(MessageMedia.html(#"<img src="https://fixtures.invalid/pw=fixture/images/测试表情包/笑.png" width="110">"#))
        func measure(_ media: MessageMedia,_ pixels:CGSize,_ width:CGFloat) -> CGSize {
            let layout=MessageImageLayout(pixels:pixels,widthLimit:media.inlineWidthLimit) { Color.red }
            return UIHostingController(rootView:layout).sizeThatFits(in:CGSize(width:width,height:2000))
        }
        for width in [CGFloat(248),338] {
            let size=measure(picture,CGSize(width:512,height:768),width)
            XCTAssertEqual(size.width,width,accuracy:1)
            XCTAssertEqual(size.height,width*1.5,accuracy:1)
        }
        let landscape=measure(picture,CGSize(width:1000,height:500),320)
        XCTAssertEqual(landscape.height,160,accuracy:1)
        XCTAssertEqual(measure(sticker,CGSize(width:512,height:512),320).width,110,accuracy:1)
        let tall=measure(picture,CGSize(width:500,height:5000),338)
        XCTAssertLessThanOrEqual(tall.height,721)
        XCTAssertEqual(tall.width/tall.height,0.1,accuracy:0.002)
    }

    @MainActor func testComposerManualDismissalAndSendDismissal() async throws {
        let state = KeyboardFixtureState()
        state.draft = ""
        let window = try host(KeyboardFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("editor is mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("草稿")
        try await eventually("typed draft reached the model") { state.draft == "草稿" }
        let bar = try XCTUnwrap(editor.inputAccessoryView as? UIToolbar)
        let hide = try XCTUnwrap(bar.items?.first { $0.title == "收起键盘" })
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(hide.action), to: hide.target, from: hide, for: nil))
        XCTAssertFalse(editor.isFirstResponder, "manual dismissal keeps the draft without sending it")
        XCTAssertEqual(editor.text, "草稿")
        XCTAssertEqual(state.draft, "草稿")
        XCTAssertTrue(state.sent.isEmpty)

        XCTAssertTrue(editor.becomeFirstResponder())
        state.acceptsSend = false
        editor.insertText("\n")
        XCTAssertTrue(editor.isFirstResponder, "rejected send should keep focus")
        XCTAssertEqual(editor.text, "草稿")
        XCTAssertTrue(state.sent.isEmpty)

        state.acceptsSend = true
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("！")
        editor.insertText("\n")
        XCTAssertEqual(state.sent, ["草稿！"], "Return must submit the latest text exactly once")
        XCTAssertFalse(editor.isFirstResponder, "accepted send should release keyboard focus")
        try await eventually("accepted draft cleared from the visible editor") { editor.text.isEmpty }
    }

    @MainActor func testReturnCanStillInsertANewline() async throws {
        let state = KeyboardFixtureState()
        let window = try host(KeyboardFixture(state: state, enterSends: false))
        defer { window.isHidden = true }
        try await eventually("newline-mode editor is mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("\n")
        XCTAssertEqual(editor.text, "草稿\n")
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertTrue(state.sent.isEmpty)
    }

    @MainActor func testComposerKeepsFocusUntilMessageAndOutboxCommit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("chat.sqlite").path
        let store = try await ChatStore.open(path: path)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_outbox BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT,'outbox unavailable'); END", nil, nil, nil), SQLITE_OK)

        let model = ChatViewModel()
        let agent = VCPAgent(), topic = ChatTopic(ownerId: agent.id, title: "本机入队")
        let room = ChatRoom(id: topic.id, messages: [])
        model.store = store; model.agents = [agent]; model.topics = [topic]
        model.activeTopicID = topic.id; model.rooms = [topic.id: room]; model.apiKey = "fixture"
        let keyboard = ComposerKeyboard()
        let composer = NativeComposer(text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                                     enterSends: true, insertNewline: 0, keyboard: keyboard) {
            model.send {
                keyboard.didClearDraft()
                room.cancellation = .stopped  // Stop before network generation, after the real commit.
            }
        }
        let window = try host(composer)
        defer { window.isHidden = true }
        try await eventually("composer mounted") { self.find(UITextView.self, in: window) != nil }
        let editor = try XCTUnwrap(find(UITextView.self, in: window))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.insertText("重试"); editor.insertText("\n")
        await room.generation?.value
        let rolledBack = try await store.messages(topicID: topic.id)
        XCTAssertTrue(room.error?.contains("outbox unavailable") == true)
        XCTAssertTrue(rolledBack.isEmpty)
        XCTAssertEqual(room.draft, "重试")
        XCTAssertTrue(editor.isFirstResponder)

        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER reject_outbox", nil, nil, nil), SQLITE_OK)
        editor.insertText("\n")
        await room.generation?.value
        let stored = try await store.messages(topicID: topic.id)
        let pending = try await store.pending()
        XCTAssertEqual(stored.map(\.content), ["重试"])
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(room.draft, "")
        XCTAssertEqual(editor.text, "")
        XCTAssertFalse(editor.isFirstResponder)
    }

    func testAtlasKeepsConfiguredPrefixAndEncodedQuery() throws {
        for base in ["https://example.invalid/vcp", "https://example.invalid/vcp/v1", "https://example.invalid/vcp/v1/chat/completions"] {
            let config = ConnectionConfiguration(server: base)
            let url = try FieldAtlasClient.endpoint("/messages?q=%E6%98%A5%26%23", configuration: config)
            XCTAssertEqual(url.absoluteString, "https://example.invalid/vcp/api/plugins/WarpedFieldAtlas/messages?q=%E6%98%A5%26%23")
            XCTAssertThrowsError(try FieldAtlasClient.endpoint("/unlisted", configuration: config))
        }
    }

    func testAtlasResponseLimitCanBeRaisedOrRemoved() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [AtlasResponseFixture.self]
        for limit in [FieldAtlasResponseLimit.standard, .larger, .unlimited] {
            let client = FieldAtlasClient(configuration: .init(server: "https://atlas.invalid/vcp"), key: "fixture", responseLimit: limit, sessionConfiguration: session)
            defer { client.close() }
            do {
                let body = try await client.get("/status")
                XCTAssertNotEqual(limit, .standard)
                XCTAssertEqual(body, "{}")
            } catch {
                XCTAssertEqual(limit, .standard)
                XCTAssertTrue(error.localizedDescription.contains("32 MiB"))
            }
        }
    }

    @MainActor func testBubbleHostIsTransparentInBothThemes() async throws {
        let web = WKWebView()
        let sample = #"<div id="vcp-root" style="background:#faf5ef;color:#336699;border-radius:16px">卡片</div><p>正文</p>"#
        for dark in [false, true] {
            let page = HTMLIslandPolicy.document(sample, motion: false, media: false, dark: dark)
            web.loadHTMLString(page, baseURL: nil)
            try await eventually("bubble page loaded") { !web.isLoading }
            let result = try await web.evaluateJavaScript("""
                (() => { const css = el => getComputedStyle(el), card = css(document.querySelector('#vcp-root'));
                    return [css(document.documentElement).backgroundColor, css(document.body).backgroundColor,
                            css(document.querySelector('p')).color, card.backgroundColor, card.color, card.borderRadius]; })()
                """) as? [String]
            XCTAssertEqual(result, ["rgba(0, 0, 0, 0)", "rgba(0, 0, 0, 0)", dark ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)",
                                    "rgb(250, 245, 239)", "rgb(51, 102, 153)", "16px"])
        }
    }

    @MainActor func testBundledAtlasCanCallNativeBridge() async throws {
        let window = try host(FieldAtlasView(configuration: .init(server: "https://example.invalid"), key: ""))
        defer { window.isHidden = true }
        try await eventually("atlas mounts a web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))

        // Reading JS during provisional navigation can target the empty document. Use
        // native state while WebKit cold-starts; keep the bridge assertion separate.
        let clock = ContinuousClock()
        let loadDeadline = clock.now + .seconds(60)
        while web.isLoading || web.url?.isFileURL != true {
            guard clock.now < loadDeadline else {
                return XCTFail("Atlas navigation timed out: page=\(web.url?.lastPathComponent ?? "none"), progress=\(web.estimatedProgress), loading=\(web.isLoading)")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(web.url?.lastPathComponent, "index.html")

        // One WebKit call, in an isolated world, observes the visible DOM. The bundled
        // page must still call /status and render the real native client's reply.
        let observation = """
        const message = document.querySelector('.wa-message');
        if (!message) throw new Error('Atlas did not mount; document=' + document.readyState);
        const visibleText = () => message.isConnected && !message.hidden && message.textContent.trim();
        if (visibleText()) return visibleText();
        return await new Promise((resolve, reject) => {
            const observer = new MutationObserver(() => {
                const text = visibleText();
                if (text) { observer.disconnect(); clearTimeout(timer); resolve(text); }
            });
            const timer = setTimeout(() => {
                observer.disconnect();
                reject(new Error('Atlas mounted but rendered no status; hidden=' + message.hidden));
            }, 30000);
            observer.observe(message, { childList: true, subtree: true, characterData: true, attributes: true });
        });
        """
        var rendered: Result<Any, any Error>?
        web.callAsyncJavaScript(observation, arguments: [:], in: nil, in: .defaultClient) { rendered = $0 }
        let replyDeadline = clock.now + .seconds(45)
        while rendered == nil {
            guard clock.now < replyDeadline else {
                return XCTFail("WebContent did not complete the DOM observation after the local page loaded")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        switch try XCTUnwrap(rendered) {
        case .success(let value):
            let message = try XCTUnwrap(value as? String)
            XCTAssertTrue(message.contains("请先在服务器设置中填写聊天 API Key。"), "Unexpected visible status: \(message)")
        case .failure(let error):
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            XCTFail("Atlas status observation failed: \(detail ?? error.localizedDescription)")
        }
    }

    @MainActor func testRemoteImageSurvivesReopenAndCoalescesRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(URL(string: "https://fixtures.invalid/pw=fixture-a/images/test/card.png?revision=1"))
        let origin = ImageOriginFixture(), payload = pixelPNG(.purple)
        await origin.set(source, payload)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        async let first = online.resource(source)
        async let second = online.resource(source)
        let pair = try await (first, second)
        XCTAssertEqual(pair.0.data, payload)
        XCTAssertEqual(pair.1.data, payload)
        let count = await origin.count(source)
        XCTAssertEqual(count, 1, "two views for one URL must share the download")

        let offline = ImageOriginFixture()
        let reopened = RemoteImageStore(directory: directory) { try await offline.get($0) }
        let restored = try await reopened.resource(source)
        XCTAssertEqual(restored.data, payload)
        let attempts = await offline.count(source)
        XCTAssertEqual(attempts, 0, "the second store has no memory cache and no available network")

        for changed in [
            "https://fixtures.invalid/pw=fixture-b/images/test/card.png?revision=1",
            "https://fixtures.invalid/pw=fixture-a/images/test/card.png?revision=2"
        ] {
            let url = try XCTUnwrap(URL(string: changed))
            do { _ = try await reopened.resource(url); XCTFail("a different resource must not get the first image") }
            catch { /* the fixture is offline */ }
            let requests = await offline.count(url)
            XCTAssertEqual(requests, 1)
        }
    }

    @MainActor func testInvalidResponsesAreRetriedAndNoStoreIsNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/demo/card.png"))
        let bytes = pixelPNG(.orange), origin = ImageOriginFixture()
        let store = RemoteImageStore(directory: directory) { try await origin.get($0) }
        await origin.set(url, bytes, status: 403)
        do { _ = try await store.resource(url); XCTFail("denied content must not be cached as an image") }
        catch { }
        await origin.set(url, Data("<html>sign in</html>".utf8))
        do { _ = try await store.resource(url); XCTFail("HTTP 200 from a login page is not an image") }
        catch { }
        await origin.set(url, bytes, control: "private, no-store")
        let privateImage = try await store.resource(url)
        XCTAssertEqual(privateImage.data, bytes)
        let newProcess = RemoteImageStore(directory: directory) { try await origin.get($0) }
        _ = try await newProcess.resource(url)
        let count = await origin.count(url)
        XCTAssertEqual(count, 4, "no-store content needs the network after reopening")
    }

    @MainActor func testZeroMaxAgeOnlyPersistsVCPStickersWithoutRevalidationRestrictions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = ImageOriginFixture(), offline = ImageOriginFixture(), bytes = pixelPNG(.blue)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        // All cases use valid identical images. Only URL shape and HTTP cache policy differ.
        for (path, control, shouldPersist) in [
            ("pw=fixture/images/测试表情包/固定.png", "public, max-age=0", true),
            ("pw=fixture/images/photos/plain.png", "public, max-age=0", false),
            ("images/测试表情包/无前缀.png", "public, max-age=0", false),
            ("pw=fixture/images/测试表情包/禁止保存.png", "public, max-age=0, NO-STORE", false),
            ("pw=fixture/images/测试表情包/必须验证.png", "public, No-Cache, max-age=0", false),
            ("pw=fixture/images/测试表情包/必须重验.png", "public, max-age=0, must-revalidate", false)
        ] {
            let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/" + path))
            await origin.set(url, bytes, control: control)
            let live = try await online.resource(url)
            XCTAssertEqual(live.data, bytes)
            let cold = RemoteImageStore(directory: directory) { try await offline.get($0) }
            do {
                let fromDisk = try await cold.resource(url)
                XCTAssertTrue(shouldPersist, "unexpected persisted response for \(path), \(control)")
                XCTAssertEqual(fromDisk.data, bytes)
            } catch {
                XCTAssertFalse(shouldPersist, "valid VCP sticker was unavailable offline: \(error.localizedDescription)")
            }
            let networkAttempts = await offline.count(url)
            XCTAssertEqual(networkAttempts, shouldPersist ? 0 : 1, "wrong cold-load policy: \(path), \(control)")
        }
    }

    @MainActor func testStickerCatalogRepairsOnlyStickerNamesAndPackages() throws {
        let library = EmoticonCatalog(entries: ["猫表情包": ["开心.webp", "吃鱼.png"], "兔表情包": ["开心.gif"]])
        func source(_ package: String, _ filename: String) throws -> URL {
            let base = try XCTUnwrap(URL(string: "https://fixtures.invalid:8443/pw=fixture/images/"))
            return base.appendingPathComponent(package)
                .appendingPathComponent(filename)
                .appending(queryItems: [URLQueryItem(name: "revision", value: "abc")])
        }
        let missingExtension = try source("猫表情包", "开心.jpg")
        let expected = try source("猫表情包", "开心.webp")
        XCTAssertEqual(library.repair(missingExtension), expected, "same stem: choose the existing item in the named package")
        let inventedPackage = try source("虚构表情包", "吃鱼.gif")
        XCTAssertEqual(library.repair(inventedPackage), try source("猫表情包", "吃鱼.png"), "a unique stem can recover another package")
        let typo = try source("猫表情包", "吃小鱼.gif")
        XCTAssertEqual(library.repair(typo), try source("猫表情包", "吃鱼.png"), "unknown stem first searches the same package")
        let ordinary = try source("photos", "开心.jpg")
        XCTAssertEqual(library.repair(ordinary), ordinary)
        XCTAssertEqual(EmoticonCatalog(entries: [:]).repair(missingExtension), missingExtension)
    }

    @MainActor func testStickerResolutionStaysOnTheConfiguredOrigin() throws {
        let server = try XCTUnwrap(URL(string: "https://fixtures.invalid/v1/chat/completions"))
        let catalog = EmoticonCatalog(entries: ["猫表情包": ["笑.png"]])
        let context = StickerContext(server: server, fileKey: "fixture-ticket", catalog: catalog)
        let resolved = try XCTUnwrap(context.resolve("images/猫表情包/笑.gif"))
        XCTAssertEqual(resolved.host, server.host)
        XCTAssertEqual(resolved.path, "/pw=fixture-ticket/images/猫表情包/笑.png")

        let old = "https://fixtures.invalid:6005/pw=older/images/猫表情包/笑.gif?revision=5"
        let fixed = try XCTUnwrap(context.resolve(old))
        XCTAssertEqual(fixed.scheme, "https")
        XCTAssertNil(fixed.port)
        XCTAssertEqual(fixed.path, "/pw=older/images/猫表情包/笑.png")
        XCTAssertEqual(fixed.query, "revision=5")

        let foreign = try XCTUnwrap(URL(string: "https://elsewhere.invalid:6005/pw=other/images/猫表情包/笑.gif"))
        XCTAssertEqual(context.resolve(foreign.absoluteString), foreign)
        XCTAssertNil(context.resolve("//elsewhere.invalid/images/猫表情包/笑.png"))
    }

    @MainActor func testMigratedLooseStickerUsesTheCatalogURLAcrossNativeAndWebKit() async throws {
        let server = try XCTUnwrap(URL(string:"https://chat.invalid"))
        let catalog = EmoticonCatalog(entries:["Fixture表情包":["开怀大笑.webp"]])
        let context = StickerContext(server:server,fileKey:"configured-test-key",catalog:catalog)
        let raw = "https://images.invalid:6005/pw=sample@./images/Fixture表情包/开怀大笑.png"
        let tag = "< img src=\"" + raw + "\" width=\"110\" style=\"b"
        let target = try XCTUnwrap(URL(string:"https://chat.invalid/pw=configured-test-key/images/Fixture表情包/开怀大笑.webp"))
        let sourceURL = try XCTUnwrap(URL(string:raw))
        let candidates = context.imageCandidates(raw)
        XCTAssertEqual(candidates.first,target)
        XCTAssertTrue(candidates.dropFirst().allSatisfy { $0.host == "images.invalid" && !$0.absoluteString.contains("configured-test-key") })
        let plain = StickerContext(server:server)
        XCTAssertEqual(plain.imageCandidates(raw).first?.host,"images.invalid")
        XCTAssertNil(plain.imageCandidates(raw).first?.port)
        XCTAssertEqual(plain.imageCandidates(raw).last,sourceURL)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let fixture = ImageOriginFixture(), bytes = pixelPNG(.orange)
        await fixture.set(target,bytes,control:"public, max-age=3600")
        let store = RemoteImageStore(directory:dir) { try await fixture.get($0) }
        for text in [tag, tag + "order-radius:8px\">"] {
            let blocks = try await MessageRenderer().render(text,options:.init(),dark:false)
            guard case .paragraph(let runs) = blocks.first, case .media(let media) = runs.first else {
                return XCTFail("Loose sticker tag did not produce a native image")
            }
            XCTAssertEqual(media.preferredWidth,110)
            let value = try await StickerResolver.shared.loadImage(media.source,in:context) { url in try await store.resource(url) }
            XCTAssertEqual(value.data,bytes)
        }
        try await renderFixtureImage(sourceURL,using:store,stickers:context)
        let loads = await fixture.count(target)
        XCTAssertEqual(loads,1,"Native and WebKit must request the same canonical resource")
        let imported = try DesktopConnection(data: Data(#"{"vcpServerUrl":"https://chat.invalid","vcpApiKey":"test","fileKey":"configured-test-key"}"#.utf8))
        XCTAssertEqual(imported.fileKey,"configured-test-key")
    }

    @MainActor func testStableCodePrefixAppendsThenYieldsToTheCanonicalParser() throws {
        let prefix = "正文\n\n", opener = "~~~swift\n"
        let first = try XCTUnwrap(StreamFenceTail.split(prefix + opener + "let x"))
        let next = try XCTUnwrap(StreamFenceTail.split(prefix + opener + "let x = 1\nlet y"))
        XCTAssertEqual(first.prefix, prefix)
        XCTAssertEqual(next.prefix, first.prefix)
        XCTAssertEqual(next.language, "swift")
        XCTAssertEqual(next.body, "let x = 1\nlet y")
        XCTAssertNil(StreamFenceTail.split(prefix + opener + next.body + "\n~~~"))
        XCTAssertNil(StreamFenceTail.split(prefix + "    ~~~swift\nexample"), "indented code is not a top-level streaming fence")
    }

    @MainActor func testLooseStickerTagRendersButCodeExamplesStayLiteral() async throws {
        let source = "https://fixtures.invalid/images/sample/card.png"
        let tag = "< img src=\"\(source)\" width=\"110\" style=\"border-radius:10px;display:block;flex-shrink:0;\" alt=\"笑\">"
        let renderer = MessageRenderer(), options = RenderOptions()
        let blocks = try await renderer.render(tag, options: options, dark: false)
        let images: [MessageMedia] = blocks.flatMap { block -> [MessageMedia] in
            guard case .paragraph(let runs) = block else { return [] }
            return runs.compactMap { run in if case .media(let media) = run { return media }; return nil }
        }
        XCTAssertEqual(images.map(\.source), [source])
        XCTAssertEqual(images.first?.caption, "笑")
        XCTAssertEqual(images.first?.preferredWidth, 110)
        XCTAssertEqual(images.first?.cornerRadius, 10)

        let fence = String(repeating: "`", count: 3)
        let open = fence + "html\n" + tag
        for (frame, expected, live) in [
            (open, tag, true),
            (open + "\n第二行", tag + "\n第二行", true),
            (open + "\n第二行\n" + fence, tag + "\n第二行", false)
        ] {
            let blocks = try await renderer.render(frame, options: options, dark: false, streaming: live)
            guard case .code(let language, let literal, _) = blocks.first else { return XCTFail("expected a literal code block") }
            XCTAssertEqual(language, "html")
            XCTAssertEqual(literal.trimmingCharacters(in: .newlines), expected)
        }
        let inline = try await renderer.render("示例：`" + tag + "`", options: options, dark: false)
        guard case .paragraph(let runs) = inline.first else { return XCTFail("expected inline code") }
        let text = runs.compactMap { run -> String? in if case .text(let t) = run { return String(t.characters) }; return nil }.joined()
        XCTAssertTrue(text.contains(tag))
        XCTAssertFalse(runs.contains { if case .media = $0 { true } else { false } })
    }

    // Keep native waiting bounded even if the simulator's WebContent process stops.
    // Once the native page starts loading, one isolated-world observer per phase
    // checks actual DOM changes without repeatedly bridging arbitrary script.
    @MainActor private func observeIsland(_ web: WKWebView, _ phase: String, condition: String,
                                          file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
        let script = """
        return await new Promise((resolve, reject) => {
            const matches = () => { \(condition) };
            const observer = new MutationObserver(check);
            const cleanup = () => { observer.disconnect(); clearTimeout(timer); document.removeEventListener('load', check, true); };
            const timer = setTimeout(() => { cleanup(); reject(new Error('island condition not reached')); }, 30000);
            function check() {
                try {
                    if (!matches()) return;
                    cleanup(); resolve(true);
                } catch (error) { cleanup(); reject(error); }
            }
            observer.observe(document, { attributes: true, childList: true, subtree: true, characterData: true });
            // A resource load changes naturalWidth without necessarily mutating an attribute.
            document.addEventListener('load', check, true);
            check();
        });
        """
        var rendered: Result<Any, any Error>?
        web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { rendered = $0 }
        let clock = ContinuousClock(), deadline = clock.now + .seconds(45)
        while rendered == nil && clock.now < deadline { try await Task.sleep(for: .milliseconds(200)) }
        guard let rendered else { XCTFail("WebContent did not finish: " + phase, file: file, line: line); return false }
        switch rendered {
        case .success(let value):
            guard value as? Bool == true else { XCTFail("Unexpected WebKit response: " + phase, file: file, line: line); return false }
            return true
        case .failure(let error):
            XCTFail(phase + ": " + error.localizedDescription, file: file, line: line)
            return false
        }
    }

    @MainActor func testStreamedIslandKeepsItsImageAndInitializesOnceThroughFinal() async throws {
        let state = IslandFixtureState(image: pixelPNG(.green))
        let window = try host(IslandFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("island mounts its web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Island document did not finish navigation") }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard try await observeIsland(web, "closed streaming island has started", condition: """
        const photo = document.getElementById('fixture-photo');
        if (!photo || document.documentElement.dataset.fixtureStarts !== '1') return false;
        window.__fixturePhoto = photo;
        return true;
        """) else { return }

        state.source += "\n<script>document.documentElement.dataset.fixtureNext = 'yes';</script>"
        guard try await observeIsland(web, "later frame retains the original image", condition: """
        if (document.documentElement.dataset.fixtureNext !== 'yes') return false;
        if (document.getElementById('fixture-photo') !== window.__fixturePhoto) throw new Error('image replaced during append');
        if (document.documentElement.dataset.fixtureStarts !== '1') throw new Error('script ran twice during append');
        return true;
        """) else { return }

        state.streaming = false
        _ = try await observeIsland(web, "canonical terminal retains the same image and script", condition: """
        if (document.documentElement.dataset.fixtureTerminal !== 'yes') return false;
        if (document.getElementById('fixture-photo') !== window.__fixturePhoto) throw new Error('image replaced at terminal');
        if (document.documentElement.dataset.fixtureStarts !== '1') throw new Error('script reran at terminal');
        return true;
        """)
    }

    @MainActor func testDesktopCanvasWaitsForOuterSealAndSurvivesTerminal() async throws {
        let open = """
        ### 阶段一

        <div class="desktop-stage"><style>.indicator { color: teal }</style>
        <div><canvas width="8" height="8"></canvas><span class="indicator">waiting</span></div>
        <script>
        const card = container.querySelector('.desktop-stage');
        if (!card) return;
        const canvas = card.querySelector('canvas');
        document.documentElement.dataset.starts = String(Number(document.documentElement.dataset.starts || 0) + 1);
        document.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.terminal = 'yes'; }, {once:true});
        requestAnimationFrame(() => {
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = '#00ff00'; ctx.fillRect(0, 0, 8, 8);
            card.querySelector('.indicator').textContent = 'drawn';
        });
        </script>
        """
        let state = IslandFixtureState(source: open)
        let window = try host(IslandFixture(state: state))
        defer { window.isHidden = true }
        try await eventually("desktop canvas island mounts a web view") { self.find(WKWebView.self, in: window) != nil }
        let web = try XCTUnwrap(find(WKWebView.self, in: window))
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Desktop island navigation never finished") }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard try await observeIsland(web, "open outer DIV does not activate a closed inline script", condition: """
        const card = document.querySelector('.desktop-stage');
        if (!card?.querySelector('script') || !card.querySelector('canvas')) return false;
        if (document.documentElement.dataset.starts) throw new Error('script started before closing outer DIV');
        return card.querySelector('.indicator').textContent === 'waiting';
        """) else { return }

        state.source += "</div>"
        guard try await observeIsland(web, "complete idle island can find its own outer container and paint", condition: """
        const card = document.querySelector('.desktop-stage'), canvas = card?.querySelector('canvas');
        if (!canvas || card.querySelector('.indicator').textContent !== 'drawn') return false;
        if (document.documentElement.dataset.starts !== '1') throw new Error('early script should run once');
        if (canvas.getContext('2d').getImageData(0, 0, 1, 1).data[1] !== 255) throw new Error('canvas never painted');
        window.__fixtureCard = card; window.__fixtureCanvas = canvas;
        return true;
        """) else { return }
        state.source += "\n\n~~~swift\nlet x = 1\n~~~"
        state.streaming = false
        _ = try await observeIsland(web, "canonical final still owns the original painted canvas", condition: """
        if (document.documentElement.dataset.terminal !== 'yes') return false;
        const card = document.querySelector('.desktop-stage'), canvas = card?.querySelector('canvas');
        if (card !== window.__fixtureCard || canvas !== window.__fixtureCanvas || document.documentElement.dataset.starts !== '1')
            throw new Error('canonical pass replaced or reinitialised the mounted island');
        return canvas.getContext('2d').getImageData(0, 0, 1, 1).data[1] === 255;
        """)
    }

    @MainActor private func renderFixtureImage(_ url: URL, using store: RemoteImageStore, owner: TopicMediaScope? = nil, stickers: StickerContext = .init()) async throws {
        let handler = IslandImageScheme(store: store)
        handler.stickers = stickers
        handler.mediaEnabled = true
        handler.owner = owner
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.removeAllUserScripts()
        configuration.setURLSchemeHandler(handler, forURLScheme: IslandImageScheme.name)
        let web = WKWebView(frame: .zero, configuration: configuration)
        let window = try host(SchemeImageFixture(view: web))
        defer { web.stopLoading(); handler.invalidate(); window.isHidden = true }

        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = try XCTUnwrap(url.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved))
        let image = "<img id=\"fixture\" src=\"\(IslandImageScheme.name)://asset?\(encoded)\" onload=\"this.dataset.loaded='yes'\" onerror=\"this.dataset.failed='yes'\">"
        let html = HTMLIslandPolicy.document(image, motion: false, media: true, dark: false)
        web.loadHTMLString(html, baseURL: nil)
        let clock = ContinuousClock(), deadline = clock.now + .seconds(60)
        while web.isLoading || web.url == nil {
            guard clock.now < deadline else { return XCTFail("Image scheme fixture navigation never finished") }
            try await Task.sleep(for: .milliseconds(200))
        }
        _ = try await observeIsland(web, "WKWebView decodes the image supplied by the persistent store", condition: """
        const img = document.getElementById('fixture');
        if (img?.dataset.failed === 'yes') throw new Error('WebKit image load failed');
        return img?.dataset.loaded === 'yes' && img.complete && img.naturalWidth > 0;
        """)
    }

    @MainActor func testHTMLImagesUseTheSamePersistentStoreAsNativeRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try XCTUnwrap(URL(string: "https://fixtures.invalid/img/card.png?size=2"))
        let origin = ImageOriginFixture(), payload = pixelPNG(.green)
        await origin.set(url, payload)
        let online = RemoteImageStore(directory: directory) { try await origin.get($0) }
        try await renderFixtureImage(url, using: online)
        let initialDownloads = await origin.count(url)
        XCTAssertEqual(initialDownloads, 1)

        let offline = ImageOriginFixture()
        let coldStore = RemoteImageStore(directory: directory) { try await offline.get($0) }
        try await renderFixtureImage(url, using: coldStore)
        let nativeBytes = try await coldStore.resource(url)
        XCTAssertEqual(nativeBytes.data, payload)
        let extraDownloads = await offline.count(url)
        XCTAssertEqual(extraDownloads, 0, "new ephemeral WebKit and native store must reload from disk while offline")
    }
}

@MainActor private final class MixedHeightProbe { var heights: [Int: CGFloat] = [:] }

@MainActor private final class KeyboardFixtureState: ObservableObject {
    @Published var draft = "草稿"
    let keyboard = ComposerKeyboard()
    var acceptsSend = true
    var sent: [String] = []

    func send() {
        guard acceptsSend, !draft.isEmpty else { return }
        sent.append(draft)
        draft = ""
        keyboard.didClearDraft()
    }
}

private struct KeyboardFixture: View {
    @ObservedObject var state: KeyboardFixtureState
    var enterSends = true
    var body: some View {
        NativeComposer(text: $state.draft, enterSends: enterSends, insertNewline: 0, keyboard: state.keyboard, onSend: state.send)
    }
}

// Use only synthetic image bytes and URLs. No server or Keychain configuration is needed.
@MainActor private func pixelPNG(_ color: UIColor) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
}

private actor ImageOriginFixture {
    private var requests: [URL:Int] = [:]
    private var replies: [URL:RemoteImageReply] = [:]
    func set(_ url: URL, _ data: Data, status: Int = 200, control: String = "") {
        replies[url] = RemoteImageReply(data: data, status: status, cacheControl: control)
    }
    func count(_ url: URL) -> Int { requests[url, default: 0] }
    func get(_ url: URL) async throws -> RemoteImageReply {
        requests[url, default: 0] += 1
        guard let reply = replies[url] else { throw URLError(.notConnectedToInternet) }
        // Ensure two simultaneous views can overlap before their first response arrives.
        try await Task.sleep(for: .milliseconds(100))
        return reply
    }
}


@MainActor private final class IslandFixtureState: ObservableObject {
    @Published var source: String
    @Published var streaming = true
    init(source: String) { self.source = source }
    init(image: Data) {
        source = """
        <div id="vcp-root"><img id="fixture-photo" alt="sticker" src="data:image/png;base64,\(image.base64EncodedString())"></div>
        <script>
        document.documentElement.dataset.fixtureStarts = String(1 + Number(document.documentElement.dataset.fixtureStarts || 0));
        document.addEventListener('DOMContentLoaded', () => { document.documentElement.dataset.fixtureTerminal = 'yes'; }, { once: true });
        </script>
        """
    }
}

private struct IslandFixture: View {
    @ObservedObject var state: IslandFixtureState
    var body: some View {
        RichMessageBody(state.source, streaming: state.streaming)
            .environment(\.scenePhase, .active)
    }
}


private struct SchemeImageFixture: UIViewRepresentable {
    let view: WKWebView
    func makeUIView(context: Context) -> WKWebView { view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// An advertised length exercises the preflight limit without allocating a large fixture.
private final class AtlasResponseFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "atlas.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(33 * 1024 * 1024)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// Deterministic deletion race; the fixture cannot complete until the test releases it.
private actor DelayedMediaOrigin {
    let bytes: Data
    private(set) var entered=false
    private var waiter: CheckedContinuation<Void,Never>?
    private var released = false
    init(bytes:Data) { self.bytes=bytes }
    func fetch() async -> RemoteImageReply {
        entered=true
        if !released { await withCheckedContinuation { waiter=$0 } }
        return RemoteImageReply(data:bytes,status:200,cacheControl:"public, max-age=0")
    }
    func release() { released=true; waiter?.resume();waiter=nil }
}

@MainActor private final class OffscreenIslandFixtureState: ObservableObject {
    @Published var offscreen=false
    @Published var incarnation=0
    let memory=TranscriptLayoutMemory()
    var heights: [Int:CGFloat]=[:]
}
private struct OffscreenIslandFixture: View {
    @ObservedObject var state: OffscreenIslandFixtureState
    private let source = #"<div id="vcp-root" style="height:414px">A large, stable offline card</div>"#
    var body: some View {
        let version=state.incarnation
        let viewport = state.offscreen ? CGRect(x:-10000,y:-10000,width:1,height:1) : CGRect(x:-1000,y:-1000,width:3000,height:3000)
        return ScrollView {
            HTMLIsland(source:source,options:.init())
                .environment(\.scenePhase,.active)
                .environment(\.messageViewport,viewport)
                .environment(\.messageLayoutMemory,state.memory)
                .environment(\.renderedMessageID,"fixture-message")
                .frame(width:248)
                .onGeometryChange(for:CGFloat.self,of:{ $0.size.height }) { height in state.heights[version]=height }
                .id(version)
        }.coordinateSpace(name:"vcp-message-viewport")
    }
}

@MainActor private final class NearbyCardFixture: ObservableObject {
    let buffer = TranscriptRenderBuffer()
    let memory = TranscriptLayoutMemory()
    let source = #"<div id="vcp-root"><details id="nearby-details"><summary>详情</summary>已展开</details><script>let n=0;function tick(){document.body.dataset.frames=String(++n);requestAnimationFrame(tick)}requestAnimationFrame(tick)</script></div>"#
    @Published var showRow = false
    @Published var enabled = true
}
private struct NearbyCardViews: View {
    @ObservedObject var state: NearbyCardFixture
    var body: some View {
        ZStack {
            TranscriptPreloader(items:state.enabled ? [.init(id:"nearby",source:state.source,role:"assistant",depth:0,rules:[],streaming:false)] : [],
                                options:.init(),buffer:state.buffer,width:280,memory:state.memory)
            if state.showRow {
                RichMessageBody(state.source,transcriptRow:true)
                    .environment(\.renderedMessageID,"nearby")
                    .environment(\.messageLayoutMemory,state.memory)
                    .frame(width:280)
            }
        }
        .environment(\.transcriptRenderBuffer,state.buffer)
        .environment(\.scenePhase,.active)
    }
}

private final class CompletedReplyFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "POST", request.url?.path == "/v1/chatvcp/completions",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture",
              request.value(forHTTPHeaderField: "Accept") == "application/json" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"回复"#.utf8))
        client?.urlProtocol(self, didLoad: Data(#"正文","reasoning_content":"思路"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension PhoneInteractionTests {
    @MainActor func testBackgroundReplySurvivesLeaseExpiryAndCommitsExactlyOnce() async throws {
        let (root, db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let topic = try await addMediaTopic(db)
        let user = StoredMessage(topicID: topic.id, role: "user", content: "test", status: "pending")
        let answer = StoredMessage(topicID: topic.id, role: "assistant", content: "原文", reasoning: "已有", status: "connecting")
        try await db.enqueue(user); try await db.save(answer)
        let room = ChatRoom(id: topic.id, messages: [user, answer])
        let model = ChatViewModel()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompletedReplyFixture.self]
        model.replyTransfers = BackgroundReplyTransfers(configuration: config)
        model.store = db; model.rooms[room.id] = room; room.busy = true; room.receivesInBackground = true
        try await model.restoreBackgroundReplies(store: db, root: root)

        let request = ChatRequest(configuration: .init(server: "https://fixture.invalid", model: "test", endpointMode: .vcpTools),
            apiKey: "fixture", messages: [.init(role: "user", content: "test")], contextTokenLimit: 100, maxOutputTokens: 12)
        let job = BackgroundReplyJob(messageID: answer.id, topicID: topic.id, userID: user.id)
        let ticket = try await model.replyTransfers.submit(job, request: request, room: room, store: db)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ticket.directory.appendingPathComponent("post"))) as? [String: Any])
        XCTAssertEqual(payload["stream"] as? Bool, false); XCTAssertEqual(payload["contextTokenLimit"] as? Int, 100)
        XCTAssertEqual(payload["max_tokens"] as? Int, 12)
        await model.interruptForBackground()
        XCTAssertFalse(room.cancelled)
        await model.collectBackgroundReply(job, ticket: ticket, room: room, store: db)
        XCTAssertEqual(room.messages.last?.text, "原文回复正文"); XCTAssertEqual(room.messages.last?.reasoning, "已有思路")
        XCTAssertEqual(room.messages.first?.status, "complete")
        let duplicate = try await db.finishBackgroundReply(job, reply: nil)
        let pending = try await db.pending()
        XCTAssertNil(duplicate); XCTAssertEqual(pending, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ticket.directory.path))
    }

    @MainActor func testStoppedTransferCannotCompleteRegeneratedMessage() async throws {
        let (root, db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = StoredMessage(topicID: "topic", role: "user", content: "我", status: "pending")
        let answer = StoredMessage(topicID: user.topicID, role: "assistant", content: "原文", status: "connecting")
        try await db.enqueue(user); try await db.save(answer)
        let old = BackgroundReplyJob(messageID: answer.id, topicID: user.topicID, userID: user.id)
        try await db.registerBackgroundReply(old)
        let stopped = try await db.finishBackgroundReply(old, reply: nil, stopped: true)
        XCTAssertEqual(stopped?.status, "stopped"); XCTAssertEqual(stopped?.content, "原文")
        let next = BackgroundReplyJob(messageID: answer.id, topicID: user.topicID, userID: user.id)
        try await db.registerBackgroundReply(next)
        let late = try FinishedReply(data: Data(#"{"choices":[{"message":{"content":"过期结果"}}]}"#.utf8))
        let ignored = try await db.finishBackgroundReply(old, reply: late)
        let pending = try await db.pending(), jobs = try await db.backgroundReplies()
        XCTAssertNil(ignored); XCTAssertEqual(pending, 1); XCTAssertEqual(jobs.map(\.id), [next.id])
    }

    @MainActor func testRelaunchCollectsDurableReceiptAndInterruptsMissingTransfer() async throws {
        let (root, db) = try await makeMediaDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let received = StoredMessage(topicID: "topic a/🪴", role: "assistant", content: "", status: "connecting")
        let orphan = StoredMessage(topicID: "another", role: "assistant", content: "保留", status: "connecting")
        let stream = StoredMessage(topicID: "stream", role: "assistant", content: "流", status: "streaming")
        for message in [received, orphan, stream] { try await db.save(message) }
        let job = BackgroundReplyJob(messageID: received.id, topicID: received.topicID, userID: nil)
        try await db.registerBackgroundReply(job)
        try await db.registerBackgroundReply(.init(messageID: orphan.id, topicID: orphan.topicID, userID: nil))
        let dir = root.appendingPathComponent("ReplyTransfers").appendingPathComponent(job.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"choices":[{"message":{"content":"完成"}}]}"#.utf8).write(to: dir.appendingPathComponent("response"))
        try JSONEncoder().encode(BackgroundReplyTransfers.Receipt()).write(to: dir.appendingPathComponent("receipt"))
        try await db.recoverInterrupted()
        let previous = try await db.messages(topicID: received.topicID)
        XCTAssertEqual(previous.first?.status, "connecting")
        let model = ChatViewModel(); model.replyTransfers = BackgroundReplyTransfers(configuration: .ephemeral)
        try await model.restoreBackgroundReplies(store: db, root: root)
        for room in Array(model.rooms.values) { await room.generation?.value }
        let all = try await db.messages()
        XCTAssertEqual(all.first { $0.id == received.id }?.content, "完成")
        XCTAssertEqual(all.first { $0.id == orphan.id }?.status, "interrupted")
        XCTAssertEqual(all.first { $0.id == orphan.id }?.content, "保留")
        XCTAssertEqual(all.first { $0.id == stream.id }?.status, "interrupted")
        let outstanding = try await db.backgroundReplies()
        XCTAssertTrue(outstanding.isEmpty)

        let link = try XCTUnwrap(ReplyActivityAttributes(jobID: job.id, topicID: job.topicID, started: Date()).url)
        XCTAssertEqual(ReplyActivityAttributes.topic(in: link), received.topicID)
        let notification = ReplyPresentation.notification(for: job)
        XCTAssertEqual(notification.content.userInfo["topicID"] as? String, received.topicID)
        XCTAssertEqual(notification.identifier, job.id); XCTAssertEqual(notification.content.threadIdentifier, received.topicID)
        XCTAssertEqual(notification.content.body, "轻点查看这条回复。")
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        XCTAssertNotNil(Bundle(url: plugins.appendingPathComponent("ReplyActivity.appex")))
    }
}
