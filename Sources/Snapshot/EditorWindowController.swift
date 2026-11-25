import AppKit
import UniformTypeIdentifiers

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

private final class SwatchView: NSView {
    let color: NSColor
    let onClick: () -> Void

    init(color: NSColor, onClick: @escaping () -> Void) {
        self.color = color
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        color.setFill()
        p.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Accent-filled pill button used for the main "Copy" action.
private final class PrimaryButton: NSButton {
    private let label: String
    private let icon: NSImage?

    init(title: String, symbol: String, target: AnyObject, action: Selector) {
        label = title
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        super.init(frame: NSRect(x: 0, y: 0, width: 92, height: 30))
        self.target = target
        self.action = action
        self.title = ""
        isBordered = false
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 92).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let base = NSColor.controlAccentColor
        (isHighlighted ? (base.blended(withFraction: 0.25, of: .black) ?? base) : base).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let iconSize = icon?.size ?? .zero
        let gap: CGFloat = icon == nil ? 0 : 6
        var x = r.midX - (iconSize.width + gap + textSize.width) / 2
        if let icon {
            icon.draw(in: NSRect(x: x, y: r.midY - iconSize.height / 2, width: iconSize.width, height: iconSize.height))
            x += iconSize.width + gap
        }
        (label as NSString).draw(at: NSPoint(x: x, y: r.midY - textSize.height / 2), withAttributes: attrs)
    }
}

private extension NSToolbarItem.Identifier {
    static let tools = Self("tools")
    static let swatches = Self("swatches")
    static let color = Self("color")
    static let size = Self("size")
    static let undo = Self("undo")
    static let redo = Self("redo")
    static let copy = Self("copy")
    static let history = Self("history")
    static let reveal = Self("reveal")
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let canvas: CanvasView
    private let scrollView = NSScrollView()
    private let toolControl = NSSegmentedControl()
    private let colorWell = NSColorWell(style: .minimal)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swatchStack = NSStackView()
    private var hud: NSView?
    private let createdAt = Date()
    var onClose: ((EditorWindowController) -> Void)?
    var onShowHistory: (() -> Void)?
    /// File in the history folder that mirrors this editor's content (nil until first copy/save/edit).
    private(set) var historyURL: URL?
    private var historyChangeCount = 0
    private var autosaveWork: DispatchWorkItem?

