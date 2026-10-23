import ScreenCaptureKit
import AppKit

@MainActor
final class CaptureManager {
    private let windowController = EditorWindowController()
    private let regionSelector = RegionSelector()
    private let windowSelector = WindowSelector()
    private var countdownWindow: NSWindow?
    private var isCaptureInProgress = false

    // MARK: - Capture modes

    func captureScreen() {
        guard beginCapture() else { return }
        Task { @MainActor in
            defer { finishCapture() }
            do {
                let screen = NSScreen.main ?? NSScreen.screens.first
                let image = try await captureDisplay(matchingScreen: screen)
                windowController.showEditor(with: image)
            } catch {
                showError(error)
            }
        }
    }

    func captureRegion() {
        guard beginCapture() else { return }
        regionSelector.selectRegion { [weak self] screen, viewRect in
            guard let self else { return }
            guard let viewRect else {
                self.finishCapture()
                return
            }
            Task { @MainActor in
                defer { self.finishCapture() }
                do {
                    try await Task.sleep(nanoseconds: 150_000_000)
                    let image = try await self.captureDisplay(matchingScreen: screen)
                    let cropped = self.cropImage(image, toViewRect: viewRect, screen: screen)
                    self.windowController.showEditor(with: cropped)
                } catch {
                    self.showError(error)
                }
            }
        }
    }

    func captureRegionDelayed() {
        guard beginCapture() else { return }
        regionSelector.selectRegion { [weak self] screen, viewRect in
            guard let self else { return }
            guard let viewRect else {
                self.finishCapture()
                return
            }
            Task { @MainActor in
                defer { self.finishCapture() }
                do {
                    await self.showCountdown(from: 3)
                    let image = try await self.captureDisplay(matchingScreen: screen)
                    let cropped = self.cropImage(image, toViewRect: viewRect, screen: screen)
                    self.windowController.showEditor(with: cropped)
                } catch {
                    self.showError(error)
                }
            }
        }
    }

    func captureScreenDelayed() {
        guard beginCapture() else { return }
        Task { @MainActor in
            defer { finishCapture() }
            do {
                await showCountdown(from: 3)
                let screen = NSScreen.main ?? NSScreen.screens.first
                let image = try await captureDisplay(matchingScreen: screen)
                windowController.showEditor(with: image)
            } catch {
                showError(error)
            }
        }
    }

    func captureWindowInteractive() {
        guard beginCapture() else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            finishCapture()
            return
        }
        windowSelector.selectWindow(on: screen) { [weak self] scWindow in
            guard let self else { return }
            guard let scWindow else {
                self.finishCapture()
                return
            }
            Task { @MainActor in
                defer { self.finishCapture() }
                do {
                    // Brief pause so the selector overlay is fully off screen before capture
                    try await Task.sleep(nanoseconds: 150_000_000)
                    let image = try await self.captureWindowImage(scWindow)
                    self.windowController.showEditor(with: image)
                } catch {
                    self.showError(error)
                }
            }
        }
    }

    // MARK: - Helpers

    private func beginCapture() -> Bool {
        guard !isCaptureInProgress else {
            NSSound.beep()
            return false
        }
        isCaptureInProgress = true
        return true
    }

    private func finishCapture() {
        isCaptureInProgress = false
    }

    private func screenUnderCursor() -> NSScreen? {
        let pt = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pt, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Countdown

    private func showCountdown(from seconds: Int) async {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size: CGFloat = 90
        let win = NSWindow(
            contentRect: NSRect(
                x: screen.frame.maxX - size - 24,
                y: screen.frame.maxY - size - 24,
                width: size, height: size
            ),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let cv = CountdownView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        win.contentView = cv
        win.orderFront(nil)
        countdownWindow = win

        for i in stride(from: seconds, through: 1, by: -1) {
            cv.count = i
            cv.needsDisplay = true
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        win.orderOut(nil)
        countdownWindow = nil
        // Short pause so the countdown window is fully off screen before the screenshot
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Window capture

    private func captureWindowImage(_ scWindow: SCWindow) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()

        let scale = NSScreen.screens
            .first(where: { screen in
                let primaryH = NSScreen.screens.first(where: { $0.frame.minY == 0 })?.frame.height ?? screen.frame.height
                let appKitFrame = CGRect(
                    x: scWindow.frame.minX,
                    y: primaryH - scWindow.frame.maxY,
                    width: scWindow.frame.width,
                    height: scWindow.frame.height
                )
                return screen.frame.intersects(appKitFrame)
            })?
            .backingScaleFactor ?? 2.0

        config.width  = Int(scWindow.frame.width  * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: config)
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: scWindow.frame.width, height: scWindow.frame.height))
    }

    // MARK: - Shared helpers

    // viewRect is in AppKit view coords (y=0 at bottom). Crop to CGImage pixel coords (y=0 at top).
    private func cropImage(_ image: NSImage, toViewRect rect: CGRect, screen: NSScreen) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let scaleX = CGFloat(cg.width)  / screen.frame.width
        let scaleY = CGFloat(cg.height) / screen.frame.height
        let cropRect = CGRect(
            x: rect.minX * scaleX,
            y: CGFloat(cg.height) - rect.maxY * scaleY,
            width:  rect.width  * scaleX,
            height: rect.height * scaleY
        )
        guard let cropped = cg.cropping(to: cropRect) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }

    private func captureDisplay(matchingScreen screen: NSScreen?) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        let displayID = screen.flatMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        } ?? CGMainDisplayID()

        let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first
        guard let display else { throw AppError.noDisplay }

        // Leave our own editor windows out, so an open screenshot never ends up in the next one.
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let config = SCStreamConfiguration()

        // Capture at the display's actual framebuffer resolution (the current
        // mode's pixelWidth/pixelHeight). This is exactly what ScreenCaptureKit
        // renders, so there is no resampling on either a Retina built-in display
        // or a scaled external one. SCDisplay.width/height report *points*, and
        // frame*backingScaleFactor can disagree under fractional "Looks like"
        // scaling — both produced the soft-on-one-screen bug.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let physW = mode?.pixelWidth  ?? display.width
        let physH = mode?.pixelHeight ?? display.height
        config.width  = physW
        config.height = physH
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let logW = screen?.frame.width  ?? CGFloat(physW)
        let logH = screen?.frame.height ?? CGFloat(physH)
        return NSImage(cgImage: cgImage, size: NSSize(width: logW, height: logH))
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        let nsErr = error as NSError
        let isPermission = nsErr.code == -3801
            || nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamError"

        if isPermission {
            alert.messageText = "Skärminspelning inte tillåten"
            alert.informativeText = "Öppna Systeminställningar › Sekretess och säkerhet › Skärm och systeminspelning och aktivera Grönskott."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Öppna Systeminställningar")
            alert.addButton(withTitle: "Avbryt")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            alert.messageText = "Skärmdump misslyckades"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    enum AppError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "Ingen skärm hittades." }
    }
}

// MARK: - Countdown view

private final class CountdownView: NSView {
    var count: Int = 3

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        // Semi-transparent circle
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.72))
        ctx.addEllipse(in: r.insetBy(dx: 4, dy: 4))
        ctx.fillPath()
        // Number
        let str = "\(count)" as NSString
        let font = NSFont.boldSystemFont(ofSize: r.width * 0.52)
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: font]
        let sz = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: (r.width - sz.width) / 2, y: (r.height - sz.height) / 2),
                 withAttributes: attrs)
    }
}
