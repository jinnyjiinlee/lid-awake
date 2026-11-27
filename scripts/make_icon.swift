import Cocoa
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.17, green: 0.24, blue: 0.55, alpha: 1),
           ending: NSColor(red: 0.04, green: 0.07, blue: 0.20, alpha: 1))!.draw(in: path, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
if let sym = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size); tinted.lockFocus()
    NSColor.white.set(); let r = NSRect(origin: .zero, size: sym.size)
    sym.draw(in: r); r.fill(using: .sourceAtop); tinted.unlockFocus()
    let s = sym.size
    tinted.draw(in: NSRect(x: (size - s.width)/2, y: (size - s.height)/2 - 10, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
