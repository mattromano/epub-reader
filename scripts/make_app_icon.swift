// Renders the Margins app icon (1024×1024, opaque PNG) into the asset catalog.
// Run: swift scripts/make_app_icon.swift Margins/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
// Opaque RGB (no alpha): App Store icons must not be transparent.
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Background: deep ink-blue gradient.
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [CGColor(red: 0.11, green: 0.17, blue: 0.32, alpha: 1),
                             CGColor(red: 0.05, green: 0.08, blue: 0.17, alpha: 1)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// The page: a warm paper card.
let page = CGRect(x: 232, y: 152, width: 560, height: 720)
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 48, color: CGColor(gray: 0, alpha: 0.45))
ctx.setFillColor(CGColor(red: 0.98, green: 0.95, blue: 0.89, alpha: 1))
ctx.addPath(CGPath(roundedRect: page, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// The margin rule.
let marginX = page.minX + 132
ctx.setStrokeColor(CGColor(red: 0.85, green: 0.36, blue: 0.30, alpha: 1))
ctx.setLineWidth(10)
ctx.move(to: CGPoint(x: marginX, y: page.minY + 70))
ctx.addLine(to: CGPoint(x: marginX, y: page.maxY - 70))
ctx.strokePath()

// Text lines, one of them highlighted.
let lineLeft = marginX + 46, lineRight = page.maxX - 64
let lineYs = stride(from: page.maxY - 130, through: page.minY + 120, by: -86).map { $0 }
for (i, y) in lineYs.enumerated() {
    let right = i == lineYs.count - 1 ? lineLeft + (lineRight - lineLeft) * 0.55 : lineRight
    if i == 3 {
        ctx.setFillColor(CGColor(red: 1.0, green: 0.80, blue: 0.20, alpha: 0.85))
        ctx.addPath(CGPath(roundedRect: CGRect(x: lineLeft - 14, y: y - 30, width: right - lineLeft + 28, height: 60),
                           cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
    }
    ctx.setStrokeColor(CGColor(red: 0.24, green: 0.27, blue: 0.36, alpha: 0.9))
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: lineLeft, y: y))
    ctx.addLine(to: CGPoint(x: right, y: y))
    ctx.strokePath()
}

// A note mark in the margin next to the highlight.
let noteY = lineYs[3]
ctx.setFillColor(CGColor(red: 0.85, green: 0.36, blue: 0.30, alpha: 1))
ctx.fillEllipse(in: CGRect(x: page.minX + 50, y: noteY - 20, width: 40, height: 40))

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(out)") }
print("wrote \(out)")
