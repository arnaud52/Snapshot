import AppKit

final class CanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    private(set) var base: BaseImage
    private(set) var annotations: [Annotation] = []

    var tool: Tool = .rect {
        didSet {
            guard tool != oldValue else { return }
            commitText()
            cropRect = nil
            if tool != .select { selectedID = nil }
            window?.invalidateCursorRects(for: self)
            onToolChange?(tool)
            needsDisplay = true
        }
    }

    var sizeIndex = 1
    private var toolColors: [Tool: NSColor] = [:]
    static let defaultColor = NSColor(srgbRed: 0.93, green: 0.16, blue: 0.16, alpha: 1)
    static let highlightColor = NSColor(srgbRed: 1.0, green: 0.9, blue: 0.0, alpha: 1)

    var color: NSColor {
        toolColors[tool] ?? (tool == .highlight ? Self.highlightColor : Self.defaultColor)
    }

    private(set) var selectedID: UUID? {
        didSet { if selectedID != oldValue { needsDisplay = true } }
    }

    var onToolChange: ((Tool) -> Void)?
    var onCopy: (() -> Void)?

    // Undo
    private struct State { var base: BaseImage; var annotations: [Annotation] }
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var lastCoalesceKey: String?
    /// Incremented on every edit; used to know when the history copy is out of date.
    private(set) var changeCount = 0 { didSet { onChange?() } }
    var onChange: (() -> Void)?

    // Interaction
    private enum Drag {
        case none
        case creating(UUID)
        case moving(UUID, CGPoint, pushed: Bool)
        case handle(UUID, movingStart: Bool, pushed: Bool)
        case cropping(CGPoint)
    }
    private var drag: Drag = .none
    private var cropRect: CGRect?

    // Text editing
    private var textField: NSTextField?
    private var editingID: UUID?
    private var editingIsNew = false
    private var editingUndoState: State?
    private var editingOriginalText = ""

    init(base: BaseImage) {
        self.base = base
        super.init(frame: CGRect(origin: .zero, size: base.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Renderer.draw(base: base, annotations: annotations, skipping: editingID)
        drawOverlays()
    }

    private func drawOverlays() {
        let m = magnification
        if let id = selectedID, let a = annotation(id), editingID == nil {
            let box = NSBezierPath(rect: a.bounds.insetBy(dx: -3 / m, dy: -3 / m))
            box.lineWidth = 1 / m
            box.setLineDash([4 / m, 3 / m], count: 2, phase: 0)
            NSColor.white.setStroke()
            let under = box.copy() as! NSBezierPath
            under.setLineDash(nil, count: 0, phase: 0)
            under.lineWidth = 1 / m
            NSColor.black.withAlphaComponent(0.6).setStroke()
            under.stroke()
            NSColor.white.setStroke()
            box.stroke()
            for h in a.handles {
                let s = 8 / m
                let r = CGRect(x: h.x - s / 2, y: h.y - s / 2, width: s, height: s)
                NSColor.white.setFill()
                NSBezierPath(rect: r).fill()
                NSColor.controlAccentColor.setStroke()
                let p = NSBezierPath(rect: r)
                p.lineWidth = 1.5 / m
                p.stroke()
            }
        }

        if let tf = textField {
            let box = NSBezierPath(rect: tf.frame.insetBy(dx: -2, dy: -2))
            box.lineWidth = 1 / m
            box.setLineDash([4 / m, 3 / m], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            box.stroke()
        }

        if let r = cropRect {
            let dim = NSBezierPath(rect: bounds)
            dim.appendRect(r)
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            dim.fill()
            let border = NSBezierPath(rect: r)
            border.lineWidth = 1 / m
            border.setLineDash([5 / m, 4 / m], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()
            let label = "\(Int(r.width * base.scale)) × \(Int(r.height * base.scale))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11 / m, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let sz = label.size(withAttributes: attrs)
            let bg = CGRect(x: r.minX, y: max(0, r.minY - sz.height - 6 / m), width: sz.width + 8 / m, height: sz.height + 4 / m)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 3 / m, yRadius: 3 / m).fill()
            label.draw(at: CGPoint(x: bg.minX + 4 / m, y: bg.minY + 2 / m), withAttributes: attrs)
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: Helpers

    private func index(_ id: UUID) -> Int? { annotations.firstIndex { $0.id == id } }
    private func annotation(_ id: UUID) -> Annotation? { index(id).map { annotations[$0] } }

    private func hitTest(annotationAt p: CGPoint) -> Annotation? {
        let t = 4 / magnification
        return annotations.reversed().first { $0.contains(p, tolerance: t) }
    }

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func newAnnotation(_ kind: Annotation.Kind, at p: CGPoint) -> Annotation {
        let s = strokeSizes[sizeIndex]
        return Annotation(kind: kind, start: p, end: p, color: color, lineWidth: s.line, fontSize: s.font)
    }

    private var nextStepNumber: Int {
        (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
    }

    private func constrained(_ s: CGPoint, _ p: CGPoint, kind: Annotation.Kind) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        switch kind {
        case .line, .arrow:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let len = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        default:
            let m = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -m : m), y: s.y + (dy < 0 ? -m : m))
        }
    }

    // MARK: Undo

    private func pushUndo(coalesce key: String? = nil) {
        changeCount += 1
        if let key, key == lastCoalesceKey { return }
        lastCoalesceKey = key
        undoStack.append(State(base: base, annotations: annotations))
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func restore(_ s: State) {
        if s.base !== base {
            base = s.base
            setFrameSize(base.size)
        }
        annotations = s.annotations
        if let id = selectedID, index(id) == nil { selectedID = nil }
        lastCoalesceKey = nil
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        guard let s = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(State(base: base, annotations: annotations))
        restore(s)
        changeCount += 1
    }

    @objc func redo(_ sender: Any?) {
        commitText()
        guard let s = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(State(base: base, annotations: annotations))
        restore(s)
        changeCount += 1
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    @objc func delete(_ sender: Any?) { deleteSelected() }

    @objc override func selectAll(_ sender: Any?) {
        tool = .select
        selectedID = annotations.last?.id
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return !undoStack.isEmpty
        case #selector(redo(_:)): return !redoStack.isEmpty
        case #selector(delete(_:)): return selectedID != nil
        default: return true
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Style

    func setColor(_ c: NSColor) {
        toolColors[tool] = c
        applyStyle(color: c, size: nil)
    }

    func setSize(_ i: Int) {
        sizeIndex = i
        applyStyle(color: nil, size: i)
    }

    private func applyStyle(color: NSColor?, size: Int?) {
        guard let id = selectedID, let i = index(id) else { return }
        pushUndo(coalesce: "style-\(id)")
        if let color { annotations[i].color = color }
        if let size {
            annotations[i].lineWidth = strokeSizes[size].line
            annotations[i].fontSize = strokeSizes[size].font
        }
        needsDisplay = true
    }

    func deleteSelected() {
        guard let id = selectedID, let i = index(id) else { return }
        pushUndo()
        annotations.remove(at: i)
        selectedID = nil
        needsDisplay = true
    }

    // MARK: Export

    /// `commitEditing: false` keeps an in-progress text box open (used by auto-save).
    func renderedImage(commitEditing: Bool = true) -> CGImage? {
        if commitEditing { commitText() }
        return Renderer.render(base: base, annotations: annotations)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = point(event)
        lastCoalesceKey = nil

        if textField != nil {
            commitText()
            if tool == .text { return }
        }
        window?.makeFirstResponder(self)

        // Resize handles of the current selection take priority.
        if let id = selectedID, let a = annotation(id), let i = index(id) {
            let s = 10 / magnification
            if let k = a.handles.firstIndex(where: { abs($0.x - p.x) <= s / 2 + 1 && abs($0.y - p.y) <= s / 2 + 1 }) {
                if a.isRectLike {
                    let h = a.handles
                    annotations[i].start = h[3 - k]
                    annotations[i].end = h[k]
                    drag = .handle(id, movingStart: false, pushed: false)
                } else {
                    drag = .handle(id, movingStart: k == 0, pushed: false)
                }
                return
            }
        }

        switch tool {
        case .select:
            if let hit = hitTest(annotationAt: p) {
                selectedID = hit.id
                if event.clickCount == 2, hit.kind == .text {
                    beginEditing(hit.id, isNew: false)
                    return
                }
                drag = .moving(hit.id, p, pushed: false)
            } else {
                selectedID = nil
            }

        case .text:
            if let hit = hitTest(annotationAt: p), hit.kind == .text {
                selectedID = hit.id
                beginEditing(hit.id, isNew: false)
            } else {
                pushUndo()
                var a = newAnnotation(.text, at: CGPoint(x: p.x, y: p.y - strokeSizes[sizeIndex].font * 0.6))
                a.text = ""
                annotations.append(a)
                selectedID = a.id
                beginEditing(a.id, isNew: true)
            }

        case .step:
            pushUndo()
            var a = newAnnotation(.step, at: p)
            a.number = nextStepNumber
            annotations.append(a)
            selectedID = a.id
            drag = .moving(a.id, p, pushed: true)

        case .crop:
            drag = .cropping(p)
            cropRect = CGRect(origin: p, size: .zero)

        default:
            guard let kind = tool.kind else { return }
            pushUndo()
            var a = newAnnotation(kind, at: p)
            if kind == .pen { a.points = [p] }
            annotations.append(a)
            selectedID = nil
            drag = .creating(a.id)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .creating(let id):
            guard let i = index(id) else { return }
            if annotations[i].kind == .pen {
                annotations[i].points.append(p)
            } else {
                annotations[i].end = shift ? constrained(annotations[i].start, p, kind: annotations[i].kind) : p
            }
        case .moving(let id, let last, let pushed):
            guard let i = index(id) else { return }
            if !pushed { pushUndo() }
            annotations[i].move(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            drag = .moving(id, p, pushed: true)
        case .handle(let id, let movingStart, let pushed):
            guard let i = index(id) else { return }
            if !pushed { pushUndo() }
            if movingStart {
                annotations[i].start = shift ? constrained(annotations[i].end, p, kind: annotations[i].kind) : p
            } else {
                annotations[i].end = shift ? constrained(annotations[i].start, p, kind: annotations[i].kind) : p
            }
            drag = .handle(id, movingStart: movingStart, pushed: true)
        case .cropping(let o):
            let q = shift ? constrained(o, p, kind: .rect) : p
            cropRect = CGRect(x: min(o.x, q.x), y: min(o.y, q.y), width: abs(q.x - o.x), height: abs(q.y - o.y))
                .intersection(bounds)
        }
        autoscroll(with: event)
        needsDisplay = true
    }

    /// True while the mouse is down drawing/moving/resizing (auto-save waits for it).
    var isInteracting: Bool {
        if case .none = drag { return false }
        return true
    }

    override func mouseUp(with event: NSEvent) {
        if isInteracting { changeCount += 1 } // final shape/position after the drag
        switch drag {
        case .creating(let id):
            if let i = index(id) {
                let a = annotations[i]
                let tooSmall = a.kind == .pen
                    ? a.points.count < 2
                    : abs(a.end.x - a.start.x) < 3 && abs(a.end.y - a.start.y) < 3
                if tooSmall {
                    annotations.remove(at: i)
                    if !undoStack.isEmpty { undoStack.removeLast() }
                } else {
                    selectedID = id
                }
            }
        case .cropping:
            if let r = cropRect, r.width >= 4, r.height >= 4 { applyCrop(r) }
            cropRect = nil
        default:
            break
        }
        drag = .none
        needsDisplay = true
    }

    private func applyCrop(_ r: CGRect) {
        guard let (newBase, origin) = base.cropped(to: r) else { return }
        pushUndo()
        base = newBase
        for i in annotations.indices {
            annotations[i].move(by: CGVector(dx: -origin.x, dy: -origin.y))
        }
        setFrameSize(base.size)
        tool = .select
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            deleteSelected(); return
        case 53: // escape
            if cropRect != nil { cropRect = nil; drag = .none; needsDisplay = true }
            else if selectedID != nil { selectedID = nil }
            else { tool = .select }
            return
        case 123, 124, 125, 126: // arrows: nudge
            guard mods.isEmpty, let id = selectedID, let i = index(id) else { break }
            let d: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let v: CGVector = [123: CGVector(dx: -d, dy: 0), 124: CGVector(dx: d, dy: 0),
                               125: CGVector(dx: 0, dy: d), 126: CGVector(dx: 0, dy: -d)][event.keyCode]!
            pushUndo(coalesce: "nudge-\(id)")
            annotations[i].move(by: v)
            needsDisplay = true
            return
        default:
            break
        }
        if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let t = Tool.allCases.first(where: { $0.shortcut == ch }) {
            tool = t
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Text editing

    private func beginEditing(_ id: UUID, isNew: Bool) {
        guard let a = annotation(id) else { return }
        editingID = id
        editingIsNew = isNew
        editingOriginalText = a.text
        editingUndoState = isNew ? nil : State(base: base, annotations: annotations)

        let tf = NSTextField(string: a.text)
        tf.font = a.font
        tf.textColor = a.color
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.isEditable = true
        tf.usesSingleLineMode = false
        tf.cell?.wraps = false
        tf.cell?.isScrollable = false
        tf.placeholderAttributedString = NSAttributedString(string: "Type…", attributes: [
            .font: a.font, .foregroundColor: a.color.withAlphaComponent(0.45),
        ])
        tf.delegate = self
        textField = tf
        addSubview(tf)
        layoutTextField()
        window?.makeFirstResponder(tf)
        if let editor = tf.currentEditor() {
            editor.selectedRange = NSRange(location: (a.text as NSString).length, length: 0)
        }
        needsDisplay = true
    }

    private func layoutTextField() {
        guard let tf = textField, let id = editingID, let a = annotation(id) else { return }
        let sample = (a.text.isEmpty ? "Type…" : a.text + " ") as NSString
        let sz = sample.size(withAttributes: a.textAttributes)
        tf.frame = CGRect(x: a.start.x - 2, y: a.start.y, width: ceil(sz.width) + 16, height: ceil(sz.height) + 2)
        needsDisplay = true
    }

    func commitText() {
        guard let tf = textField, let id = editingID else { return }
        let text = tf.stringValue
        textField = nil
        editingID = nil
        window?.makeFirstResponder(self)
        tf.delegate = nil
        tf.removeFromSuperview()

        if let i = index(id) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                annotations.remove(at: i)
                if selectedID == id { selectedID = nil }
                if editingIsNew {
                    if !undoStack.isEmpty { undoStack.removeLast() }
                } else if let s = editingUndoState {
                    undoStack.append(s); redoStack.removeAll(); changeCount += 1
                }
            } else {
                annotations[i].text = text
                if !editingIsNew, text != editingOriginalText, let s = editingUndoState {
                    undoStack.append(s); redoStack.removeAll(); changeCount += 1
                }
            }
        }
        editingUndoState = nil
        changeCount += 1
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = textField, let id = editingID, let i = index(id) else { return }
        annotations[i].text = tf.stringValue
        layoutTextField()
        changeCount += 1
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }
}
