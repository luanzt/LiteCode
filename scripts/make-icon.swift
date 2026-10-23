// Renders the app icon: `swift scripts/make-icon.swift <output.png>` (1024×1024).
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.86, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.45, alpha: 1),
])!.draw(in: path, angle: -90)

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let text = NSAttributedString(string: "</>", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 300, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph,
])
let textSize = text.size()
text.draw(in: NSRect(x: rect.minX, y: rect.midY - textSize.height / 2, width: rect.width, height: textSize.height))
image.unlockFocus()

let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
