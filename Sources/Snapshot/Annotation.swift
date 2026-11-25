import AppKit
import CoreImage

// MARK: - Tools

enum Tool: Int, CaseIterable {
    case select, rect, ellipse, arrow, line, pen, highlight, text, step, blur, pixelate, crop

    var title: String {
        switch self {
        case .select: return "Select / Move"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .pen: return "Freehand"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .step: return "Step number"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .blur: return "drop.halffull"
        case .pixelate: return "checkerboard.rectangle"
        case .crop: return "crop"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .rect: return "r"
        case .ellipse: return "e"
        case .arrow: return "a"
        case .line: return "l"
        case .pen: return "p"
        case .highlight: return "h"
        case .text: return "t"
        case .step: return "n"
        case .blur: return "b"
        case .pixelate: return "x"
        case .crop: return "c"
        }
    }

    var kind: Annotation.Kind? {
        switch self {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .line: return .line
        case .pen: return .pen
        case .highlight: return .highlight
        case .text: return .text
        case .step: return .step
        case .blur: return .blur
        case .pixelate: return .pixelate
        case .select, .crop: return nil
        }
    }
}

struct StrokeSize {
    let name: String
    let line: CGFloat
    let font: CGFloat
}

let strokeSizes: [StrokeSize] = [
    StrokeSize(name: "Thin", line: 2, font: 14),
    StrokeSize(name: "Medium", line: 4, font: 20),
    StrokeSize(name: "Thick", line: 6, font: 28),
    StrokeSize(name: "Huge", line: 10, font: 40),
]

// MARK: - Annotation model

struct Annotation {
    enum Kind { case rect, ellipse, arrow, line, pen, highlight, text, step, blur, pixelate }

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var text = ""
    var number = 0

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isRectLike: Bool {
        switch kind {
        case .rect, .ellipse, .highlight, .blur, .pixelate: return true
        default: return false
        }
    }

    var font: NSFont { .systemFont(ofSize: fontSize, weight: .bold) }
    var stepRadius: CGFloat { fontSize * 0.75 + 4 }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    var outlineAttributes: [NSAttributedString.Key: Any] {
        let c = color.contrasting
        return [.font: font, .foregroundColor: c, .strokeColor: c, .strokeWidth: 18]
    }

    var textSize: CGSize {
        let s = text.isEmpty ? " " : text
        return (s as NSString).size(withAttributes: textAttributes)
    }

    var bounds: CGRect {
        switch kind {
        case .text:
            return CGRect(origin: start, size: textSize).insetBy(dx: -3, dy: -3)
        case .step:
            let r = stepRadius
            return CGRect(x: start.x - r, y: start.y - r, width: 2 * r, height: 2 * r)
        case .pen:
            guard let first = points.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .line, .arrow:
            let pad = kind == .arrow ? max(12, lineWidth * 4) * 0.6 : lineWidth / 2
            return rect.insetBy(dx: -pad, dy: -pad)
        case .rect, .ellipse:
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .highlight, .blur, .pixelate:
            return rect
        }
    }

    /// Points that can be dragged to resize.
    var handles: [CGPoint] {
        switch kind {
        case .line, .arrow:
            return [start, end]
        case .rect, .ellipse, .highlight, .blur, .pixelate:
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        default:
            return []
        }
    }

    func contains(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch kind {
        case .line, .arrow:
            return distance(p, toSegment: start, end) <= lineWidth / 2 + t
        case .pen:
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= lineWidth / 2 + t }
            return zip(points, points.dropFirst()).contains { distance(p, toSegment: $0, $1) <= lineWidth / 2 + t }
        case .rect:
            let pad = lineWidth / 2 + t
            return rect.insetBy(dx: -pad, dy: -pad).contains(p) && !rect.insetBy(dx: pad, dy: pad).contains(p)
        case .ellipse:
            let pad = lineWidth / 2 + t
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: -pad, dy: -pad))
            let innerRect = rect.insetBy(dx: pad, dy: pad)
            let inner = innerRect.width > 0 && innerRect.height > 0 ? NSBezierPath(ovalIn: innerRect) : nil
            return outer.contains(p) && !(inner?.contains(p) ?? false)
        default:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    mutating func move(by d: CGVector) {
        start.x += d.dx; start.y += d.dy
        end.x += d.dx; end.y += d.dy
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }
}

func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let l2 = dx * dx + dy * dy
    if l2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

extension NSColor {
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }

    var contrasting: NSColor {
        luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
    }
}

// MARK: - Base image (with lazily computed blur / pixelate layers)

final class BaseImage {
    let image: NSImage
    let cgImage: CGImage

    var size: CGSize { image.size }
    var scale: CGFloat { CGFloat(cgImage.width) / max(image.size.width, 1) }

    init(cgImage: CGImage, size: CGSize) {
        self.cgImage = cgImage
        self.image = NSImage(cgImage: cgImage, size: size)
    }

