import AppKit
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var editors: [EditorWindowController] = []
    private var loginItem: NSMenuItem?
    private var settings: SettingsWindowController?
    private var history: HistoryWindowController?

    private var shortcut = Shortcut.load()
    private var hotkeyActive = false
    private var statusCaptureItem: NSMenuItem?
    private var mainCaptureItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = buildMainMenu()
        setupStatusItem()

        History.migrateLegacyFolder()
        let permission = CGPreflightScreenCaptureAccess()
        Log.write("launch \(Bundle.main.bundlePath) screenRecording=\(permission)")

        Capturer.onPermissionMissing = { [weak self] in
            Log.write("capture blocked: Screen Recording permission missing")
            self?.showSettings()
            self?.settings?.warnPermissionMissing()
        }

        let args = CommandLine.arguments
        if args.contains("--enable-login-item") { try? LoginItem.set(true) }

        registerHotkey()

        // Ask for Screen Recording permission up front, and show the settings window
        // on first launch or when the permission is missing.
        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched")
        UserDefaults.standard.set(true, forKey: "hasLaunched")
        if !permission {
            CGRequestScreenCaptureAccess()
            showSettings()
        } else if firstLaunch {
            showSettings()
        }

        // Developer/testing hook: Snapshot --open /path/to/image.png
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            openEditor(url: URL(fileURLWithPath: args[i + 1]), historyURL: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openEditor(url: url, historyURL: nil) }
    }

    // MARK: Hotkey

    private func registerHotkey() {
        let status = HotKey.register(id: 1, keyCode: Int(shortcut.keyCode), modifiers: shortcut.carbonModifiers) { [weak self] in
            Log.write("hotkey pressed")
            self?.captureArea(nil)
        }
        hotkeyActive = status == noErr
        Log.write("hotkey \(shortcut.displayString) registered=\(hotkeyActive) status=\(status)")
        updateShortcutDisplays()
    }

    private func updateShortcutDisplays() {
        for item in [statusCaptureItem, mainCaptureItem].compactMap({ $0 }) {
            if let key = shortcut.menuKeyEquivalent {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = shortcut.modifiers
                item.title = "Capture Area"
            } else {
                item.keyEquivalent = ""
                item.title = "Capture Area (\(shortcut.displayString))"
            }
        }
        statusItem?.button?.toolTip = "Snapshot – \(shortcut.displayString) to capture an area"
        settings?.refresh()
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapshot")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self

        let area = NSMenuItem(title: "Capture Area", action: #selector(captureArea(_:)), keyEquivalent: "")
        menu.addItem(area)
        statusCaptureItem = area
        menu.addItem(NSMenuItem(title: "Capture Window", action: #selector(captureWindow(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Capture Full Screen", action: #selector(captureScreen(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "History…", action: #selector(showHistory(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Screenshots Folder", action: #selector(openScreenshotsFolder(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Image…", action: #selector(openImage(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit Image from Clipboard", action: #selector(openClipboard(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        menu.addItem(login)
        loginItem = login
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Snapshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = LoginItem.isEnabled ? .on : .off
    }

    // MARK: Main menu (visible while a window is open)

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        let app = submenu("Snapshot")
        app.addItem(withTitle: "About Snapshot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Snapshot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Snapshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("File")
        let cap = file.addItem(withTitle: "Capture Area", action: #selector(captureArea(_:)), keyEquivalent: "")
        cap.target = self
        mainCaptureItem = cap
        file.addItem(withTitle: "Open…", action: #selector(openImage(_:)), keyEquivalent: "o").target = self
        file.addItem(withTitle: "History…", action: #selector(showHistory(_:)), keyEquivalent: "y").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveNow(_:)), keyEquivalent: "s")
        let export = file.addItem(withTitle: "Export As…", action: #selector(EditorWindowController.saveImage(_:)), keyEquivalent: "s")
        export.keyEquivalentModifierMask = [.command, .shift]
        let reveal = file.addItem(withTitle: "Show in Finder", action: #selector(EditorWindowController.revealInFinder(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Open Screenshots Folder", action: #selector(openScreenshotsFolder(_:)), keyEquivalent: "").target = self
        let copyClose = file.addItem(withTitle: "Copy and Close", action: #selector(EditorWindowController.copyAndClose(_:)), keyEquivalent: "\r")
        copyClose.keyEquivalentModifierMask = [.command]
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: #selector(CanvasView.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(CanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(CanvasView.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let view = submenu("View")
        view.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(EditorWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(EditorWindowController.zoomActual(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom to Fit", action: #selector(EditorWindowController.zoomFit(_:)), keyEquivalent: "9")

        let window = submenu("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = window

        return main
    }

    // MARK: Windows

    private func updateActivationPolicy() {
        let visible = !editors.isEmpty
            || (settings?.window?.isVisible ?? false)
            || (history?.window?.isVisible ?? false)
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }

    private func bringToFront(_ controller: NSWindowController?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any? = nil) {
        if settings == nil {
            let s = SettingsWindowController(shortcut: shortcut)
            s.isHotkeyActive = { [weak self] in self?.hotkeyActive ?? false }
            s.onCapture = { [weak self] in self?.captureArea(nil) }
            s.onOpenImage = { [weak self] in self?.openImage(nil) }
            s.onShowHistory = { [weak self] in self?.showHistory(nil) }
            s.onShortcutChange = { [weak self] new in
                guard let self else { return }
                self.shortcut = new
                new.save()
                self.registerHotkey()
            }
            s.onShortcutRecording = { [weak self] recording in
                // Release the current hotkey while recording so the keys reach the recorder.
                if recording { HotKey.unregister(id: 1) } else { self?.registerHotkey() }
            }
            s.onClose = { [weak self] in
                DispatchQueue.main.async { self?.updateActivationPolicy() }
            }
            settings = s
        }
        settings?.refresh()
        bringToFront(settings)
    }

    @objc func showHistory(_ sender: Any?) {
        if history == nil {
            let h = HistoryWindowController(shortcutText: shortcut.displayString)
            h.onOpen = { [weak self] url in self?.openEditor(url: url, historyURL: url) }
            h.onClose = { [weak self] in
                DispatchQueue.main.async { self?.updateActivationPolicy() }
            }
            history = h
        }
        history?.reload()
        bringToFront(history)
    }

    // MARK: Capture actions

    @objc func captureArea(_ sender: Any?) { capture(.area) }
    @objc func captureWindow(_ sender: Any?) { capture(.window) }
    @objc func captureScreen(_ sender: Any?) { capture(.screen) }

    private func capture(_ mode: CaptureMode) {
        Capturer.capture(mode) { [weak self] tmp in
            let saved = History.importCapture(tmp)
            self?.openEditor(url: saved, historyURL: saved)
        }
    }

    @objc func openScreenshotsFolder(_ sender: Any?) { History.revealFolder() }

    @objc func openImage(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openEditor(url: url, historyURL: nil) }
    }

    @objc func openClipboard(_ sender: Any?) {
        guard let img = NSImage(pasteboard: .general), let base = BaseImage(nsImage: img) else {
            NSSound.beep()
            return
        }
        openEditor(base: base, historyURL: nil)
    }

    @objc func toggleLogin(_ sender: Any?) {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: error)
            alert.informativeText = "Move Snapshot.app to /Applications and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
        settings?.refresh()
    }

    // MARK: Editors

    private func openEditor(url: URL, historyURL: URL?) {
        guard let base = BaseImage(url: url) else {
            Log.write("could not load image \(url.path)")
            NSSound.beep()
            return
        }
        openEditor(base: base, historyURL: historyURL)
    }

    private func openEditor(base: BaseImage, historyURL: URL?) {
        let editor = EditorWindowController(base: base, historyURL: historyURL)
        editor.onShowHistory = { [weak self] in self?.showHistory(nil) }
        editor.onClose = { [weak self] e in
            guard let self else { return }
            self.editors.removeAll { $0 === e }
            DispatchQueue.main.async { self.updateActivationPolicy() }
        }
        editors.append(editor)
        bringToFront(nil)
        editor.present()
    }
}
