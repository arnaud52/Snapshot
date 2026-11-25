import AppKit
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Window shown when the app is opened from Finder/Spotlight/Launchpad, on first launch,
/// from the menu-bar icon (Settings…), and whenever Screen Recording permission is missing.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onCapture: (() -> Void)?
    var onOpenImage: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onClose: (() -> Void)?
    var onShortcutChange: ((Shortcut) -> Void)?
    var onShortcutRecording: ((Bool) -> Void)?
    var isHotkeyActive: () -> Bool = { true }

    private let recorder: ShortcutRecorder
    private let shortcutStatus = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let permissionIcon = NSImageView()
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionHint = NSTextField(wrappingLabelWithString:
        "Click “Open System Settings…” and turn on Snapshot. If it is already on, select it, remove it with “–”, "
        + "and turn it on again when asked. Then click “Restart Snapshot”.")
    private let permissionButtons = NSStackView()
    private let loginCheckbox = NSButton(checkboxWithTitle: "Open Snapshot automatically at login", target: nil, action: nil)
    private let folderPath = NSTextField(labelWithString: "")

    init(shortcut: Shortcut) {
        recorder = ShortcutRecorder(shortcut: shortcut)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Snapshot"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        let width: CGFloat = 436

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "Snapshot")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        subtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4
        let header = NSStackView(views: [icon, titles])
        header.alignment = .centerY
        header.spacing = 14

        // Shortcut
        let shortcutLabel = NSTextField(labelWithString: "Capture shortcut:")
        shortcutLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        recorder.onChange = { [weak self] s in self?.onShortcutChange?(s); self?.refresh() }
        recorder.onRecordingChange = { [weak self] r in self?.onShortcutRecording?(r) }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .push
        let shortcutRow = NSStackView(views: [shortcutLabel, recorder, reset])
        shortcutRow.spacing = 8
        shortcutStatus.font = .systemFont(ofSize: 12)

        // Permission
        permissionIcon.translatesAutoresizingMaskIntoConstraints = false
        permissionIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        permissionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let permissionRow = NSStackView(views: [permissionIcon, permissionLabel])
        permissionRow.spacing = 6
        permissionHint.textColor = .secondaryLabelColor
        permissionHint.font = .systemFont(ofSize: 12)
        let openSettings = NSButton(title: "Open System Settings…", target: self, action: #selector(openPrivacySettings))
        let restart = NSButton(title: "Restart Snapshot", target: self, action: #selector(restart))
        permissionButtons.setViews([openSettings, restart], in: .leading)
        permissionButtons.spacing = 8

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)

        // Screenshots folder
        let folderLabel = NSTextField(labelWithString: "Screenshots are saved automatically to:")
        folderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        folderPath.lineBreakMode = .byTruncatingMiddle
        folderPath.textColor = .secondaryLabelColor
        folderPath.translatesAutoresizingMaskIntoConstraints = false
        folderPath.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true
        let change = NSButton(title: "Change…", target: self, action: #selector(changeFolder))
        let showFolder = NSButton(title: "Show in Finder", target: self, action: #selector(showFolder))
        let folderRow = NSStackView(views: [folderPath, change, showFolder])
        folderRow.spacing = 8

        let capture = NSButton(title: "Capture Area", target: self, action: #selector(capture))
        capture.keyEquivalent = "\r"
        let history = NSButton(title: "History…", target: self, action: #selector(showHistory))
        let open = NSButton(title: "Open Image…", target: self, action: #selector(openImage))
        let actions = NSStackView(views: [capture, history, open])
        actions.spacing = 8

        let footer = NSTextField(wrappingLabelWithString:
            "Snapshot runs in the menu bar (camera icon). Open the app again at any time to show this window.")
        footer.textColor = .tertiaryLabelColor
        footer.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [header, separator(), shortcutRow, shortcutStatus, separator(),
                                        folderLabel, folderRow, separator(),
                                        permissionRow, permissionHint, permissionButtons, separator(),
                                        loginCheckbox, actions, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: width + 44),
            subtitle.widthAnchor.constraint(equalToConstant: width - 78),
            permissionHint.widthAnchor.constraint(equalToConstant: width),
            footer.widthAnchor.constraint(equalToConstant: width),
        ])
        for v in stack.arrangedSubviews where v is NSBox {
            v.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        window.contentView = content
        refresh()
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    func refresh() {
        let key = recorder.shortcut.displayString
        subtitle.stringValue = "Press \(key) anywhere to capture an area.\nPress Space while selecting to capture a window, Esc to cancel."

        if isHotkeyActive() {
            shortcutStatus.stringValue = "✓ \(key) is active everywhere. Note: it replaces \(key) in other apps."
            shortcutStatus.textColor = .secondaryLabelColor
        } else {
            shortcutStatus.stringValue = "⚠︎ \(key) could not be registered — another app is using it. Pick another shortcut."
            shortcutStatus.textColor = .systemRed
        }

        let allowed = CGPreflightScreenCaptureAccess()
        permissionIcon.image = NSImage(systemSymbolName: allowed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                       accessibilityDescription: nil)
        permissionIcon.contentTintColor = allowed ? .systemGreen : .systemOrange
        permissionLabel.stringValue = allowed ? "Screen Recording permission: allowed"
                                              : "Screen Recording permission: not allowed yet"
        permissionHint.isHidden = allowed
        permissionButtons.isHidden = allowed
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        folderPath.stringValue = History.displayPath
        folderPath.toolTip = History.directory.path
    }

    @objc private func changeFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = History.directory
        panel.prompt = "Use This Folder"
        panel.message = "New screenshots will be saved here. Existing ones stay where they are."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            History.setDirectory(url)
            self?.refresh()
        }
    }

    @objc private func showFolder() { History.revealFolder() }

    /// Shown when the capture shortcut is pressed but the permission is missing.
    func warnPermissionMissing() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Snapshot can’t capture the screen yet"
        alert.informativeText = """
        macOS hasn’t given Snapshot the Screen Recording permission.

        Click “Open System Settings”, turn on Snapshot (if it’s already on, remove it with “–” \
        and add it again), then click “Restart Snapshot” in this window.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.openPrivacySettings() }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func resetShortcut() {
        recorder.shortcut = .default
        onShortcutChange?(.default)
        refresh()
    }

    @objc private func openPrivacySettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.set(loginCheckbox.state == .on)
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    @objc private func capture() {
        window?.close()
        onCapture?()
    }

    @objc private func showHistory() { onShowHistory?() }
    @objc private func openImage() { onOpenImage?() }
}
