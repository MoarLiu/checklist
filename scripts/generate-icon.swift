import AppKit

// 出账日 product mark. Render vector geometry directly at every icon size.
// Coordinates use SVG's top-left origin on a 1024-square canvas.
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let brandDirectory = URL(fileURLWithPath: "Resources/Brand", isDirectory: true)
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: brandDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
            green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255, alpha: 1).cgColor
}
let tile = CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864),
                  cornerWidth: 192, cornerHeight: 192, transform: nil)
let page = CGMutablePath()
page.move(to: CGPoint(x: 320, y: 268))
page.addLine(to: CGPoint(x: 704, y: 268))
page.addCurve(to: CGPoint(x: 768, y: 332), control1: CGPoint(x: 739, y: 268), control2: CGPoint(x: 768, y: 297))
page.addLine(to: CGPoint(x: 768, y: 652))
page.addLine(to: CGPoint(x: 656, y: 764))
page.addLine(to: CGPoint(x: 320, y: 764))
page.addCurve(to: CGPoint(x: 256, y: 700), control1: CGPoint(x: 285, y: 764), control2: CGPoint(x: 256, y: 735))
page.addLine(to: CGPoint(x: 256, y: 332))
page.addCurve(to: CGPoint(x: 320, y: 268), control1: CGPoint(x: 256, y: 297), control2: CGPoint(x: 285, y: 268))
page.closeSubpath()
let fold = CGMutablePath()
fold.move(to: CGPoint(x: 656, y: 764))
fold.addLine(to: CGPoint(x: 656, y: 682))
fold.addQuadCurve(to: CGPoint(x: 686, y: 652), control: CGPoint(x: 656, y: 652))
fold.addLine(to: CGPoint(x: 768, y: 652))
fold.closeSubpath()
let check = CGMutablePath()
check.move(to: CGPoint(x: 374, y: 530))
check.addLine(to: CGPoint(x: 468, y: 620))
check.addLine(to: CGPoint(x: 648, y: 448))

func drawGradient(_ context: CGContext, path: CGPath, colors: [UInt32], start: CGPoint, end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors.map(color) as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func render(size: Int) throws -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    drawGradient(context, path: tile, colors: [0x3FF0CD, 0x0FBFA0],
                 start: CGPoint(x: 220, y: 80), end: CGPoint(x: 820, y: 944))
    context.addPath(tile)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.48).cgColor)
    context.setLineWidth(5)
    context.strokePath()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 20,
                      color: NSColor(srgbRed: 0.01, green: 0.25, blue: 0.20, alpha: 0.18).cgColor)
    context.addPath(page)
    context.setFillColor(color(0xF4FFFB))
    context.fillPath()
    context.restoreGState()
    drawGradient(context, path: page, colors: [0xFFFFFF, 0xE5FFF7],
                 start: CGPoint(x: 400, y: 268), end: CGPoint(x: 650, y: 764))
    context.addPath(fold)
    context.setFillColor(color(0xA9E9D8))
    context.fillPath()
    context.move(to: CGPoint(x: 300, y: 382))
    context.addLine(to: CGPoint(x: 724, y: 382))
    context.setStrokeColor(color(0xD3F6EA))
    context.setLineWidth(10)
    context.setLineCap(.round)
    context.strokePath()
    for x in [364, 612] {
        let binding = CGPath(roundedRect: CGRect(x: x, y: 216, width: 48, height: 100),
                             cornerWidth: 24, cornerHeight: 24, transform: nil)
        context.addPath(binding)
        context.setFillColor(color(0x134E4A))
        context.fillPath()
    }
    context.addPath(check)
    context.setStrokeColor(color(0x134E4A))
    context.setLineWidth(62)
    context.setLineJoin(.round)
    context.strokePath()
    context.addEllipse(in: CGRect(x: 718, y: 244, width: 88, height: 88))
    context.setFillColor(color(0xFFCA57))
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(10)
    context.drawPath(using: .fillStroke)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="出账日：账单日历、还款勾和到期提醒点">
  <defs>
    <linearGradient id="tile" x1="220" y1="80" x2="820" y2="944" gradientUnits="userSpaceOnUse"><stop stop-color="#3FF0CD"/><stop offset="1" stop-color="#0FBFA0"/></linearGradient>
    <linearGradient id="paper" x1="400" y1="268" x2="650" y2="764" gradientUnits="userSpaceOnUse"><stop stop-color="#FFFFFF"/><stop offset="1" stop-color="#E5FFF7"/></linearGradient>
    <filter id="shadow" x="-30%" y="-30%" width="160%" height="170%"><feDropShadow dx="0" dy="12" stdDeviation="10" flood-color="#034033" flood-opacity=".18"/></filter>
  </defs>
  <rect x="80" y="80" width="864" height="864" rx="192" fill="url(#tile)" stroke="#FFFFFF" stroke-opacity=".48" stroke-width="5"/>
  <path d="M320 268H704C739 268 768 297 768 332V652L656 764H320C285 764 256 735 256 700V332C256 297 285 268 320 268Z" fill="url(#paper)" filter="url(#shadow)"/>
  <path d="M656 764V682Q656 652 686 652H768Z" fill="#A9E9D8"/>
  <path d="M300 382H724" stroke="#D3F6EA" stroke-width="10" stroke-linecap="round"/>
  <rect x="364" y="216" width="48" height="100" rx="24" fill="#134E4A"/>
  <rect x="612" y="216" width="48" height="100" rx="24" fill="#134E4A"/>
  <path d="M374 530L468 620L648 448" fill="none" stroke="#134E4A" stroke-width="62" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="762" cy="288" r="44" fill="#FFCA57" stroke="#FFFFFF" stroke-width="10"/>
</svg>
"""
try svg.write(to: brandDirectory.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)
try render(size: 1024).write(to: brandDirectory.appendingPathComponent("logo.png"))
for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    try render(size: size).write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
}
print("Generated SVG, transparent 1024 PNG and all macOS icon sizes.")
