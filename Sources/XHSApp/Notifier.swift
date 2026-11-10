import AppKit
import UserNotifications
import XHSCore

/// Mac notifications for panes out of view. The first one asks the owner's permission. Refused, none shows;
/// the ring and the count do not depend on it. A smoke never comes here.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Alerts for the banner, and the badge for the Dock count (D23). macOS shows an app's Dock badge only
    /// when the app asked for badges and the owner left "Badge application icon" on (System Settings,
    /// Notifications, Xyntetik Dojo). The app asked for alerts alone until 2026-11-10, so its count never
    /// showed in the Dock though `dockTile.badgeLabel` was set.
    static let options: UNAuthorizationOptions = [.alert, .badge]

    /// Called with the pane's name when the owner clicks a notification.
    var onOpen: ((String) -> Void)?
    /// Where the app records what macOS allows it (~/.dojo/notifications), so a missing badge or banner
    /// can be told apart from a bug: overwritten at launch and after each request.
    private let record: URL

    init(record: URL) {
        self.record = record
        super.init()
        UNUserNotificationCenter.current().delegate = self
        // Reading the settings never asks the owner anything; only a request can, and macOS asks once.
        recordSettings()
    }

    func post(pane: String, _ attention: Attention) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: Notifier.options) { [weak self] granted, _ in
            self?.recordSettings()
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = pane
            content.body = attention == .prompt ? "needs you" : "finished"
            content.userInfo = ["pane": pane]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// One line each: whether notifications are allowed, then alerts and badges (enabled, disabled, or
    /// notSupported when the app never asked for them), then what the app asks for.
    func recordSettings() {
        let file = record
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            func word(_ s: UNNotificationSetting) -> String {
                switch s {
                case .enabled: return "enabled"
                case .disabled: return "disabled"
                case .notSupported: return "notSupported"
                @unknown default: return "unknown"
                }
            }
            let authorization: String
            switch settings.authorizationStatus {
            case .authorized: authorization = "authorized"
            case .denied: authorization = "denied"
            case .notDetermined: authorization = "notDetermined"
            case .provisional: authorization = "provisional"
            case .ephemeral: authorization = "ephemeral"
            @unknown default: authorization = "unknown"
            }
            var asks: [String] = []
            if Notifier.options.contains(.alert) { asks.append("alert") }
            if Notifier.options.contains(.badge) { asks.append("badge") }
            let text = "checked \(ISO8601DateFormatter().string(from: Date()))\n"
                + "authorization \(authorization)\n"
                + "alerts \(word(settings.alertSetting))\n"
                + "badges \(word(settings.badgeSetting))\n"
                + "asks for \(asks.joined(separator: ", "))\n"
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
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
