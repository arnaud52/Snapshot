import AppKit
import ImageIO

extension Notification.Name {
    static let snapshotHistoryChanged = Notification.Name("SnapshotHistoryChanged")
}

/// Every capture (and every edited image) is saved automatically as a PNG in the
/// screenshots folder: ~/Pictures/Snapshot by default, changeable in Settings.
enum History {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snapshot", isDirectory: true)
    }

    static var directory: URL {
        let dir = UserDefaults.standard.string(forKey: "saveFolderPath")
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var displayPath: String { (directory.path as NSString).abbreviatingWithTildeInPath }

    static func setDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "saveFolderPath")
        Log.write("screenshots folder -> \(url.path)")
        notify()
    }

    /// Earlier versions kept history in Application Support; move those files to the visible folder.
    static func migrateLegacyFolder() {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snapshot/History", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        let dest = directory
        for f in files where !f.lastPathComponent.hasPrefix(".") {
            let target = dest.appendingPathComponent(f.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                do { try fm.moveItem(at: f, to: target) } catch { Log.write("migrate failed \(f.lastPathComponent): \(error)") }
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: legacy)
            try? fm.removeItem(at: legacy.deletingLastPathComponent())
        }
        Log.write("migrated \(files.count) file(s) from legacy history folder")
    }

    static func revealFolder() {
        NSWorkspace.shared.open(directory)
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func newURL(date: Date = Date()) -> URL {
        let base = "Snapshot \(nameFormatter.string(from: date))"
        var url = directory.appendingPathComponent("\(base).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) (\(n)).png")
            n += 1
        }
        return url
    }

    /// Moves a freshly captured temp file into the history folder.
    static func importCapture(_ tmp: URL) -> URL {
        let dest = newURL()
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            Log.write("history: could not move capture: \(error)")
            return tmp
        }
        notify()
        return dest
    }

    static func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            notify()
        } catch {
            Log.write("history: write failed: \(error)")
        }
    }

    static func items() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // names encode the capture time
    }

    static func date(of url: URL) -> Date? {
        var name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("Snapshot ") else { return nil }
        name.removeFirst("Snapshot ".count)
        if let r = name.range(of: " (") { name = String(name[..<r.lowerBound]) }
        return nameFormatter.date(from: name)
    }

    static func notify() {
        NotificationCenter.default.post(name: .snapshotHistoryChanged, object: nil)
    }

    static func copyToPasteboard(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if url.pathExtension.lowercased() == "png" { pb.setData(data, forType: .png) }
        if let rep = NSBitmapImageRep(data: data), let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }
}

// MARK: - History window

private final class HistoryItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("HistoryItem")
    let thumb = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    var url: URL?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 8

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.borderWidth = 1
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        thumb.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(thumb)
        v.addSubview(titleLabel)
        v.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            thumb.heightAnchor.constraint(equalToConstant: 136),
            titleLabel.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])
        view = v
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
                : NSColor.clear.cgColor
        }
    }
}

private final class HistoryCollectionView: NSCollectionView {
    weak var owner: HistoryWindowController?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2,
           let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            owner?.open([ip])
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !selectionIndexPaths.contains(ip) {
            selectionIndexPaths = [ip]
        }
        return owner?.contextMenu()
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 51, 117: owner?.trashSelected(nil)
        case 36, 76: owner?.openSelected(nil)
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) { owner?.copySelected(nil) }
}

final class HistoryWindowController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate {
    var onOpen: ((URL) -> Void)?
    var onClose: (() -> Void)?

    private var items: [URL] = []
    private let collectionView = HistoryCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let cache = NSCache<NSString, NSImage>()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    init(shortcutText: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Snapshot History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.setFrameAutosaveName("SnapshotHistoryWindow")
        super.init(window: window)
        window.delegate = self

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 230, height: 190)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 14
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.windowBackgroundColor]
        collectionView.register(HistoryItem.self, forItemWithIdentifier: HistoryItem.id)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.owner = self
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.stringValue = "No screenshots yet.\nPress \(shortcutText) to capture an area."
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 12)
        let hint = NSTextField(labelWithString: "Double-click to edit · drag out to share")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        let folder = NSButton(title: "Show in Finder", target: self, action: #selector(showFolder(_:)))
        folder.bezelStyle = .push
        let bar = NSStackView(views: [countLabel, hint, NSView(), folder])
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(line)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window.contentView = content
        window.center()

        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .snapshotHistoryChanged, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        items = History.items()
        collectionView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        let n = items.count == 1 ? "1 screenshot" : "\(items.count) screenshots"
        countLabel.stringValue = "\(n) in \(History.displayPath)"
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: HistoryItem.id, for: indexPath) as! HistoryItem
        let url = items[indexPath.item]
        item.url = url
        let date = History.date(of: url)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        item.titleLabel.stringValue = date.map { dateFormatter.string(from: $0) } ?? url.lastPathComponent
        item.detailLabel.stringValue = ""

        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)" as NSString
        if let img = cache.object(forKey: key) {
            item.thumb.image = img
            item.detailLabel.stringValue = img.accessibilityDescription ?? ""
        } else {
            item.thumb.image = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let img = Self.thumbnail(url)
                DispatchQueue.main.async {
                    guard let img else { return }
                    self?.cache.setObject(img, forKey: key)
                    if item.url == url {
                        item.thumb.image = img
                        item.detailLabel.stringValue = img.accessibilityDescription ?? ""
                    }
                }
            }
        }
        return item
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 460,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            img.accessibilityDescription = "\(w) × \(h) px"
        }
        return img
    }

    // MARK: Drag out

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        items[indexPath.item] as NSURL
    }

    // MARK: Actions

    private var selectedURLs: [URL] {
        collectionView.selectionIndexPaths.map(\.item).sorted().compactMap { $0 < items.count ? items[$0] : nil }
    }

    fileprivate func open(_ paths: Set<IndexPath>) {
        for ip in paths where ip.item < items.count { onOpen?(items[ip.item]) }
    }

    fileprivate func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Open in Editor", action: #selector(openSelected(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Copy Image", action: #selector(copySelected(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Show in Finder", action: #selector(revealSelected(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Move to Trash", action: #selector(trashSelected(_:)), keyEquivalent: "").target = self
        return m
    }

    @objc func openSelected(_ sender: Any?) { open(collectionView.selectionIndexPaths) }

    @objc func copySelected(_ sender: Any?) {
        guard let url = selectedURLs.first else { return }
        History.copyToPasteboard(url)
    }

    @objc func revealSelected(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(selectedURLs)
    }

    @objc func trashSelected(_ sender: Any?) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { _, _ in
            DispatchQueue.main.async { History.notify() }
        }
    }

    @objc func showFolder(_ sender: Any?) {
        History.revealFolder()
    }
}
