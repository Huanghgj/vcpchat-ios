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
    static func end(_ id: String, phase: ReplyActivityAttributes.ContentState.Phase) async {
        for activity in Activity<ReplyActivityAttributes>.activities where activity.attributes.jobID == id {
            await activity.end(ActivityContent(state: .init(phase: phase), staleDate: nil),
                               dismissalPolicy: phase == .stopped ? .immediate : .after(Date().addingTimeInterval(15)))
        }
    }
    static func notify(_ job: BackgroundReplyJob) async {
        guard UIApplication.shared.applicationState != .active else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus),
              UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "AI 回复已收到"; content.body = "轻点查看这条回复。"
        content.sound = .default; content.threadIdentifier = job.topicID; content.userInfo = ["topicID": job.topicID]
        try? await center.add(UNNotificationRequest(identifier: job.id, content: content, trigger: nil))
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
