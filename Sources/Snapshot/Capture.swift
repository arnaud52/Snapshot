import AppKit
import CoreGraphics

enum CaptureMode {
    case area, window, screen
}

/// Uses the system `screencapture` tool for the interactive selection UI
/// (crosshair, Space to toggle window mode, Esc to cancel).
enum Capturer {
    private static var busy = false
    /// Called (instead of showing an alert) when Screen Recording permission is missing.
    static var onPermissionMissing: (() -> Void)?

    static func capture(_ mode: CaptureMode, completion: @escaping (URL) -> Void) {
        guard !busy else { return }
        guard ensurePermission() else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).png")
        var args = ["-x"] // no shutter sound
        switch mode {
        case .area:
            args += ["-i"]
        case .window:
            args += ["-i", "-w", "-o"]
        case .screen:
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let screen, let primary = NSScreen.screens.first {
                let f = screen.frame
                let y = primary.frame.maxY - f.maxY
                args += ["-R", "\(Int(f.minX)),\(Int(y)),\(Int(f.width)),\(Int(f.height))"]
            } else {
                args += ["-m"]
            }
        }
        args.append(url.path)

        busy = true
        Log.write("capture \(mode) \(args.joined(separator: " "))")
        let start = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = args
            process.terminationHandler = { p in
                DispatchQueue.main.async {
                    busy = false
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    Log.write("screencapture exit=\(p.terminationStatus) bytes=\(size)")
                    if size > 0 { completion(url) }
                }
            }
            do {
                try process.run()
            } catch {
                busy = false
                NSSound.beep()
            }
        }
        // Give the status menu time to disappear before grabbing the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + (mode == .screen ? 0.3 : 0.05), execute: start)
    }

    private static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        if let onPermissionMissing {
            onPermissionMissing()
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        Snapshot needs permission to capture the screen.

        Enable “Snapshot” in System Settings → Privacy & Security → \
        Screen & System Audio Recording, then quit and reopen Snapshot.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
