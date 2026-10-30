// Draws Floe's app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift Resources/icon.swift
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func polygon(_ ctx: CGContext, _ pts: [(CGFloat, CGFloat)]) {
    ctx.beginPath()
    ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.closePath()
}

func fill(_ ctx: CGContext, _ pts: [(CGFloat, CGFloat)], _ c: CGColor) {
    polygon(ctx, pts)
    ctx.setFillColor(c)
    ctx.fillPath()
}

func gradient(_ ctx: CGContext, _ colors: [CGColor], from: CGFloat, to: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Canvas follows Apple's macOS grid: 1024 points, an 824-point rounded square with room for the shadow.
func draw(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let water: CGFloat = 470

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0E3F80))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Sky, then sea.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: water, width: 1024, height: 1024))
    gradient(ctx, [color(0xA6DDF8), color(0x55AEE6)], from: 924, to: water)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 0, y: 0, width: 1024, height: water))
    gradient(ctx, [color(0x1C6FC2), color(0x08265A)], from: water, to: 100)
    ctx.restoreGState()

    // The submerged part of the floe, larger than what shows above water.
    fill(ctx, [(270, water), (770, water), (820, 390), (770, 265), (620, 200), (430, 215), (320, 285), (255, 380)], color(0xFFFFFF, 0.24))
    fill(ctx, [(520, water), (770, water), (820, 390), (770, 265), (620, 200), (560, 330)], color(0xFFFFFF, 0.10))

    // Above water: a faceted slab.
    let top: [(CGFloat, CGFloat)] = [(270, water), (300, 575), (405, 640), (560, 668), (690, 625), (745, 545), (770, water)]
    ctx.saveGState()
    polygon(ctx, top)
    ctx.clip()
    gradient(ctx, [color(0xFFFFFF), color(0xE6F5FD)], from: 668, to: water)
    ctx.restoreGState()
    fill(ctx, [(560, 668), (690, 625), (745, 545), (770, water), (600, water), (585, 580)], color(0x8CC6EC, 0.75))
    fill(ctx, [(270, water), (300, 575), (405, 640), (380, 540), (330, water)], color(0xD2EDFB, 0.85))

    // Waterline and a couple of ripples.
    ctx.setStrokeColor(color(0xFFFFFF, 0.55))
    ctx.setLineCap(.round)
    ctx.setLineWidth(6)
    for (a, b) in [(150.0, 250.0), (790.0, 875.0)] {
        ctx.move(to: CGPoint(x: a, y: water))
        ctx.addLine(to: CGPoint(x: b, y: water))
    }
    ctx.strokePath()
    ctx.setLineWidth(5)
    ctx.setStrokeColor(color(0xFFFFFF, 0.25))
    for (a, b, y) in [(190.0, 260.0, 430.0), (800.0, 850.0, 425.0), (330.0, 400.0, 160.0)] {
        ctx.move(to: CGPoint(x: a, y: y))
        ctx.addLine(to: CGPoint(x: b, y: y))
    }
    ctx.strokePath()

    // A four-point glint in the sky.
    let (cx, cy, r): (CGFloat, CGFloat, CGFloat) = (745, 780, 46)
    fill(ctx, [(cx, cy + r), (cx + r * 0.22, cy + r * 0.22), (cx + r, cy), (cx + r * 0.22, cy - r * 0.22),
               (cx, cy - r), (cx - r * 0.22, cy - r * 0.22), (cx - r, cy), (cx - r * 0.22, cy + r * 0.22)], color(0xFFFFFF, 0.95))
    ctx.restoreGState()

    // Hairline edge so the tile reads on light and dark backgrounds.
    ctx.addPath(shape)
    ctx.setStrokeColor(color(0x000000, 0.10))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.interpolationQuality = .high
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! render(pt).write(to: set.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! render(pt * 2).write(to: set.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
try! render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/null"))
