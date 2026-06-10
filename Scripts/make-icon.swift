// Renders the app icon (1024×1024 master PNG) — a macOS-style squircle with
// a VM console motif: dark gradient, terminal screen, green play/prompt.
// Run via Scripts/make-icon.sh which assembles the .icns.
import AppKit

let size: CGFloat = 1024
// Apple's icon grid: content squircle is 824pt of a 1024 canvas, r≈185.
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = 185

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Background squircle — deep slate gradient (terminal-dark, slightly blue).
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1),
])!.draw(in: bg, angle: -90)

// Soft top sheen.
let sheen = NSBezierPath(roundedRect: rect.insetBy(dx: 14, dy: 14), xRadius: radius - 14, yRadius: radius - 14)
NSGradient(colors: [
    NSColor(calibratedWhite: 1, alpha: 0.10),
    NSColor(calibratedWhite: 1, alpha: 0.0),
])!.draw(in: sheen, angle: -90)

// Monitor bezel.
let screenOuter = NSRect(x: 222, y: 330, width: 580, height: 420)
let bezel = NSBezierPath(roundedRect: screenOuter, xRadius: 46, yRadius: 46)
NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.65, alpha: 1).setFill()
bezel.fill()

// Screen — near-black with a hint of green glow.
let screenRect = screenOuter.insetBy(dx: 26, dy: 26)
let screen = NSBezierPath(roundedRect: screenRect, xRadius: 26, yRadius: 26)
NSGradient(colors: [
    NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.07, alpha: 1),
    NSColor(calibratedRed: 0.01, green: 0.03, blue: 0.02, alpha: 1),
])!.draw(in: screen, angle: -90)

let green = NSColor(calibratedRed: 0.30, green: 0.95, blue: 0.45, alpha: 1)

// Small terminal-prompt accent, top-left of the screen.
let mono = NSFont.monospacedSystemFont(ofSize: 84, weight: .bold)
(">" as NSString).draw(at: NSPoint(x: screenRect.minX + 42, y: screenRect.maxY - 140),
                       withAttributes: [.font: mono, .foregroundColor: green])
green.withAlphaComponent(0.85).setFill()
NSRect(x: screenRect.minX + 110, y: screenRect.maxY - 128, width: 46, height: 78).fill()

// Big centered play triangle (start the VM) with a soft glow.
let cx = screenRect.midX + 14, cy = screenRect.midY - 34
let r: CGFloat = 118
let play = NSBezierPath()
play.move(to: NSPoint(x: cx - r * 0.62, y: cy + r))
play.line(to: NSPoint(x: cx - r * 0.62, y: cy - r))
play.line(to: NSPoint(x: cx + r * 1.05, y: cy))
play.close()
NSGraphicsContext.current?.cgContext.setShadow(
    offset: .zero, blur: 60,
    color: green.withAlphaComponent(0.8).cgColor)
green.setFill()
play.fill()
NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

// Stand.
NSColor(calibratedRed: 0.45, green: 0.48, blue: 0.55, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 472, y: 268, width: 80, height: 70), xRadius: 12, yRadius: 12).fill()
NSBezierPath(roundedRect: NSRect(x: 372, y: 232, width: 280, height: 44), xRadius: 22, yRadius: 22).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