    static let swatches: [(String, NSColor)] = [
        ("Red", NSColor(srgbRed: 0.93, green: 0.16, blue: 0.16, alpha: 1)),
        ("Orange", NSColor(srgbRed: 1.0, green: 0.55, blue: 0.0, alpha: 1)),
        ("Yellow", NSColor(srgbRed: 1.0, green: 0.9, blue: 0.0, alpha: 1)),
        ("Green", NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)),
        ("Blue", NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)),
        ("Purple", NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)),
        ("Black", NSColor(white: 0.08, alpha: 1)),
        ("White", NSColor.white),
    ]

    init(base: BaseImage, historyURL: URL? = nil) {
        canvas = CanvasView(base: base)
        self.historyURL = historyURL

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(max(base.size.width + 60, 1180), visible.width * 0.95)
        let h = min(max(base.size.height + 60, 420), visible.height * 0.92 - 60)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 300)
        super.init(window: window)

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        window.title = "Snapshot – \(f.string(from: createdAt))"
        window.delegate = self
        window.tabbingMode = .disallowed

        setupControls()

        let toolbar = NSToolbar(identifier: "SnapshotEditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden

        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = NSColor(white: 0.16, alpha: 1)
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.16, alpha: 1)
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.borderType = .noBorder
        window.contentView = scrollView

        canvas.onToolChange = { [weak self] tool in
            guard let self else { return }
            self.toolControl.selectedSegment = tool.rawValue
            self.colorWell.color = self.canvas.color
        }
        canvas.onCopy = { [weak self] in self?.copyImage(nil) }
        canvas.onChange = { [weak self] in self?.scheduleAutosave() }

        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        zoomToFitIfNeeded()
    }

    // MARK: Controls

    private func setupControls() {
        toolControl.segmentCount = Tool.allCases.count
        toolControl.trackingMode = .selectOne
        for t in Tool.allCases {
            let i = t.rawValue
            if let img = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title) {
                toolControl.setImage(img, forSegment: i)
            } else {
                toolControl.setLabel(String(t.title.prefix(2)), forSegment: i)
            }
            toolControl.setToolTip("\(t.title)  (\(String(t.shortcut).uppercased()))", forSegment: i)
            toolControl.setWidth(28, forSegment: i)
        }
        toolControl.selectedSegment = canvas.tool.rawValue
        toolControl.target = self
        toolControl.action = #selector(toolChanged(_:))

        swatchStack.orientation = .horizontal
        swatchStack.spacing = 4
        for (name, c) in Self.swatches {
            let v = SwatchView(color: c) { [weak self] in self?.swatchClicked(c) }
            v.toolTip = name
            swatchStack.addArrangedSubview(v)
        }

        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Custom color"

        for (i, s) in strokeSizes.enumerated() {
            sizePopup.addItem(withTitle: "")
            sizePopup.item(at: i)?.image = lineImage(width: s.line)
            sizePopup.item(at: i)?.toolTip = s.name
        }
        sizePopup.selectItem(at: canvas.sizeIndex)
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged(_:))
        sizePopup.toolTip = "Line width / text size"
    }

    private func lineImage(width: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: 24, height: 14), flipped: false) { r in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 2, y: r.midY))
            p.line(to: NSPoint(x: r.width - 2, y: r.midY))
            p.lineWidth = min(width, 10)
            p.lineCapStyle = .round
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        if let t = Tool(rawValue: sender.selectedSegment) { canvas.tool = t }
        colorWell.color = canvas.color
        window?.makeFirstResponder(canvas)
    }

    private func swatchClicked(_ c: NSColor) {
        colorWell.color = c
        canvas.setColor(c)
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.setColor(sender.color)
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        canvas.setSize(sender.indexOfSelectedItem)
        window?.makeFirstResponder(canvas)
    }

    // MARK: Actions

    private func pngData(commitEditing: Bool = true) -> Data? {
        guard let cg = canvas.renderedImage(commitEditing: commitEditing) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = canvas.base.size // keeps Retina DPI metadata
        return rep.representation(using: .png, properties: [:])
    }

    @objc func copyImage(_ sender: Any?) {
        guard let cg = canvas.renderedImage() else { NSSound.beep(); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = canvas.base.size
        let pb = NSPasteboard.general
        pb.clearContents()
        let png = rep.representation(using: .png, properties: [:])
        if let png { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        if let png { syncHistory(png, force: true) }
        showHUD("Copied to clipboard")
    }

    @objc func copyAndClose(_ sender: Any?) {
        copyImage(sender)
        window?.close()
    }

    // MARK: Auto-save into the screenshots folder

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosaveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes the current edits to this screenshot's file without interrupting text editing.
    private func autosaveNow() {
        autosaveWork?.cancel()
        autosaveWork = nil
        if canvas.isInteracting { scheduleAutosave(); return }
        guard canvas.changeCount != historyChangeCount, let png = pngData(commitEditing: false) else { return }
        syncHistory(png, force: false)
    }

    /// ⌘S: make sure the latest version is on disk.
    @objc func saveNow(_ sender: Any?) {
        canvas.commitText()
        autosaveWork?.cancel()
        if let png = pngData() { syncHistory(png, force: true) }
        showHUD("Saved in \(History.displayPath)")
    }

    /// Shows this screenshot's file selected in Finder.
    @objc func revealInFinder(_ sender: Any?) {
        autosaveWork?.cancel()
        if canvas.changeCount != historyChangeCount || historyURL == nil, let png = pngData(commitEditing: false) {
            syncHistory(png, force: true)
        }
        if let url = historyURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            History.revealFolder()
        }
    }

    /// Export a copy somewhere else (File → Export As…).
    @objc func saveImage(_ sender: Any?) {
        guard let window else { return }
        canvas.commitText()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Snapshot \(f.string(from: createdAt)).png"
        if let path = UserDefaults.standard.string(forKey: "lastSaveDirectory") {
            panel.directoryURL = URL(fileURLWithPath: path)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let cg = self.canvas.renderedImage() else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = self.canvas.base.size
            let ext = url.pathExtension.lowercased()
            let data = (ext == "jpg" || ext == "jpeg")
                ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                : rep.representation(using: .png, properties: [:])
            if let png = rep.representation(using: .png, properties: [:]) { self.syncHistory(png, force: true) }
            do {
                try data?.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "lastSaveDirectory")
                self.showHUD("Saved \(url.lastPathComponent)")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func undoAction(_ sender: Any?) { canvas.undo(sender) }
    @objc func redoAction(_ sender: Any?) { canvas.redo(sender) }

    @objc func zoomIn(_ sender: Any?) { scrollView.animator().magnification = min(scrollView.magnification * 1.25, 8) }
    @objc func zoomOut(_ sender: Any?) { scrollView.animator().magnification = max(scrollView.magnification / 1.25, 0.1) }
    @objc func zoomActual(_ sender: Any?) { scrollView.animator().magnification = 1 }
    @objc func zoomFit(_ sender: Any?) {
        let avail = scrollView.contentSize
        let s = canvas.base.size
        guard s.width > 0, s.height > 0 else { return }
        scrollView.animator().magnification = min(avail.width / s.width, avail.height / s.height) * 0.98
    }

    private func zoomToFitIfNeeded() {
        let avail = scrollView.contentSize
        let s = canvas.base.size
        guard s.width > 0, s.height > 0 else { return }
        let fit = min(avail.width / s.width, avail.height / s.height)
        if fit < 1 { scrollView.magnification = max(0.1, fit * 0.98) }
    }

    func selectTool(_ t: Tool) { canvas.tool = t }

    // MARK: HUD

    private func showHUD(_ text: String) {
        guard let content = window?.contentView?.superview ?? window?.contentView else { return }
        hud?.removeFromSuperview()
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        box.layer?.cornerRadius = 9
        box.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        content.addSubview(box)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            box.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            box.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        hud = box
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak box] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                box?.animator().alphaValue = 0
            }, completionHandler: {
                box?.removeFromSuperview()
            })
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.tools, .swatches, .color, .size, .flexibleSpace, .undo, .redo, .history, .reveal, .copy]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .tools:
            item.view = toolControl
            item.label = "Tools"
        case .swatches:
            item.view = swatchStack
            item.label = "Colors"
        case .color:
            item.view = colorWell
            item.label = "Color"
        case .size:
            item.view = sizePopup
            item.label = "Size"
        case .undo:
            configure(item, "Undo", "arrow.uturn.backward", "Undo (⌘Z)", #selector(undoAction(_:)))
        case .redo:
            configure(item, "Redo", "arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redoAction(_:)))
        case .copy:
            item.view = PrimaryButton(title: "Copy", symbol: "doc.on.doc", target: self, action: #selector(copyImage(_:)))
            item.view?.toolTip = "Copy the edited image to the clipboard (⌘C)"
            item.label = "Copy"
        case .history:
            configure(item, "History", "clock.arrow.circlepath", "Screenshot history (⌘Y)", #selector(showHistory(_:)))
        case .reveal:
            configure(item, "Show in Finder", "folder", "Show this screenshot in Finder (⇧⌘R)", #selector(revealInFinder(_:)))
        default:
            return nil
        }
        return item
    }

    private func configure(_ item: NSToolbarItem, _ label: String, _ symbol: String, _ tip: String, _ action: Selector) {
        item.label = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        autosaveWork?.cancel()
        canvas.commitText()
        if canvas.changeCount != historyChangeCount, let png = pngData() {
            syncHistory(png, force: false)
        }
        onClose?(self)
    }

    /// Keeps the history copy of this image up to date with the edits.
    private func syncHistory(_ png: Data, force: Bool) {
        let changed = canvas.changeCount != historyChangeCount
        guard changed || (force && historyURL == nil) else { return }
        let url = historyURL ?? History.newURL()
        historyURL = url
        History.write(png, to: url)
        historyChangeCount = canvas.changeCount
    }

    @objc func showHistory(_ sender: Any?) { onShowHistory?() }
}
