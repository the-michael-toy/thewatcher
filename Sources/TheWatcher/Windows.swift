import AppKit
import SwiftUI
import WatcherCore

/// Opens and reuses the More Details and Settings windows.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    var monitor: Monitor?
    private var details: NSWindow?
    private var settings: NSWindow?

    func showDetails() {
        guard let monitor else { return }
        details = present(details, title: "TheWatcher — History", size: NSSize(width: 820, height: 720)) {
            DetailsView(monitor: monitor)
        }
    }

    func showSettings() {
        guard let monitor else { return }
        settings = present(settings, title: "TheWatcher Settings", size: NSSize(width: 460, height: 400)) {
            SettingsView(monitor: monitor)
        }
    }

    /// A closed window is released along with its views; it's rebuilt when reopened.
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === details { details = nil }
        if closing === settings { settings = nil }
    }

    private func present<V: View>(_ existing: NSWindow?, title: String, size: NSSize, content: () -> V) -> NSWindow {
        let window = existing ?? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: content())
            w.setContentSize(size)
            w.center()
            return w
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
