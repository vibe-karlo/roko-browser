// Draws roko's app icons from the logo design file (marks J, K, T3, F): the
// default, the Eclipse in the app's colours, with its dark and tinted versions,
// and the alternates, as 1024 px app icon sets plus small previews for the
// Settings picker. Icons designed as whole tiles (Scripts/icons/*.svg, named for
// their icon set) are drawn as they are. Given a third path, the Raycast
// extension's icon goes there too: the default, rounded.
// Run: swift Scripts/make_alternate_icons.swift Browser/Resources/Assets.xcassets [Raycast/assets/icon.png]
import AppKit

struct Mark {
    let viewBox: (x: Double, y: Double, w: Double, h: Double)
    /// Width of the mark as a share of the tile, as drawn in the design.
    let widthShare: Double
    let body: (String) -> String  // fill colour → SVG elements
}

let star = Mark(viewBox: (0, 0, 200, 100), widthShare: 150.0 / 200) {
    "<path d=\"M0 50C50 48 88 40 100 12C112 40 150 48 200 50C150 52 112 60 100 88C88 60 50 52 0 50Z\" fill=\"\($0)\"/>"
}
let chevrons = Mark(viewBox: (-12, -10, 160, 140), widthShare: 116.0 / 200) {
    "<g fill=\"\($0)\"><polygon points=\"0,0 28,0 80,52 52,52\"/><polygon points=\"52,68 80,68 28,120 0,120\"/><polygon points=\"56,0 84,0 136,52 108,52\"/><polygon points=\"108,68 136,68 84,120 56,120\"/></g>"
}
let forwardPlus = Mark(viewBox: (30, -6, 180, 112), widthShare: 140.0 / 200) {
    "<path d=\"M92 0H108V28Q108 42 122 42H200V58H122Q108 58 108 72V100H92V72Q92 58 78 58H40V42H78Q92 42 92 28Z\" fill=\"\($0)\"/>"
}
let rollingO = Mark(viewBox: (5, 0, 200, 200), widthShare: 236.0 / 360) {
    "<path d=\"M20 150H140A50 50 0 1 0 139.99 150\" fill=\"none\" stroke=\"\($0)\" stroke-width=\"26\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
}

/// A disc with a smaller disc cut out, set off to the right: on the 1024 tile,
/// radius 300 at the centre, hole of radius 150 moved 94 to the right. The hole
/// is cut (even-odd), so the tile shows through it in any colourway.
let eclipse = Mark(viewBox: (0, 0, 600, 600), widthShare: 600.0 / 1024) {
    "<path fill-rule=\"evenodd\" fill=\"\($0)\" d=\"M0 300A300 300 0 1 0 600 300A300 300 0 1 0 0 300ZM244 300A150 150 0 1 0 544 300A150 150 0 1 0 244 300Z\"/>"
}

/// Icon set name, mark, tile colour, mark colour.
let icons: [(String, Mark, String, String)] = [
    ("AppIcon-Star", star, "#1A1A1B", "#A9A9A9"),
    ("AppIcon-StarOrange", star, "#050506", "#FF5B1F"),
    ("AppIcon-StarFlame", star, "#FF5B1F", "#0E0E0F"),
    ("AppIcon-ChevronsGraphite", chevrons, "#1A1A1B", "#A9A9A9"),
    ("AppIcon-Plus", forwardPlus, "#050506", "#FF5B1F"),
    ("AppIcon-RollingO", rollingO, "#15171B", "#FF5B1F"),
    // In the app's own colours: the dark canvas (Theme.canvas) and the accent.
    // (The cream one, Theme.ink on the canvas, is the default now.)
    ("AppIcon-EclipseOnOrange", eclipse, "#FF5B1F", "#0E0E0F"),
    ("AppIcon-EclipseOrange", eclipse, "#0E0E0F", "#FF5B1F"),
]

/// The default: the Eclipse in the light ink text is set in (Theme.ink) on the
/// dark canvas (Theme.canvas), as in dark mode.
let defaultIcon = (mark: eclipse, tile: "#0E0E0F", color: "#E7E7E4")

