// Renders the app icon to a 1024px PNG. Usage: swift make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded tile with the standard macOS margin.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tile); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let colors = [NSColor(red: 0.16, green: 0.10, blue: 0.42, alpha: 1).cgColor,
              NSColor(red: 0.50, green: 0.33, blue: 0.98, alpha: 1).cgColor,
              NSColor(red: 1.00, green: 0.50, blue: 0.42, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
// Soft highlight, like light catching glass.
let glow = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.38).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 640, y: 700), startRadius: 0, endCenter: CGPoint(x: 640, y: 700), endRadius: 430, options: [])

// Four-point sparkles.
func sparkle(center: CGPoint, radius: CGFloat, pinch: CGFloat, alpha: CGFloat) {
    let p = CGMutablePath()
    let pts = [CGPoint(x: center.x, y: center.y + radius), CGPoint(x: center.x + radius, y: center.y),
               CGPoint(x: center.x, y: center.y - radius), CGPoint(x: center.x - radius, y: center.y)]
    p.move(to: pts[0])
    for i in 1...4 {
        let next = pts[i % 4]
        let control = CGPoint(x: center.x + (pts[i - 1].x + next.x - 2 * center.x) * pinch,
                              y: center.y + (pts[i - 1].y + next.y - 2 * center.y) * pinch)
        p.addQuadCurve(to: next, control: control)
    }
    p.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: NSColor.white.withAlphaComponent(0.7).cgColor)
    ctx.addPath(p); ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor); ctx.fillPath()
    ctx.restoreGState()
}
sparkle(center: CGPoint(x: 470, y: 500), radius: 250, pinch: 0.10, alpha: 1)
sparkle(center: CGPoint(x: 720, y: 730), radius: 96, pinch: 0.10, alpha: 0.95)
sparkle(center: CGPoint(x: 730, y: 330), radius: 58, pinch: 0.10, alpha: 0.85)
ctx.restoreGState()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
