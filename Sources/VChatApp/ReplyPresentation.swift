#if os(iOS)
import ActivityKit
@preconcurrency import BackgroundTasks
import UIKit
import UserNotifications
import VChatCore

/// iOS 26 can keep an explicitly user-started streaming connection executing.
@MainActor enum ReplyRuntime {
    static let noticeKey = "native.last-reply-runtime-notice"
    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    @MainActor private final class Slot {
        let identifier: String
        var job: String?, task: BGContinuedProcessingTask?, expire: (() -> Void)?
        var bytes: Int = 0
        init(_ identifier: String) { self.identifier = identifier }
        func launched(_ task: BGTask) {
            guard let task = task as? BGContinuedProcessingTask, let job else {
                task.setTaskCompleted(success:false); return
            }
            self.task = task
            task.progress.totalUnitCount = -1 // no reliable model output length
            task.progress.completedUnitCount = Int64(bytes)
            task.expirationHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.job == job else { return }
                    let stop = self.expire
                    self.complete(false); stop?()
                }
            }
        }
        func complete(_ success: Bool) {
            if let task {
                task.expirationHandler = nil
                if success { task.progress.totalUnitCount = Int64(max(1,bytes)); task.progress.completedUnitCount = task.progress.totalUnitCount }
                task.setTaskCompleted(success:success)
            } else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:identifier) }
            task = nil; job = nil; expire = nil; bytes = 0
        }
    }
    @available(iOS 26.0, *)
    private static let slots: [Slot] = {
        guard let declared = Bundle.main.object(forInfoDictionaryKey:"BGTaskSchedulerPermittedIdentifiers") as? [String] else { return [] }
        return declared.compactMap { id in
            let slot = Slot(id)
            guard BGTaskScheduler.shared.register(forTaskWithIdentifier:id,using:.main,launchHandler: { task in
                MainActor.assumeIsolated { slot.launched(task) }
            }) else { return nil }
            return slot
        }
    }()
    #endif
    static func begin(_ id: String, expire: @escaping @MainActor () -> Void) {
        #if compiler(>=6.2)
        if #available(iOS 26.0,*), UserDefaults.standard.object(forKey:ReplyPresentation.islandKey) as? Bool != false,
           UIApplication.shared.applicationState != .background, let slot = slots.first(where:{ $0.job == nil }) {
            let request = BGContinuedProcessingTaskRequest(identifier:slot.identifier,title:"VChat 正在回复",subtitle:"等待服务器输出")
            request.strategy = .fail
            slot.job = id; slot.expire = expire
            do {
                try BGTaskScheduler.shared.submit(request)
                UserDefaults.standard.removeObject(forKey: noticeKey)
            } catch {
                slot.job = nil; slot.expire = nil
                UserDefaults.standard.set("系统未批准上次回复持续后台运行。前台仍可实时接收，锁屏后可能暂停。", forKey:noticeKey)
            }
        }
        #endif
    }
    static func systemPresents(_ id: String) -> Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0,*) { return slots.contains { $0.job == id } }
        #endif
        return false
    }
    static func progress(_ id: String, bytes: Int) {
        #if compiler(>=6.2)
        if #available(iOS 26.0,*), let slot = slots.first(where:{ $0.job == id }), bytes > slot.bytes {
            slot.bytes = bytes
            slot.task?.progress.completedUnitCount = Int64(bytes)
            slot.task?.updateTitle("VChat 正在回复",subtitle:"已接收 " + ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file))
        }
        #endif
    }
    static func finish(_ id: String, success: Bool) {
        #if compiler(>=6.2)
        if #available(iOS 26.0,*) { slots.first(where:{ $0.job == id })?.complete(success) }
        #endif
    }
}

@MainActor enum ReplyPresentation {
    static let modeKey = "native.background-replies"
    static let islandKey = "native.reply-activity"

