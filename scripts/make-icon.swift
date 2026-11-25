// Renders the 1024×1024 app icon PNG. Usage: swift scripts/make-icon.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(x: 0, y: 0, width: size, height: size)
let body = canvas.insetBy(dx: 100, dy: 100)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [
    NSColor(srgbRed: 0.33, green: 0.24, blue: 0.93, alpha: 1),
    NSColor(srgbRed: 0.16, green: 0.55, blue: 1.0, alpha: 1),
])!.draw(in: shape, angle: 90)

// Highlighter swipe
NSColor(srgbRed: 1, green: 0.86, blue: 0.1, alpha: 0.95).setFill()
let f = body.insetBy(dx: 150, dy: 150)
NSBezierPath(roundedRect: NSRect(x: f.minX + 60, y: f.midY - 45, width: f.width - 120, height: 90),
             xRadius: 24, yRadius: 24).fill()

// Viewfinder corners
let corners = NSBezierPath()
corners.lineWidth = 46
corners.lineCapStyle = .round
corners.lineJoinStyle = .round
let L: CGFloat = 130
for (x, y, dx, dy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0),
                       (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
    corners.move(to: NSPoint(x: x + dx * L, y: y))
    corners.line(to: NSPoint(x: x, y: y))
    corners.line(to: NSPoint(x: x, y: y + dy * L))
}
NSColor.white.setStroke()
corners.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
