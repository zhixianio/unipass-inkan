// Renders one full-bleed artwork (SVG or PNG) into the two master PNGs.
//
//   swift render.swift <source.svg|png> <full-bleed out.png> <macos out.png>
//
//   full-bleed  1024x1024, opaque sRGB, no alpha (the iOS icon is one of these)
//   macos       the artwork on the macOS (Big Sur) icon grid: an 824x824 continuous-corner
//               squircle (~185 px corner radius) centered in a transparent 1024 canvas,
//               with a soft drop shadow
//
// AppKit renders plain SVG; SVG filters (the textured version) need a browser, so render.sh
// rasterizes that one with headless Chrome first and passes the PNG here.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write("usage: swift render.swift <source.svg|png> <full-bleed out.png> <macos out.png>\n".data(using: .utf8)!)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: args[1])
guard let art = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write("cannot load \(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let side = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(alpha: Bool) -> CGContext {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: info.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func drawArt(in rect: CGRect, ctx: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    art.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(_ ctx: CGContext, _ path: String) {
    let url = URL(fileURLWithPath: path)
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
    print("wrote \(url.path)")
}

/// Rounded rect with continuous (curvature-continuous) corners, like Apple's icon shape.
/// Each corner is a superellipse quadrant spanning `1.528 * radius` along both edges;
/// the exponent is chosen so the corner's 45-degree point sits where a circular corner of `radius` would.
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let s = 1.528665 * r
    let n: CGFloat = 3.3
    let steps = 48
    let path = CGMutablePath()
    // corners in order (counter-clockwise in CG space): bottom-left, bottom-right, top-right, top-left.
    // (cx, cy) = superellipse centre, (dx, dy) = direction towards the corner.
    let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (rect.minX + s, rect.minY + s, -1, -1),
        (rect.maxX - s, rect.minY + s, 1, -1),
        (rect.maxX - s, rect.maxY - s, 1, 1),
        (rect.minX + s, rect.maxY - s, -1, 1),
    ]
    for (i, (cx, cy, dx, dy)) in corners.enumerated() {
        for k in 0...steps {
            var t = CGFloat(k) / CGFloat(steps) * .pi / 2
            // walk each corner from the edge we arrive on to the edge we leave on
            if i % 2 == 1 { t = .pi / 2 - t }
            let px = cx + dx * s * pow(cos(t), 2 / n)
            let py = cy + dy * s * pow(sin(t), 2 / n)
            if i == 0 && k == 0 { path.move(to: CGPoint(x: px, y: py)) } else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
    }
    path.closeSubpath()
    return path
}

// 1. Full-bleed opaque master.
do {
    let ctx = makeContext(alpha: false)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    drawArt(in: CGRect(x: 0, y: 0, width: side, height: side), ctx: ctx)
    writePNG(ctx, args[2])
}

// 2. macOS icon on the Big Sur grid.
do {
    let ctx = makeContext(alpha: true)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body, radius: 185)

    // soft drop shadow (CG y axis points up, so a negative offset falls below)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.95, blue: 0.91, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // artwork clipped to the squircle
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    drawArt(in: body, ctx: ctx)
    ctx.restoreGState()

    // hairline edge so the light paper still separates from light backgrounds
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.25, blue: 0.15, alpha: 0.12))
    ctx.setLineWidth(4) // 2 px visible inside the clip
    ctx.strokePath()
    ctx.restoreGState()

    writePNG(ctx, args[3])
}
