import AppKit

@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var completion: (@MainActor (NSScreen, CGRect?) -> Void)?
    private var eventMonitor: Any?
    private var didComplete = false

    fileprivate static let scopeCursor: NSCursor = {
        let dim: CGFloat = 29
        let mid = dim / 2
        let image = NSImage(size: NSSize(width: dim, height: dim), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineWidth(1)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
            ctx.move(to: CGPoint(x: 0, y: mid)); ctx.addLine(to: CGPoint(x: dim, y: mid))
            ctx.move(to: CGPoint(x: mid, y: 0)); ctx.addLine(to: CGPoint(x: mid, y: dim))
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 0.55))
            ctx.addArc(center: CGPoint(x: mid, y: mid), radius: 7,
                       startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: mid, y: mid))
    }()

    // Shows one overlay per screen. Completion returns the selected screen and a
    // rect in that screen's local AppKit coordinates.
    func selectRegion(completion: @escaping @MainActor (NSScreen, CGRect?) -> Void) {
        cancelSelection(notify: false)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        didComplete = false
        self.completion = completion

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelSelection()
                return nil
            }
            return event
        }

        for screen in screens {
            let win = RegionOverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            win.level = .screenSaver
            win.backgroundColor = .clear
            win.isOpaque = false
            win.hasShadow = false
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.acceptsMouseMovedEvents = true
            win.ignoresMouseEvents = false

            let view = RegionSelectorView(screen: screen) { [weak self] rect in
                self?.finish(screen: screen, rect: rect)
            }
            win.contentView = view
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
            windows.append(win)
        }

        NSApp.activate(ignoringOtherApps: true)

        let cursorScreen = screenUnderCursor() ?? NSScreen.main ?? screens[0]
        if let keyWindow = windows.first(where: { $0.frame == cursorScreen.frame }) {
            keyWindow.makeKeyAndOrderFront(nil)
        }
    }

    func cancelSelection() {
        cancelSelection(notify: true)
    }

    private func cancelSelection(notify: Bool) {
        guard !windows.isEmpty || completion != nil else { return }
        let screen = screenUnderCursor() ?? NSScreen.main ?? NSScreen.screens.first
        closeOverlays()
        let currentCompletion = completion
        completion = nil
        didComplete = true

        if notify, let screen, let currentCompletion {
            currentCompletion(screen, nil)
        }
    }

    private func finish(screen: NSScreen, rect: CGRect?) {
        guard !didComplete else { return }
        didComplete = true
        closeOverlays()
        let currentCompletion = completion
        completion = nil
        currentCompletion?(screen, rect)
    }

    private func closeOverlays() {
        NSCursor.arrow.set()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func screenUnderCursor() -> NSScreen? {
        let pt = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pt, $0.frame, false) })
    }
}

private final class RegionOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class RegionSelectorView: NSView {
    private let screen: NSScreen
    private let completion: (CGRect?) -> Void
    private var startPt: CGPoint?
    private var curPt: CGPoint?

    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.screen = screen
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

    override func cursorUpdate(with event: NSEvent) {
        RegionSelector.scopeCursor.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = startPt, let c = curPt else { return }
        let sel = selectionRect(from: s, to: c)
        guard sel.width > 1, sel.height > 1,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(CGColor(gray: 1, alpha: 0.06))
        ctx.fill(sel)

        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.8))
        ctx.stroke(sel)
        ctx.setLineWidth(0.5)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        ctx.stroke(sel.insetBy(dx: 1, dy: 1))

        drawCursorLabel(at: c, width: sel.width, height: sel.height, in: ctx)
    }

    private func drawCursorLabel(at pt: CGPoint, width: CGFloat, height: CGFloat, in ctx: CGContext) {
        let scale = screen.backingScaleFactor

        let wStr = "\(Int(width * scale))" as NSString
        let hStr = "\(Int(height * scale))" as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: font]
        let wSz = wStr.size(withAttributes: attrs)
        let hSz = hStr.size(withAttributes: attrs)
        let boxW = max(wSz.width, hSz.width) + 10
        let boxH = wSz.height + hSz.height + 8

        let offset: CGFloat = 14
        var bx = pt.x + offset
        var by = pt.y - boxH - offset
        if bx + boxW > bounds.maxX - 4 { bx = pt.x - boxW - offset }
        if by < 4 { by = pt.y + offset }

        ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
        ctx.addPath(CGPath(roundedRect: CGRect(x: bx, y: by, width: boxW, height: boxH),
                           cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()

        let wOrigin = CGPoint(x: bx + (boxW - wSz.width) / 2, y: by + boxH - wSz.height - 4)
        let hOrigin = CGPoint(x: bx + (boxW - hSz.width) / 2, y: wOrigin.y - hSz.height - 2)
        wStr.draw(at: wOrigin, withAttributes: attrs)
        hStr.draw(at: hOrigin, withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil) }
        else { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        RegionSelector.scopeCursor.set()
        startPt = localPoint(from: event)
        curPt = startPt
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        RegionSelector.scopeCursor.set()
        curPt = localPoint(from: event)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        RegionSelector.scopeCursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = startPt else { return }
        let c = localPoint(from: event)
        let sel = selectionRect(from: s, to: c)
        guard sel.width > 5, sel.height > 5 else { completion(nil); return }
        completion(sel)
    }

    private func localPoint(from event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func selectionRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
