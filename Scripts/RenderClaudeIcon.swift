// 25 October 2026, 20:55 CEST: renders the I1 app icon (terracotta squircle, glass highlight, white SF Symbol mic.fill) chosen by Matthieu.
// FR : icône I1, carré arrondi terracotta, reflet de verre, mic.fill blanc. Usage : swift RenderClaudeIcon.swift <out.iconset>
import AppKit
struct IconParams {
    static let squircle: CGFloat = 824 / 1024      // macOS icon grid: 824 pt body on a 1024 canvas
    static let radiusRatio: CGFloat = 0.225
    static let symbolRatio: CGFloat = 0.56          // mic.fill height relative to the squircle
    static let top = NSColor(srgbRed: 233/255, green: 151/255, blue: 122/255, alpha: 1)
    static let mid = NSColor(srgbRed: 217/255, green: 119/255, blue: 87/255, alpha: 1)
    static let bottom = NSColor(srgbRed: 189/255, green: 95/255, blue: 64/255, alpha: 1)
    static let highlight: CGFloat = 0.28
}
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let side = s * IconParams.squircle, origin = (s - side) / 2
    let rect = NSRect(x: origin, y: origin, width: side, height: side)
    let path = NSBezierPath(roundedRect: rect, xRadius: side * IconParams.radiusRatio, yRadius: side * IconParams.radiusRatio)
    let shadow = NSShadow(); shadow.shadowColor = NSColor(srgbRed: 0.47, green: 0.2, blue: 0.08, alpha: 0.22)
    shadow.shadowBlurRadius = side * 0.035; shadow.shadowOffset = NSSize(width: 0, height: -side * 0.015)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); IconParams.mid.setFill(); path.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [IconParams.top, IconParams.mid, IconParams.bottom], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!.draw(in: path, angle: -70)
    // Glass highlight clipped to the squircle, fading out at mid height. / reflet limité à la forme, effacé à mi-hauteur.
    NSGraphicsContext.saveGraphicsState(); path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(IconParams.highlight), NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: rect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let config = NSImage.SymbolConfiguration(pointSize: side * IconParams.symbolRatio, weight: .semibold).applying(.init(paletteColors: [.white]))
    let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let ms = mic.size, k = (side * IconParams.symbolRatio) / ms.height
    mic.draw(in: NSRect(x: s / 2 - ms.width * k / 2, y: s / 2 - ms.height * k / 2, width: ms.width * k, height: ms.height * k))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    try! render(px).write(to: out.appendingPathComponent(name + ".png"))
}
print("iconset ok")
