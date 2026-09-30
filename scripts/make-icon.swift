// Draws the app icon as vectors (so every size is rendered crisp) and packs Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift [preview.png [pixels]]
// SF Symbols may not be used in app icons (license), hence the hand-built shapes.
import AppKit

let outline = CGColor(srgbRed: 0.97, green: 0.95, blue: 0.92, alpha: 1)
let mint = CGColor(srgbRed: 0.24, green: 0.88, blue: 0.76, alpha: 1)
let night = CGColor(srgbRed: 0.09, green: 0.10, blue: 0.25, alpha: 1)
let gradientTop = CGColor(srgbRed: 0.33, green: 0.40, blue: 0.86, alpha: 1)
let gradientBottom = CGColor(srgbRed: 0.10, green: 0.11, blue: 0.30, alpha: 1)
let nosePink = CGColor(srgbRed: 1.0, green: 0.62, blue: 0.68, alpha: 1)

func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: [a, b, c])
    path.closeSubpath()
    return path
}

/// Fills with rounded corners by also stroking the outline (ear tips would otherwise be needle-sharp).
func fillRounded(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, radius: CGFloat) {
    ctx.setFillColor(color)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(radius * 2)
    ctx.setLineJoin(.round)
    ctx.addPath(path); ctx.fillPath()
    ctx.addPath(path); ctx.strokePath()
}

/// Drawing space is 1024×1024 with y pointing down; `scale` maps it to device pixels for shadows,
/// whose offset and blur ignore the CTM.
func drawIcon(_ ctx: CGContext, scale: CGFloat) {
    // Apple's 1024 icon grid: an 824pt body with ~22.5% corner radius and room for the shadow.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale,
                  color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(body)
    ctx.setFillColor(gradientBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let colors = [gradientTop, gradientBottom] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // Soft light behind the head so the silhouette doesn't sit on a flat field.
    let glowColors = [CGColor(srgbRed: 0.55, green: 0.65, blue: 1, alpha: 0.35), CGColor(srgbRed: 0.55, green: 0.65, blue: 1, alpha: 0)] as CFArray
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glowColors, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 520), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 520), endRadius: 420, options: [])

    // Cat, composited as one layer so it casts a single shadow.
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 30 * scale, color: CGColor(gray: 0, alpha: 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Tail: leaves from behind the head and curls up into a network node.
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 600, y: 700))
    tail.addCurve(to: CGPoint(x: 810, y: 730), control1: CGPoint(x: 680, y: 800), control2: CGPoint(x: 770, y: 800))
    tail.addCurve(to: CGPoint(x: 790, y: 390), control1: CGPoint(x: 880, y: 640), control2: CGPoint(x: 870, y: 450))
    ctx.addPath(tail)
    ctx.setStrokeColor(outline)
    ctx.setLineWidth(58)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Outer base corners sit inside the head outline so the rounded joins don't bulge past the cheeks.
    let ears = [
        [CGPoint(x: 305, y: 460), CGPoint(x: 274, y: 250), CGPoint(x: 425, y: 392)],
        [CGPoint(x: 635, y: 460), CGPoint(x: 666, y: 250), CGPoint(x: 515, y: 392)],
    ]
    for ear in ears { fillRounded(ctx, triangle(ear[0], ear[1], ear[2]), outline, radius: 22) }
    ctx.setFillColor(outline)
    ctx.fillEllipse(in: CGRect(x: 240, y: 375, width: 460, height: 375))
    ctx.endTransparencyLayer()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    let innerEar = CGColor(srgbRed: 0.99, green: 0.76, blue: 0.79, alpha: 1)
    for ear in ears {
        let cx = ear.map(\.x).reduce(0, +) / 3, cy = ear.map(\.y).reduce(0, +) / 3
        let inner = ear.map { CGPoint(x: cx + ($0.x - cx) * 0.55, y: cy + ($0.y - cy) * 0.55 + 10) }
        fillRounded(ctx, triangle(inner[0], inner[1], inner[2]), innerEar, radius: 10)
    }

    // Eyes glow like a cat's at night; slit pupils keep them readable at 16px.
    for x in [390.0, 550.0] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 18 * scale, color: mint.copy(alpha: 0.8))
        ctx.setFillColor(mint)
        ctx.fillEllipse(in: CGRect(x: x - 42, y: 520, width: 84, height: 96))
        ctx.restoreGState()
        ctx.setFillColor(night)
        ctx.fillEllipse(in: CGRect(x: x - 10, y: 530, width: 20, height: 76))
    }

    fillRounded(ctx, triangle(CGPoint(x: 448, y: 648), CGPoint(x: 492, y: 648), CGPoint(x: 470, y: 672)), nosePink, radius: 6)

    // Tail tip node.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26 * scale, color: mint)
    ctx.setFillColor(mint)
    ctx.fillEllipse(in: CGRect(x: 790 - 40, y: 390 - 40, width: 80, height: 80))
    ctx.restoreGState()
    ctx.setFillColor(outline)
    ctx.fillEllipse(in: CGRect(x: 790 - 16, y: 390 - 16, width: 32, height: 32))
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawIcon(ctx, scale: scale)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let args = Array(CommandLine.arguments.dropFirst())
if let preview = args.first {
    let pixels = args.count > 1 ? Int(args[1]) ?? 1024 : 1024
    try render(pixels: pixels).write(to: URL(fileURLWithPath: preview))
    exit(0)
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", "Resources/AppIcon.icns", iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Wrote Resources/AppIcon.icns")
