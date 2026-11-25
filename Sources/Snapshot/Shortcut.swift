import AppKit
import Carbon

/// Appends diagnostic lines to ~/Library/Logs/Snapshot.log
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Snapshot.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// A global keyboard shortcut (key code + modifiers), persisted in UserDefaults.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: [.command])

    static func load() -> Shortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: "hotkeyKeyCode") != nil else { return .default }
        return Shortcut(keyCode: UInt32(d.integer(forKey: "hotkeyKeyCode")),
                        modifiers: NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: "hotkeyModifiers"))))
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: "hotkeyModifiers")
    }

    var carbonModifiers: Int {
        var m = 0
        if modifiers.contains(.command) { m |= cmdKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.control) { m |= controlKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        return m
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Key equivalent string usable in an NSMenuItem (only for printable keys).
    var menuKeyEquivalent: String? {
        let n = Self.keyName(keyCode)
        guard n.count == 1, Self.special[Int(keyCode)] == nil else { return nil }
        return n.lowercased()
    }

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                                         kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16,
                                         kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    private static let special: [Int: String] = {
        var m: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓",
            kVK_UpArrow: "↑", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                 kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, k) in f.enumerated() { m[k] = "F\(i + 1)" }
        return m
    }()

    static func keyName(_ keyCode: UInt32) -> String {
        if let s = special[Int(keyCode)] { return s }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Click to record a new shortcut; Esc cancels.
final class ShortcutRecorder: NSButton {
    var shortcut: Shortcut { didSet { updateTitle() } }
    var onChange: ((Shortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            updateTitle()
            onRecordingChange?(recording)
        }
    }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        toolTip = "Click, then press the new shortcut (Esc to cancel)"
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        title = recording ? "Press shortcut…" : shortcut.displayString
    }

    @objc private func clicked() {
        recording.toggle()
        if recording { window?.makeFirstResponder(self) }
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if recording { handle(event) } else { super.keyDown(with: event) }
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(event.keyCode) == kVK_Escape && mods.isEmpty {
            recording = false
            return
        }
        let isFunctionKey = Shortcut.functionKeys.contains(Int(event.keyCode))
        if mods.intersection([.command, .option, .control]).isEmpty && !isFunctionKey {
            NSSound.beep() // needs ⌘, ⌥ or ⌃ (or a function key)
            return
        }
        shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
        recording = false
        onChange?(shortcut)
    }
}
