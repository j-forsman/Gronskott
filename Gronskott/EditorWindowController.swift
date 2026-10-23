import AppKit
import SwiftUI

final class EditorWindowController: NSObject, NSWindowDelegate {
    private var windows: [NSWindow] = []

    func showEditor(with image: NSImage) {
        let window = createWindow(fitting: image.size)

        let view = EditorView(image: image)
        window.contentView = NSHostingView(rootView: view)
        window.title = "Grönskott"
        window.makeKeyAndOrderFront(nil)
        windows.append(window)

        NSApp.setActivationPolicy(.regular)

        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0 === window }
        if windows.isEmpty {
            // Dropping to .accessory while active lets macOS pick an arbitrary app
            // to activate, so the app you came from (e.g. the paste target) can
            // end up buried. hide() hands focus back to the previously active app.
            NSApp.hide(nil)
            NSApp.setActivationPolicy(.accessory)
            // Clear the hidden flag so later overlays/editor windows can show.
            DispatchQueue.main.async { NSApp.unhideWithoutActivation() }
        }
    }

    // Window hugs the screenshot at 1:1 (plus toolbars), capped to the screen.
    private func createWindow(fitting imageSize: NSSize) -> NSWindow {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let sf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let chrome = NSSize(width: 67 + 40, height: 70 + 40)   // left bar, top+status bars, margin
        let w = min(sf.width * 0.92, max(1000, imageSize.width + chrome.width))
        let h = min(sf.height * 0.92, max(620, imageSize.height + chrome.height))
        let offset = CGFloat(windows.count % 8) * 24
        let x = sf.origin.x + (sf.width - w) / 2 + offset
        let y = sf.origin.y + (sf.height - h) / 2 - offset

        let win = NSWindow(
            contentRect: NSRect(x: x, y: y, width: w, height: h),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Grönskott"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 640, height: 620)
        win.delegate = self
        return win
    }
}
