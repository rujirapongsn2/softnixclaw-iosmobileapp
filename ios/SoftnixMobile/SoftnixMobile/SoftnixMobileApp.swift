import SwiftUI
import UserNotifications
import UIKit

@main
struct SoftnixMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(SoftnixTheme.blue)
                .onReceive(NotificationCenter.default.publisher(for: .softnixPushToken)) { note in
                    guard let data = note.object as? Data else { return }
                    Task { await session.registerPushToken(data) }
                }
                .onReceive(NotificationCenter.default.publisher(for: .softnixPushOpened)) { note in
                    guard let userInfo = note.userInfo else { return }
                    Task { await session.handlePush(userInfo: userInfo) }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .softnixPushToken, object: deviceToken)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        NotificationCenter.default.post(name: .softnixPushOpened,
                                        object: nil, userInfo: response.notification.request.content.userInfo)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}

extension Notification.Name {
    static let softnixPushToken = Notification.Name("ai.softnix.mobile.push-token")
    static let softnixPushOpened = Notification.Name("ai.softnix.mobile.push-opened")
}

enum SoftnixTheme {
    static let blue = Color(red: 0.08, green: 0.48, blue: 0.78)
    static let deepBlue = Color(red: 0.02, green: 0.20, blue: 0.38)
    static let background = Color(red: 0.95, green: 0.98, blue: 1.0)
    static let ink = Color(red: 0.08, green: 0.08, blue: 0.17)
}
