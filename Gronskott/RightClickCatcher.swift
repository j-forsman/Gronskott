import SwiftUI

// Transparent overlay that only takes right-clicks (and ctrl-clicks); every other
// event falls through to the SwiftUI gestures underneath.
struct RightClickCatcher: NSViewRepresentable {
    var menuAt: (CGPoint) -> NSMenu?

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ view: CatcherView, context: Context) { view.menuAt = menuAt }

    final class CatcherView: NSView {
        var menuAt: ((CGPoint) -> NSMenu?)?

        override var isFlipped: Bool { true }   // y-down, same as SwiftUI

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let isContextClick = e.type == .rightMouseDown
                || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return isContextClick ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuAt?(convert(event.locationInWindow, from: nil))
        }
    }
}

// NSMenuItem that runs a closure, so menus can be built inline from SwiftUI state.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        self.image = image
    }

    required init(coder: NSCoder) {
        handler = {}
        super.init(coder: coder)
    }

    @objc private func fire() { handler() }
}
