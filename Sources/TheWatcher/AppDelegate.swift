import AppKit
import WatcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor!
    private var statusItem: StatusItemController!
    private let windows = Windows()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = try? HistoryStore()
        monitor = Monitor(store: store)
        statusItem = StatusItemController(monitor: monitor, windows: windows)
        windows.monitor = monitor

        Notifier.prepare()
        monitor.onOutageEnded = { Notifier.outageEnded($0) }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.pause() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.monitor.resume() }
        }
        monitor.start()
        DispatchQueue.main.async { LoginItem.askOnFirstLaunch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.pause()
    }
}
