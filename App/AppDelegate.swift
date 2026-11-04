import AppKit
import StandUpCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        guard let id = NotificationService.token(for: notification.request) else { return [] }
        return await model.isCurrentReminder(id) ? [.banner, .list, .sound] : []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let id = NotificationService.token(for: response.notification.request) else { return }
        if let event = NotificationService.event(for: response.actionIdentifier, token: id) {
            await model.send(event)
        }
        // Clicking or dismissing the notification leaves the reminder available in the menu bar.
    }
}
