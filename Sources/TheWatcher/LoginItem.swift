import AppKit
import ServiceManagement

enum LoginItem {
    private static let setUpKey = "loginItemSetUp"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("TheWatcher: login item change failed: \(error.localizedDescription)")
        }
    }

    /// Asks once, the first time the installed app launches. A copy run from
    /// the build folder never asks or registers itself.
    @MainActor
    static func askOnFirstLaunch() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: setUpKey) else { return }
        UserDefaults.standard.set(true, forKey: setUpKey)
        let alert = NSAlert()
        alert.messageText = "Open TheWatcher when you log in?"
        alert.informativeText = "You can change this later in Settings."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { set(true) }
    }
}
