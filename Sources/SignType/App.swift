import AppKit
import SwiftUI

@main
struct SignTypeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let controller = SessionController()
    private var hotkey: FnTripleTapMonitor?
    private var hotkeyRetry: Timer?
    private var teachWindow: NSWindow?
    private var teachModel: TeachModel?
    private var settingsWindow: NSWindow?

    private var toggleItem: NSMenuItem!
    private var modeItems: [Mode: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        controller.onActivityChange = { [weak self] _ in self?.refreshMenu() }

        // Accessibility covers both the global fn-key tap and typing into other apps.
        if !Permissions.accessibilityTrusted { Permissions.requestAccessibility() }

        hotkey = FnTripleTapMonitor { [weak self] in self?.controller.toggle() }
        if hotkey?.start() != true {
            // Accessibility not granted yet – keep retrying until the user flips the switch.
            hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                if self?.hotkey?.start() == true {
                    t.invalidate()
                    self?.refreshMenu()
                }
            }
        }
        if Permissions.cameraStatus == .notDetermined {
            Permissions.requestCamera { _ in }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        controller.knn.save()
    }

    // MARK: Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "hand.raised.fingers.spread", accessibilityDescription: "SignType") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "🤟"
            }
        }
        let menu = NSMenu()
        menu.autoenablesItems = false

        toggleItem = NSMenuItem(title: "Start signing", action: #selector(toggleSigning), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let hint = NSMenuItem(title: "Tap fn (🌐) three times from any app", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        for mode in Mode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            modeItems[mode] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let teach = NSMenuItem(title: "Teach letters…", action: #selector(openTeach), keyEquivalent: "t")
        teach.target = self
        menu.addItem(teach)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let version = NSMenuItem(title: "Build \(build)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let quit = NSMenuItem(title: "Quit SignType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        refreshMenu()
    }

    private func refreshMenu() {
        switch controller.activity {
        case .idle: toggleItem.title = "Start signing"
        case .signing: toggleItem.title = "Stop signing"
        case .teaching: toggleItem.title = "Teaching… (close the teach window to stop)"
        case .processing: toggleItem.title = "Processing…"
        }
        toggleItem.isEnabled = controller.activity == .idle || controller.activity == .signing
        for (mode, item) in modeItems {
            item.state = mode == controller.settings.mode ? .on : .off
        }
        if let button = statusItem.button {
            let name = controller.activity == .idle ? "hand.raised.fingers.spread" : "hand.raised.fingers.spread.fill"
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "SignType") {
                img.isTemplate = true
                button.image = img
            }
            button.contentTintColor = controller.activity == .signing ? .systemGreen : nil
        }
        if hotkey?.isRunning != true {
            toggleItem.title += "  (fn hotkey needs Accessibility)"
        }
    }

    @objc private func toggleSigning() {
        controller.toggle()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Mode(rawValue: raw) else { return }
        controller.settings.mode = mode
        refreshMenu()
    }

    // MARK: Windows

    @objc private func openTeach() {
        if let w = teachWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard controller.activity == .idle else {
            SessionController.alert("Busy", "Stop signing first, then open the teach window.")
            return
        }
        let model = TeachModel(controller: controller)
        teachModel = model
        controller.onFeatures = { [weak model] f, p in model?.ingest(features: f, prediction: p) }
        controller.onSegment = { [weak model] s in model?.ingest(segment: s) }

        let w = NSWindow(contentViewController: NSHostingController(rootView: TeachView(model: model)))
        w.title = "Teach SignType"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        teachWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        controller.startTeaching()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: controller.settings)))
            w.title = "SignType Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === teachWindow {
            controller.stopTeaching()
            controller.onFeatures = nil
            controller.onSegment = nil
            teachWindow = nil
            teachModel = nil
        } else if w === settingsWindow {
            refreshMenu()
        }
    }
}
