import AppKit
import SwiftUI
import WatcherCore

/// The dot in the menu bar, and the panel it opens.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let monitor: Monitor
    private let windows: Windows

    init(monitor: Monitor, windows: Windows) {
        self.monitor = monitor
        self.windows = windows
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle)
        update()
        observe()
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // The panel exists only while open, so its once-a-second redraw
            // costs nothing the rest of the time.
            popover.contentViewController = NSHostingController(
                rootView: PanelView(monitor: monitor, windows: windows, close: { [weak self] in self?.popover.performClose(nil) }))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    private func observe() {
        withObservationTracking {
            _ = monitor.assessment
        } onChange: {
            Task { @MainActor [weak self] in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        item.button?.image = Dot.image(for: monitor.assessment.light)
        item.button?.toolTip = monitor.assessment.headline
    }
}

enum Dot {
    static func color(_ light: Light) -> NSColor {
        switch light {
        case .gray: .systemGray
        case .green: .systemGreen
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .red: .systemRed
        }
    }

    static func image(for light: Light) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            if light == .gray {
                // Hollow: not connected is not the same as the internet failing.
                color(light).setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
            } else {
                color(light).setFill()
                circle.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
