// 앱 아이콘: 네이비 배경 + 흰 노트북 + 노란 해 (노트북이 깨어 있다)
import Cocoa
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let path = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.17, green: 0.24, blue: 0.55, alpha: 1),
           ending: NSColor(red: 0.04, green: 0.07, blue: 0.20, alpha: 1))!.draw(in: path, angle: -90)
func sym(_ name: String, _ pt: CGFloat, _ color: NSColor) -> NSImage {
    let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: pt, weight: .semibold))!
    let t = NSImage(size: s.size); t.lockFocus(); color.set()
    let r = NSRect(origin: .zero, size: s.size); s.draw(in: r); r.fill(using: .sourceAtop); t.unlockFocus(); return t
}
func drawC(_ i: NSImage, _ cx: CGFloat, _ cy: CGFloat) {
    i.draw(in: NSRect(x: cx - i.size.width/2, y: cy - i.size.height/2, width: i.size.width, height: i.size.height))
}
drawC(sym("laptopcomputer", 400, .white), 512, 470)
drawC(sym("sun.max.fill", 215, NSColor(red: 1.0, green: 0.78, blue: 0.15, alpha: 1)), 740, 740)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
