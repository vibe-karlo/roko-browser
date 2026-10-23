// Draws the roko app icon (design option K, "Warp star, graphite") at 1024 px.
// Run: swift Scripts/make_app_icon.swift Browser/Resources/Assets.xcassets/AppIcon.appiconset
// Geometry is the design's SVG: viewBox "0 0 200 100", path
// "M0 50C50 48 88 40 100 12C112 40 150 48 200 50C150 52 112 60 100 88C88 60 50 52 0 50Z",
// drawn 260 px wide, centred, inside a 360 px tile.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let scale = size / 360 * 260 / 200

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(background: CGColor?, mark: CGColor, to name: String) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    // Work in the SVG's own units, y pointing down, the 200 × 100 box centred.
    context.translateBy(x: size / 2, y: size / 2)
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: -100, y: -50)

    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 50))
    path.addCurve(to: CGPoint(x: 100, y: 12), control1: CGPoint(x: 50, y: 48), control2: CGPoint(x: 88, y: 40))
    path.addCurve(to: CGPoint(x: 200, y: 50), control1: CGPoint(x: 112, y: 40), control2: CGPoint(x: 150, y: 48))
    path.addCurve(to: CGPoint(x: 100, y: 88), control1: CGPoint(x: 150, y: 52), control2: CGPoint(x: 112, y: 60))
    path.addCurve(to: CGPoint(x: 0, y: 50), control1: CGPoint(x: 88, y: 60), control2: CGPoint(x: 50, y: 52))
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(mark)
    context.fillPath()

    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

let graphite = color(0xA9A9A9)
render(background: color(0x1A1A1B), mark: graphite, to: "AppIcon.png")
render(background: nil, mark: graphite, to: "AppIcon-Dark.png")
render(background: nil, mark: color(0xFFFFFF), to: "AppIcon-Tinted.png")
