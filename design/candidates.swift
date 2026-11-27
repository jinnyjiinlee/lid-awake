import Cocoa
let W: CGFloat = 1500, H: CGFloat = 760
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
func sym(_ name: String, _ pt: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .semibold) -> NSImage? {
    guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pt, weight: weight)) else { return nil }
    let t = NSImage(size: s.size); t.lockFocus(); color.set()
    let r = NSRect(origin: .zero, size: s.size); s.draw(in: r); r.fill(using: .sourceAtop); t.unlockFocus(); return t
}
func drawC(_ i: NSImage?, cx: CGFloat, cy: CGFloat) { guard let i else { return }
    i.draw(in: NSRect(x: cx - i.size.width/2, y: cy - i.size.height/2, width: i.size.width, height: i.size.height)) }
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, bold: Bool = false, color: NSColor = .black) {
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular), .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: a); let w = str.size().width
    str.draw(at: NSPoint(x: x - w/2, y: y))
}
let navyTop = NSColor(red: 0.17, green: 0.24, blue: 0.55, alpha: 1), navyBot = NSColor(red: 0.04, green: 0.07, blue: 0.20, alpha: 1)
let sun = NSColor(red: 1.0, green: 0.78, blue: 0.15, alpha: 1)
struct C { let title: String; let on: String; let off: String; let draw: (CGFloat, CGFloat) -> Void }
let cands: [C] = [
  C(title: "1. 노트북 + 해", on: "sun.max.fill", off: "moon.zzz.fill", draw: { cx, cy in
      drawC(sym("laptopcomputer", 150, .white), cx: cx, cy: cy - 15)
      drawC(sym("sun.max.fill", 80, sun), cx: cx + 85, cy: cy + 85) }),
  C(title: "2. 노트북 + 눈 뜸", on: "eye.fill", off: "eye.slash", draw: { cx, cy in
      drawC(sym("laptopcomputer", 150, .white), cx: cx, cy: cy - 15)
      drawC(sym("eye.fill", 52, sun), cx: cx, cy: cy - 2) }),
  C(title: "3. 해 / 달", on: "sun.max.fill", off: "moon.fill", draw: { cx, cy in
      drawC(sym("sun.max.fill", 170, sun), cx: cx, cy: cy) }),
]
for (i, c) in cands.enumerated() {
    let cx = 250 + CGFloat(i) * 500, cy: CGFloat = 470
    let r = NSRect(x: cx - 160, y: cy - 160, width: 320, height: 320)
    NSGradient(starting: navyTop, ending: navyBot)!.draw(in: NSBezierPath(roundedRect: r, xRadius: 72, yRadius: 72), angle: -90)
    c.draw(cx, cy)
    text(c.title, cx, 680, 34, bold: true)
    // 메뉴바 미리보기
    let bar = NSRect(x: cx - 170, y: 150, width: 340, height: 90)
    NSColor(white: 0.93, alpha: 1).setFill(); NSBezierPath(roundedRect: bar, xRadius: 14, yRadius: 14).fill()
    drawC(sym(c.on, 40, .black, .medium), cx: cx - 75, cy: 195)
    drawC(sym(c.off, 40, .black, .medium), cx: cx + 75, cy: 195)
    text("켜짐", cx - 75, 100, 26); text("꺼짐", cx + 75, 100, 26)
    text("메뉴바 아이콘", cx, 40, 22, color: .gray)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