    static func start(id: String, topicID: String, receivedBytes: Int) {
        guard UserDefaults.standard.object(forKey: islandKey) as? Bool != false,
              ActivityAuthorizationInfo().areActivitiesEnabled, UIApplication.shared.applicationState != .background,
              !Activity<ReplyActivityAttributes>.activities.contains(where: { $0.attributes.jobID == id && $0.activityState == .active }) else { return }
        let attributes = ReplyActivityAttributes(jobID: id, topicID: topicID, started: Date())
        _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: .init(phase: .waiting, receivedBytes: receivedBytes),
            staleDate: Date().addingTimeInterval(600)), pushType: nil)
    }
    nonisolated static func update(id: String, receivedBytes: Int) async {
        for activity in Activity<ReplyActivityAttributes>.activities where activity.attributes.jobID == id && activity.activityState == .active {
            await activity.update(ActivityContent(state: .init(phase: .waiting, receivedBytes: receivedBytes),
                                                  staleDate: activity.attributes.started.addingTimeInterval(600)))
        }
    }
    nonisolated static func hideWaitingOnReturn(ids: Set<String>) async {
        for activity in Activity<ReplyActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    static func dismissOrphanedActivities(activeIDs: Set<String>) async {
        for activity in Activity<ReplyActivityAttributes>.activities where !activeIDs.contains(activity.attributes.jobID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    static func end(_ id: String, phase: ReplyActivityAttributes.ContentState.Phase) async {
        for activity in Activity<ReplyActivityAttributes>.activities where activity.attributes.jobID == id {
            await activity.end(ActivityContent(state: .init(phase: phase), staleDate: nil),
                               dismissalPolicy: phase == .stopped ? .immediate : .after(Date().addingTimeInterval(15)))
        }
    }
    // UNNotificationSettings itself isn't Sendable on the iOS 17/18 SDK.
    nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }
    static func notify(_ job: BackgroundReplyJob) async {
        guard UIApplication.shared.applicationState != .active else { return }
        let status = await authorizationStatus()
        guard [.authorized, .provisional, .ephemeral].contains(status),
              UIApplication.shared.applicationState != .active else { return }
        await enqueueNotification(for: job)
    }
    nonisolated private static func enqueueNotification(for job: BackgroundReplyJob) async {
        let request = notification(for: job)
        try? await UNUserNotificationCenter.current().add(request)
    }
    nonisolated static func notification(for job: BackgroundReplyJob) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "AI 回复已收到"; content.body = "轻点查看这条回复。"
        content.sound = .default; content.threadIdentifier = job.topicID; content.userInfo = ["topicID": job.topicID]
        return UNNotificationRequest(identifier: job.id, content: content, trigger: nil)
    }
}

@MainActor final class ReplyAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = ChatViewModel()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Scene-based apps do not get the legacy app-delegate foreground callbacks.
        NotificationCenter.default.addObserver(self, selector: #selector(leavingForeground),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(returningToForeground),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    @objc private func leavingForeground() {
        // Start while still foreground-eligible, only for outstanding user requests.
        for room in model.rooms.values where room.busy && room.receivesInBackground && !room.cancelled {
            if let id = room.backgroundJobID, !ReplyRuntime.systemPresents(room.replyRuntimeID ?? id) { ReplyPresentation.start(id: id, topicID: room.id, receivedBytes: room.receivedReplyBytes) }
        }
    }
    @objc private func returningToForeground() {
        let ids = Set(Activity<ReplyActivityAttributes>.activities.compactMap { $0.content.state.phase == .waiting ? $0.id : nil })
        Task { await ReplyPresentation.hideWaitingOnReturn(ids: ids) }
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundReplyTransfers.identifier else { completionHandler(); return }
        if application.applicationState == .background { model.backgrounded = true }
        model.replyTransfers.handleWake(completionHandler)
        Task { await model.load() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let topic = response.notification.request.content.userInfo["topicID"] as? String else { return }
        await MainActor.run { model.requestedReplyTopic = topic }
    }
}
#endif
