import AppKit
import ScreenCaptureKit

@MainActor
final class WindowSelector {
    private var overlayWindow: NSWindow?

    func selectWindow(on screen: NSScreen, completion: @escaping @MainActor (SCWindow?) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let windows = content.windows.filter {
                    $0.isOnScreen
                    && $0.frame.width > 60 && $0.frame.height > 60
                    && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                }
                self.showOverlay(windows: windows, on: screen, completion: completion)
            } catch {
                completion(nil)
            }
        }
    }

    private func showOverlay(windows: [SCWindow], on screen: NSScreen,
                              completion: @escaping @MainActor (SCWindow?) -> Void) {
        let win = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.acceptsMouseMovedEvents = true
        win.ignoresMouseEvents = false

        let view = WindowSelectorView(screen: screen, scWindows: windows) { [weak self] scWin in
            NSCursor.arrow.set()
            win.orderOut(nil)
            self?.overlayWindow = nil
            completion(scWin)
        }
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)
        self.overlayWindow = win
    }
}

private final class WindowSelectorView: NSView {
    private struct Entry { let scWindow: SCWindow; let localFrame: CGRect }
    private let entries: [Entry]
    private let completion: (SCWindow?) -> Void
    private var hoveredIndex: Int? = nil

    init(screen: NSScreen, scWindows: [SCWindow], completion: @escaping (SCWindow?) -> Void) {
        // CG coordinate space: y=0 at top of primary display, y increases down.
        // AppKit coordinate space: y=0 at bottom of primary display, y increases up.
        // The overlay view covers screen.frame (AppKit).
        // Primary screen is the one whose AppKit frame.minY == 0.
        let primaryH = NSScreen.screens.first(where: { $0.frame.minY == 0 })?.frame.height
            ?? screen.frame.height

        self.entries = scWindows.compactMap { w in
            let f = w.frame  // CG coords
            // Convert to AppKit coords (y-up, origin at primary screen bottom-left)
            let appKitY = primaryH - f.maxY
            let appKitFrame = CGRect(x: f.minX, y: appKitY, width: f.width, height: f.height)
            // Convert to local view coords (subtract screen.frame.origin)
            let localFrame = CGRect(
                x: appKitFrame.minX - screen.frame.minX,
                y: appKitFrame.minY - screen.frame.minY,
                width: appKitFrame.width,
                height: appKitFrame.height
            )
            // Skip windows outside this screen
            guard localFrame.intersects(CGRect(origin: .zero, size: screen.frame.size)) else {
                return nil
            }
            return Entry(scWindow: w, localFrame: localFrame)
        }

        self.completion = completion
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .cursorUpdate, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let idx = hoveredIndex, idx < entries.count else { return }

        let r = entries[idx].localFrame

        // Dim everything outside the hovered window
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.3))
        ctx.beginPath()
        ctx.addRect(bounds)
        ctx.addRect(r)
        ctx.fillPath(using: .evenOdd)

        // Blue highlight border
        ctx.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.47, blue: 0.96, alpha: 1))
        ctx.setLineWidth(3)
        let highlight = r.insetBy(dx: -3, dy: -3)
        ctx.addPath(CGPath(roundedRect: highlight, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()

        // Window title label
        if let title = entries[idx].scWindow.title, !title.isEmpty {
            drawLabel(title, near: r, in: ctx)
        }
    }

    private func drawLabel(_ text: String, near r: CGRect, in ctx: CGContext) {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let str = text as NSString
        let sz = str.size(withAttributes: attrs)
        let pad: CGFloat = 8
        let boxW = sz.width + pad * 2, boxH = sz.height + pad
        let boxX = max(4, min(r.midX - boxW / 2, bounds.maxX - boxW - 4))
        // Place label above or below window
        let boxY = r.minY > boxH + 8 ? r.minY - boxH - 8 : r.maxY + 8
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.76))
        ctx.addPath(CGPath(roundedRect: CGRect(x: boxX, y: boxY, width: boxW, height: boxH),
                           cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        str.draw(at: NSPoint(x: boxX + pad, y: boxY + pad / 2), withAttributes: attrs)
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        let pt = convert(event.locationInWindow, from: nil)
        // Pick frontmost (lowest index) window that contains the point
        let newIdx = entries.indices.first { entries[$0].localFrame.contains(pt) }
        if newIdx != hoveredIndex {
            hoveredIndex = newIdx
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let idx = hoveredIndex { completion(entries[idx].scWindow) }
        else { completion(nil) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil) }
        else { super.keyDown(with: event) }
    }
}
