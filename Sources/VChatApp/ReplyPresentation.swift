#if os(iOS)
import ActivityKit
import UIKit
import UserNotifications
import VChatCore

@MainActor enum ReplyPresentation {
    static let modeKey = "native.background-replies"
    static let islandKey = "native.reply-activity"

    static func start(_ job: BackgroundReplyJob) {
        guard UserDefaults.standard.object(forKey: islandKey) as? Bool != false,
              ActivityAuthorizationInfo().areActivitiesEnabled, UIApplication.shared.applicationState == .active else { return }
        let attributes = ReplyActivityAttributes(jobID: job.id, topicID: job.topicID, started: Date())
        _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: .init(phase: .waiting),
            staleDate: Date().addingTimeInterval(600)), pushType: nil)
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
        UNUserNotificationCenter.current().delegate = self
        return true
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