    convenience init?(nsImage: NSImage) {
        if let rep = nsImage.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }),
           let cg = rep.cgImage {
            self.init(cgImage: cg, size: rep.size)
        } else if let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            self.init(cgImage: cg, size: nsImage.size)
        } else {
            return nil
        }
    }

    convenience init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let s = max(1, dpi / 72)
        self.init(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / s, height: CGFloat(cg.height) / s))
    }

    lazy var blurred: NSImage? = filtered { ci, s in
        ci.clampedToExtent().applyingGaussianBlur(sigma: 10 * s)
    }

    lazy var pixelated: NSImage? = filtered { ci, s in
        ci.clampedToExtent().applyingFilter("CIPixellate", parameters: [
            kCIInputScaleKey: 12 * s,
            kCIInputCenterKey: CIVector(x: 0, y: 0),
        ])
    }

    private func filtered(_ f: (CIImage, CGFloat) -> CIImage) -> NSImage? {
        let ci = CIImage(cgImage: cgImage)
        let out = f(ci, scale).cropped(to: ci.extent)
        let ctx = CIContext(options: nil)
        guard let cg = ctx.createCGImage(out, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    func cropped(to r: CGRect) -> (BaseImage, CGPoint)? {
        let s = scale
        let px = CGRect(x: (r.minX * s).rounded(.down), y: (r.minY * s).rounded(.down),
                        width: (r.width * s).rounded(), height: (r.height * s).rounded())
            .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard px.width >= 1, px.height >= 1, let cg = cgImage.cropping(to: px) else { return nil }
        let newImage = BaseImage(cgImage: cg, size: CGSize(width: px.width / s, height: px.height / s))
        return (newImage, CGPoint(x: px.minX / s, y: px.minY / s))
    }
}

// MARK: - Rendering

/// Draws into the current NSGraphicsContext, which must be flipped (origin top-left, in image points).
enum Renderer {
    static func draw(base: BaseImage, annotations: [Annotation], skipping skip: UUID? = nil, shadowScale: CGFloat = 1) {
        let full = CGRect(origin: .zero, size: base.size)
        base.image.draw(in: full, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for a in annotations where a.id != skip {
            draw(a, base: base, shadowScale: shadowScale)
        }
    }

    static func draw(_ a: Annotation, base: BaseImage, shadowScale: CGFloat) {
        guard let ctx = NSGraphicsContext.current else { return }
        let cg = ctx.cgContext
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }

        switch a.kind {
        case .highlight:
            cg.setBlendMode(.multiply)
            a.color.withAlphaComponent(0.55).setFill()
            NSBezierPath(rect: a.rect).fill()

        case .blur, .pixelate:
            guard let src = a.kind == .blur ? base.blurred : base.pixelated else { return }
            NSBezierPath(rect: a.rect).addClip()
            src.draw(in: CGRect(origin: .zero, size: base.size), from: .zero,
                     operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        case .text:
            let s = a.text as NSString
            s.draw(at: a.start, withAttributes: a.outlineAttributes)
            s.draw(at: a.start, withAttributes: a.textAttributes)

        default:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 3 * shadowScale
            shadow.shadowOffset = NSSize(width: 1 * shadowScale, height: -1 * shadowScale)
            shadow.set()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            drawShape(a)
            cg.endTransparencyLayer()
        }
    }

    private static func drawShape(_ a: Annotation) {
        let path = NSBezierPath()
        path.lineWidth = a.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        a.color.setStroke()
        a.color.setFill()

        switch a.kind {
        case .rect:
            path.appendRect(a.rect)
            path.stroke()
        case .ellipse:
            path.appendOval(in: a.rect)
            path.stroke()
        case .line:
            path.move(to: a.start)
            path.line(to: a.end)
            path.stroke()
        case .arrow:
            drawArrow(a, path: path)
        case .pen:
            guard let first = a.points.first else { return }
            path.move(to: first)
            if a.points.count == 1 {
                path.line(to: first)
            } else {
                for p in a.points.dropFirst() { path.line(to: p) }
            }
            path.stroke()
        case .step:
            let r = a.stepRadius
            let c = a.start
            let circle = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            circle.fill()
            NSColor.white.setStroke()
            circle.lineWidth = max(1.5, r * 0.12)
            circle.stroke()
            let s = "\(a.number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.05, weight: .bold),
                .foregroundColor: a.color.contrasting,
            ]
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: attrs)
        default:
            break
        }
    }

    private static func drawArrow(_ a: Annotation, path: NSBezierPath) {
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        let headLen = min(len, max(12, a.lineWidth * 4))
        let headHalf = headLen * 0.55
        let base = CGPoint(x: a.end.x - ux * headLen, y: a.end.y - uy * headLen)

        path.move(to: a.start)
        path.line(to: CGPoint(x: base.x + ux * 1, y: base.y + uy * 1))
        path.stroke()

        let head = NSBezierPath()
        head.move(to: a.end)
        head.line(to: CGPoint(x: base.x - uy * headHalf, y: base.y + ux * headHalf))
        head.line(to: CGPoint(x: base.x + uy * headHalf, y: base.y - ux * headHalf))
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = max(1, a.lineWidth / 2)
        head.fill()
        head.stroke()
    }

    /// Renders base image + annotations at full pixel resolution.
    static func render(base: BaseImage, annotations: [Annotation]) -> CGImage? {
        let w = base.cgImage.width, h = base.cgImage.height
        var space = base.cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = base.scale
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(base: base, annotations: annotations, shadowScale: s)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
