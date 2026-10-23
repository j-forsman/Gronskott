import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

@main
struct GronskottApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let captureManager = CaptureManager()
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var hotKeyHandler: EventHandlerRef?
    private var loginItem: NSMenuItem?
    private var quitKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenuBar()
        registerHotkeys()
        // ponytail: Cmd+Q normally quits the whole app, which is easy to hit by
        // accident since this is a menu-bar utility. Always swallow it here —
        // close the front window if there is one, otherwise do nothing. Quitting
        // for real requires the explicit "Avsluta Grönskott" menu item.
        quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "q" else { return event }
            NSApp.keyWindow?.performClose(nil)
            return nil
        }
    }

    private func registerHotkeys() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { (_, event, refcon) -> OSStatus in
            guard let event, let refcon else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let ptr = refcon
            Task { @MainActor in
                let delegate = Unmanaged<AppDelegate>.fromOpaque(ptr).takeUnretainedValue()
                switch hkID.id {
                case 1: delegate.captureManager.captureRegion()
                case 2: delegate.captureManager.captureScreen()
                default: break
                }
            }
            return noErr
        }, 1, &eventSpec, selfPtr, &hotKeyHandler)

        // ⌃⇧3 = region capture. Plain ⌃3 is commonly reserved by Mission Control Spaces.
        var ref1: EventHotKeyRef?
        let id1 = EventHotKeyID(signature: 0x534E4500, id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_3), UInt32(controlKey | shiftKey),
                            id1, GetEventDispatcherTarget(), 0, &ref1)
        hotKeyRefs.append(ref1)

        // ⌃⇧4 = full screen capture
        var ref2: EventHotKeyRef?
        let id2 = EventHotKeyID(signature: 0x534E4500, id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(controlKey | shiftKey),
                            id2, GetEventDispatcherTarget(), 0, &ref2)
        hotKeyRefs.append(ref2)
    }

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Grönskott")
            btn.toolTip = "Grönskott"
        }

        let menu = NSMenu()

        menu.addItem(menuItem("Ta skärmdump av region",       shortcut: "3", modifiers: [.control, .shift], action: #selector(takeRegion)))
        menu.addItem(menuItem("Ta skärmdump av hela skärmen", shortcut: "4", modifiers: [.control, .shift], action: #selector(takeFullScreen)))
        menu.addItem(menuItem("Ta skärmdump av fönster",      shortcut: "5", modifiers: [.control, .option], action: #selector(takeWindow)))

        menu.addItem(.separator())

        menu.addItem(menuItem("Region med 3s fördröjning",      shortcut: "", action: #selector(takeRegionDelayed)))
        menu.addItem(menuItem("Hela skärmen med 3s fördröjning", shortcut: "", action: #selector(takeFullScreenDelayed)))

        menu.addItem(.separator())

        let launchItem = menuItem("Starta med macOS", shortcut: "", action: #selector(toggleLoginItem))
        loginItem = launchItem
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Avsluta Grönskott",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem?.menu = menu
    }

    private func menuItem(_ title: String, shortcut: String,
                          modifiers: NSEvent.ModifierFlags = .command,
                          action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func takeRegion()            { captureManager.captureRegion() }
    @objc private func takeFullScreen()        { captureManager.captureScreen() }
    @objc private func takeWindow()            { captureManager.captureWindowInteractive() }
    @objc private func takeRegionDelayed()     { captureManager.captureRegionDelayed() }
    @objc private func takeFullScreenDelayed() { captureManager.captureScreenDelayed() }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Kunde inte ändra inställning"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // NSMenuDelegate — update checkmark each time menu opens
    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
