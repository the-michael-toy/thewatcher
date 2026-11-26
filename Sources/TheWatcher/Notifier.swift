import Foundation
import UserNotifications
import WatcherCore

enum Settings {
    static let notifyOnRecoveryKey = "notifyOnRecovery"

    static var notifyOnRecovery: Bool {
        UserDefaults.standard.object(forKey: notifyOnRecoveryKey) as? Bool ?? true
    }
}

enum Notifier {
    static func prepare() {
        guard Settings.notifyOnRecovery else { return }
        requestPermission()
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func outageEnded(_ outage: Outage) {
        guard Settings.notifyOnRecovery, let end = outage.end else { return }
        let content = UNMutableNotificationContent()
        content.title = "The outage is over"
        content.body = "It lasted about \(Format.duration(outage.duration(asOf: end)))."
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