/// `tile` nil: the mark alone on transparent, for the dark and tinted icons iOS draws its own tile under.
func svg(_ mark: Mark, tile: String?, color: String, size: Double) -> String {
    let width = size * mark.widthShare
    let scale = width / mark.viewBox.w
    let height = mark.viewBox.h * scale
    let x = (size - width) / 2 - mark.viewBox.x * scale
    let y = (size - height) / 2 - mark.viewBox.y * scale
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(size)" height="\(size)" viewBox="0 0 \(size) \(size)">
    \(tile.map { "<rect width=\"\(size)\" height=\"\(size)\" fill=\"\($0)\"/>" } ?? "")
    <g transform="translate(\(x) \(y)) scale(\(scale))">\(mark.body(color))</g>
    </svg>
    """
}

/// `inset`: the share of the canvas left clear around the tile, as macOS icons
/// sit on their grid (824 of 1024), so the icon matches its neighbours' size.
func png(_ svgText: String, pixels: Int, to url: URL, rounded: Bool = false, inset: Double = 0) {
    let image = NSImage(data: Data(svgText.utf8))!
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let margin = Double(pixels) * inset
    let rect = NSRect(x: margin, y: margin, width: Double(pixels) - 2 * margin, height: Double(pixels) - 2 * margin)
    if rounded { NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225).addClip() }
    image.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// A whole tile from Scripts/icons, rendered at any size.
func designed(_ name: String) -> String {
    let file = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("icons/\(name).svg")
    return try! String(contentsOf: file, encoding: .utf8)
}

/// Their order in the picker.
let designedIcons = ["AppIcon-Ro", "AppIcon-RoOnOrange", "AppIcon-Octagon", "AppIcon-OctagonOnOrange",
                     "AppIcon-Wordmark", "AppIcon-WordmarkOnOrange"]

func writeJSON(_ object: Any, to url: URL) {
    try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

let catalog = URL(fileURLWithPath: CommandLine.arguments[1])
let previews = catalog.appendingPathComponent("iconpreview")
try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
writeJSON(["info": ["author": "xcode", "version": 1], "properties": ["provides-namespace": true]],
          to: previews.appendingPathComponent("Contents.json"))

// The default: light, dark (the mark alone, iOS draws the dark tile) and tinted (white, iOS tints it).
let defaultSet = catalog.appendingPathComponent("AppIcon.appiconset")
png(svg(defaultIcon.mark, tile: defaultIcon.tile, color: defaultIcon.color, size: 1024), pixels: 1024,
    to: defaultSet.appendingPathComponent("AppIcon.png"))
png(svg(defaultIcon.mark, tile: nil, color: defaultIcon.color, size: 1024), pixels: 1024,
    to: defaultSet.appendingPathComponent("AppIcon-Dark.png"))
png(svg(defaultIcon.mark, tile: nil, color: "#FFFFFF", size: 1024), pixels: 1024,
    to: defaultSet.appendingPathComponent("AppIcon-Tinted.png"))
if CommandLine.arguments.count > 2 {
    png(svg(defaultIcon.mark, tile: defaultIcon.tile, color: defaultIcon.color, size: 512), pixels: 512,
        to: URL(fileURLWithPath: CommandLine.arguments[2]), rounded: true, inset: 100.0 / 1024)
}

for (name, mark, tile, color) in icons + [("AppIcon", defaultIcon.mark, defaultIcon.tile, defaultIcon.color)] {
    if name != "AppIcon" {
        let set = catalog.appendingPathComponent("\(name).appiconset")
        try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        png(svg(mark, tile: tile, color: color, size: 1024), pixels: 1024, to: set.appendingPathComponent("icon.png"))
        writeJSON(["images": [["filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
                   "info": ["author": "xcode", "version": 1]], to: set.appendingPathComponent("Contents.json"))
    }
    // The picker's preview, already rounded like a home screen icon.
    let preview = previews.appendingPathComponent("\(name).imageset")
    try? FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    png(svg(mark, tile: tile, color: color, size: 180), pixels: 180, to: preview.appendingPathComponent("preview.png"), rounded: true)
    writeJSON(["images": [["filename": "preview.png", "idiom": "universal"]], "info": ["author": "xcode", "version": 1]],
              to: preview.appendingPathComponent("Contents.json"))
    print(name)
}

for name in designedIcons {
    let tile = designed(name)
    let set = catalog.appendingPathComponent("\(name).appiconset")
    try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    png(tile, pixels: 1024, to: set.appendingPathComponent("icon.png"))
    writeJSON(["images": [["filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
               "info": ["author": "xcode", "version": 1]], to: set.appendingPathComponent("Contents.json"))
    let preview = previews.appendingPathComponent("\(name).imageset")
    try? FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    png(tile, pixels: 180, to: preview.appendingPathComponent("preview.png"), rounded: true)
    writeJSON(["images": [["filename": "preview.png", "idiom": "universal"]], "info": ["author": "xcode", "version": 1]],
              to: preview.appendingPathComponent("Contents.json"))
    print(name)
}
