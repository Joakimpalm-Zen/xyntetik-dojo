import AppKit
import UserNotifications
import XHSCore

/// Mac notifications for panes out of view. The first one asks the owner's permission. Refused, none shows;
/// the ring, the count and the Dock badge do not depend on it. A smoke never comes here.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the pane's name when the owner clicks a notification.
    var onOpen: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(pane: String, _ attention: Attention) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = pane
            content.body = attention == .prompt ? "needs you" : "finished"
            content.userInfo = ["pane": pane]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// A pane behind another tab notifies with the app in front as well.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let pane = response.notification.request.content.userInfo["pane"] as? String
        DispatchQueue.main.async { [weak self] in
            if let pane { self?.onOpen?(pane) }
            completionHandler()
        }
    }
}
