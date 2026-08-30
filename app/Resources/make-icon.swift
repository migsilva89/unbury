import AppKit
import CoreGraphics

// The mark: a bookmark ribbon cut out of the plate, with the five bars of the
// match meter behind it — the one thing in the interface you look at to know
// whether an answer is worth trusting. Drawn rather than generated, so it stays
// crisp at 16pt where most icons turn to mud.

let bg1 = NSColor(srgbRed: 0.114, green: 0.118, blue: 0.129, alpha: 1)  // #1D1E21
let bg2 = NSColor(srgbRed: 0.043, green: 0.047, blue: 0.051, alpha: 1)  // #0B0C0D
let accent = NSColor(srgbRed: 0.229, green: 0.663, blue: 0.624, alpha: 1) // #3AA99F
let faint = NSColor(srgbRed: 0.35, green: 0.36, blue: 0.36, alpha: 1)

/// Apple's squircle, close enough for an app icon: a superellipse.
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = cy + b * pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func draw(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icons sit inside their canvas with a margin, or they look oversized
    // next to every other icon in the Dock.
    let inset = size * 0.09
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = squircle(plate)

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space,
                              colors: [bg1.cgColor, bg2.cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY), options: [])

    // Two marks on one baseline: the bookmark on the left, and the match meter
    // climbing away from it. One says what this holds, the other says what it
    // does with it.
    let unit = plate.width / 100
    let baseY = plate.minY + unit * 27

    // Four bars, not five: at 16 points a fifth bar closes the gaps and the
    // whole mark turns into a smudge. The meter must end well inside the plate.
    let barW = unit * 6.5, gap = unit * 4.5
    let meterX = plate.minX + unit * 51
    for i in 0..<4 {
        let height = unit * (10 + Double(i) * 9.5)
        let rect = CGRect(x: meterX + Double(i) * (barW + gap), y: baseY,
                          width: barW, height: height)
        ctx.setFillColor(i >= 2 ? accent.cgColor : faint.withAlphaComponent(0.5).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barW / 2.4,
                           cornerHeight: barW / 2.4, transform: nil))
        ctx.fillPath()
    }

    // The bookmark: a solid shape, not a hole. Filled a shade darker than the
    // plate so it reads as an object sitting on it, with an accent edge.
    let ribbonW = unit * 27, ribbonH = unit * 47
    let rx = plate.minX + unit * 15
    let ry = baseY
    let notch = unit * 13
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: rx, y: ry))
    ribbon.addLine(to: CGPoint(x: rx, y: ry + ribbonH))
    ribbon.addLine(to: CGPoint(x: rx + ribbonW, y: ry + ribbonH))
    ribbon.addLine(to: CGPoint(x: rx + ribbonW, y: ry))
    ribbon.addLine(to: CGPoint(x: rx + ribbonW / 2, y: ry + notch))
    ribbon.closeSubpath()

    ctx.addPath(ribbon)
    ctx.setFillColor(NSColor(srgbRed: 0.02, green: 0.023, blue: 0.027, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.addPath(ribbon)
    ctx.setStrokeColor(accent.cgColor)
    ctx.setLineWidth(max(1.2, unit * 3.2))
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // The rim every macOS icon has, or it looks pasted on.
    ctx.addPath(shape)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.setLineWidth(max(1, size * 0.005))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = draw(size: CGFloat(size))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon_\(size).png"))
}
print("desenhado em \(out)")
