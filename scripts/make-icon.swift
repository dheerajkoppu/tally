// Writes the Tally app icon: the Icon Composer document Resources/AppIcon.icon (vector layers and icon.json),
// Resources/AppIcon.icns (the flattened fallback that actool renders from that document) and the README pictures
// docs/images/icon.png and docs/images/icon-256.png.
// Run from the package root: swift scripts/make-icon.swift [--previews <directory>]
// The geometry and colors match LogoGeometry in Sources/TallyExtras/TallyLogoMark.swift.
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct DisplayP3 {
    let red: Double, green: Double, blue: Double, alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(grey: Double) {
        self.init(grey, grey, grey)
    }

    var encoded: String {
        "display-p3:" + [red, green, blue, alpha].map { String(format: "%.5f", $0) }.joined(separator: ",")
    }

    /// Hex for the SVG layers, which the document marks as Display P3.
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

/// An app tile in the pile, in points of the 1024 canvas (0,0 top left).
struct Tile {
    let name: String
    let center: CGPoint
    let side: CGFloat
    let degrees: CGFloat
    let top: DisplayP3
    let bottom: DisplayP3
    /// Value in the Mono (clear and tinted) appearances, so the tiles still separate without colour.
    let mono: Double
}

let tiles = [
    Tile(name: "back", center: CGPoint(x: 397, y: 440), side: 487, degrees: -16,
         top: DisplayP3(1.00, 0.46, 0.57), bottom: DisplayP3(0.85, 0.15, 0.33), mono: 0.28),
    Tile(name: "middle", center: CGPoint(x: 459, y: 502), side: 487, degrees: -8,
         top: DisplayP3(1.00, 0.80, 0.30), bottom: DisplayP3(0.96, 0.54, 0.04), mono: 0.40),
    Tile(name: "front", center: CGPoint(x: 538, y: 581), side: 510, degrees: 0,
         top: DisplayP3(0.28, 0.85, 0.53), bottom: DisplayP3(0.02, 0.55, 0.28), mono: 0.54),
]
let tileCornerRatio: CGFloat = 0.25
/// The 2×2 grid of app cells on the front tile, as shares of the tile side.
let cellRatio: CGFloat = 0.21
let cellGapRatio: CGFloat = 0.068
let badgeCenter = CGPoint(x: 777, y: 342)
let badgeRadius: CGFloat = 121
let badgeText = "5"

let backgroundTop = DisplayP3(0.27, 0.275, 0.30)
let backgroundBottom = DisplayP3(0.075, 0.08, 0.09)
let darkBackgroundTop = DisplayP3(0.16, 0.165, 0.18)
let darkBackgroundBottom = DisplayP3(0.03, 0.03, 0.035)
let badgeTop = DisplayP3(1.00, 0.45, 0.39)
let badgeBottom = DisplayP3(0.85, 0.12, 0.07)

struct Fill: Encodable {
    struct Orientation: Encodable {
        struct Point: Encodable { let x: Double, y: Double }
        let start: Point, stop: Point
    }

    var solid: String?
    var linearGradient: [String]?
    var orientation: Orientation?

    enum CodingKeys: String, CodingKey {
        case solid
        case linearGradient = "linear-gradient"
        case orientation
    }

    static func solid(_ color: DisplayP3) -> Fill {
        Fill(solid: color.encoded)
    }

    static func gradient(_ from: DisplayP3, _ to: DisplayP3) -> Fill {
        Fill(
            linearGradient: [from.encoded, to.encoded],
            orientation: Orientation(start: .init(x: 0.5, y: 0), stop: .init(x: 0.5, y: 1))
        )
    }
}

/// A value for every appearance (`appearance` nil), or an override for "dark" or "tinted" (Mono).
struct Specialization<Value: Encodable>: Encodable {
    var appearance: String?
    let value: Value
}

struct Layer: Encodable {
    let name: String
    let imageName: String
    var fillSpecializations: [Specialization<Fill>]?

    enum CodingKeys: String, CodingKey {
        case name
        case imageName = "image-name"
        case fillSpecializations = "fill-specializations"
    }

    /// Keeps the SVG's own colours, with a flat value in the Mono appearances.
    static func colored(_ name: String, mono: Double) -> Layer {
        Layer(name: name, imageName: "\(name).svg", fillSpecializations: [
            Specialization(appearance: "tinted", value: .solid(DisplayP3(grey: mono))),
        ])
    }
}

struct Group: Encodable {
    struct Shadow: Encodable { let kind: String, opacity: Double }
    struct Translucency: Encodable { let enabled: Bool, value: Double }

    let name: String
    let layers: [Layer]
    let shadow: Shadow
    let specular: Bool
    let translucency: Translucency
}

struct IconDocument: Encodable {
    struct Platforms: Encodable { let squares: [String] }

    let fillSpecializations: [Specialization<Fill>]
    let groups: [Group]
    let supportedPlatforms: Platforms
    /// The SVG layers' hex colours are read as Display P3.
    let svgColorSpace = "display-p3"

    enum CodingKeys: String, CodingKey {
        case fillSpecializations = "fill-specializations"
        case groups
        case supportedPlatforms = "supported-platforms"
        case svgColorSpace = "color-space-for-untagged-svg-colors"
    }
}

func tileGroup(_ tile: Tile, extraLayers: [Layer] = []) -> Group {
    Group(
        name: tile.name.capitalized,
        layers: extraLayers + [Layer.colored("\(tile.name)-tile", mono: tile.mono)],
        shadow: .init(kind: "layer-color", opacity: 0.8),
        specular: true,
        translucency: .init(enabled: false, value: 0)
    )
}

// Groups and their layers run front to back: the badge, then the front tile down to the back one.
// The system adds the mask, specular highlights and shadows.
let document = IconDocument(
    fillSpecializations: [
        Specialization(value: .gradient(backgroundTop, backgroundBottom)),
        Specialization(appearance: "dark", value: .gradient(darkBackgroundTop, darkBackgroundBottom)),
    ],
    groups: [
        Group(
            name: "Badge",
            layers: [Layer.colored("badge-count", mono: 1), Layer.colored("badge", mono: 0.4)],
            shadow: .init(kind: "neutral", opacity: 0.5),
            specular: true,
            translucency: .init(enabled: false, value: 0)
        ),
        tileGroup(tiles[2], extraLayers: [Layer.colored("front-grid", mono: 1)]),
        tileGroup(tiles[1]),
        tileGroup(tiles[0]),
    ],
    supportedPlatforms: .init(squares: ["macOS"])
)

func number(_ value: CGFloat) -> String {
    String(format: "%.1f", value)
}

/// SVG path data for a Core Graphics path.
func pathData(_ path: CGPath) -> String {
    var commands: [String] = []
    path.applyWithBlock { pointer in
        let element = pointer.pointee
        let points = element.points
        switch element.type {
        case .moveToPoint:
            commands.append("M\(number(points[0].x)) \(number(points[0].y))")
        case .addLineToPoint:
            commands.append("L\(number(points[0].x)) \(number(points[0].y))")
        case .addQuadCurveToPoint:
            commands.append("Q\(number(points[0].x)) \(number(points[0].y)) \(number(points[1].x)) \(number(points[1].y))")
        case .addCurveToPoint:
            commands.append("C\(number(points[0].x)) \(number(points[0].y)) \(number(points[1].x)) \(number(points[1].y)) \(number(points[2].x)) \(number(points[2].y))")
        case .closeSubpath:
            commands.append("Z")
        @unknown default:
            break
        }
    }
    return commands.joined(separator: " ")
}

func roundedSquare(center: CGPoint, side: CGFloat, cornerRatio: CGFloat, degrees: CGFloat = 0) -> CGPath {
    let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
    let shape = RoundedRectangle(cornerRadius: side * cornerRatio, style: .continuous).path(in: rect).cgPath
    var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: degrees * .pi / 180)
    return shape.copy(using: &transform)!
}

func svg(_ body: String, definitions: String = "") -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    \(definitions.isEmpty ? "" : "<defs>\(definitions)</defs>\n")\(body)
    </svg>

    """
}

/// A shape filled top to bottom with a gradient that follows the shape's own box.
func gradientSVG(_ path: CGPath, top: DisplayP3, bottom: DisplayP3) -> String {
    let definitions = ##"<linearGradient id="fill" x1="0.2" y1="0" x2="0.55" y2="1"><stop offset="0" stop-color="\##(top.hex)"/><stop offset="1" stop-color="\##(bottom.hex)"/></linearGradient>"##
    return svg(##"<path d="\##(pathData(path))" fill="url(#fill)"/>"##, definitions: definitions)
}

func whiteSVG(_ path: CGPath) -> String {
    svg(##"<path d="\##(pathData(path))" fill="#FFFFFF"/>"##)
}

func tilePath(_ tile: Tile) -> CGPath {
    roundedSquare(center: tile.center, side: tile.side, cornerRatio: tileCornerRatio, degrees: tile.degrees)
}

let front = tiles[2]
let grid = CGMutablePath()
let cell = front.side * cellRatio
let cellGap = front.side * cellGapRatio
for row in 0..<2 {
    for column in 0..<2 {
        let offset = CGPoint(x: (CGFloat(column) - 0.5) * (cell + cellGap), y: (CGFloat(row) - 0.5) * (cell + cellGap))
        grid.addPath(roundedSquare(center: CGPoint(x: front.center.x + offset.x, y: front.center.y + offset.y), side: cell, cornerRatio: 0.28))
    }
}

/// The badge count as outlines in SF Pro Rounded Bold, centred in the badge.
func countPath() -> CGPath {
    let base = NSFont.systemFont(ofSize: badgeRadius * 1.3, weight: .bold)
    let font = (NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: base.pointSize) ?? base) as CTFont
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: badgeText, attributes: [.font: font]))
    let outline = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        for index in 0..<count {
            guard let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
            outline.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
        }
    }
    let bounds = outline.boundingBoxOfPath
    // Glyphs are y-up; flip into the canvas and centre on the badge.
    var transform = CGAffineTransform(translationX: badgeCenter.x - bounds.midX, y: badgeCenter.y + bounds.midY).scaledBy(x: 1, y: -1)
    return outline.copy(using: &transform)!
}

func run(_ executable: String, _ arguments: [String], quiet: Bool = false) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if quiet {
        process.standardOutput = FileHandle.nullDevice
    }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("\(executable) \(arguments.joined(separator: " ")) failed with status \(process.terminationStatus)")
    }
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let bundle = resources.appendingPathComponent("AppIcon.icon", isDirectory: true)
let assets = bundle.appendingPathComponent("Assets", isDirectory: true)

try? fileManager.removeItem(at: bundle)
try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
let layers: [String: String] = [
    "back-tile": gradientSVG(tilePath(tiles[0]), top: tiles[0].top, bottom: tiles[0].bottom),
    "middle-tile": gradientSVG(tilePath(tiles[1]), top: tiles[1].top, bottom: tiles[1].bottom),
    "front-tile": gradientSVG(tilePath(tiles[2]), top: tiles[2].top, bottom: tiles[2].bottom),
    "front-grid": whiteSVG(grid),
    "badge": gradientSVG(CGPath(ellipseIn: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2), transform: nil), top: badgeTop, bottom: badgeBottom),
    "badge-count": whiteSVG(countPath()),
]
for (name, contents) in layers {
    try contents.write(to: assets.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(document).write(to: bundle.appendingPathComponent("icon.json"))
print("Wrote \(bundle.path)")

let compiled = fileManager.temporaryDirectory.appendingPathComponent("tally-icon-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: compiled, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: compiled) }
try run("/usr/bin/xcrun", [
    "actool", bundle.path, "--compile", compiled.path,
    "--output-format", "human-readable-text", "--notices", "--warnings", "--errors",
    "--output-partial-info-plist", compiled.appendingPathComponent("partial.plist").path,
    "--app-icon", "AppIcon", "--platform", "macosx", "--target-device", "mac",
    "--minimum-deployment-target", "15.0", "--standalone-icon-behavior", "all",
])
let icns = resources.appendingPathComponent("AppIcon.icns")
try? fileManager.removeItem(at: icns)
try fileManager.copyItem(at: compiled.appendingPathComponent("AppIcon.icns"), to: icns)
print("Wrote \(icns.path)")

let developer = Process()
let pipe = Pipe()
developer.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
developer.arguments = ["-p"]
developer.standardOutput = pipe
try developer.run()
developer.waitUntilExit()
let developerPath = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let ictool = URL(fileURLWithPath: developerPath)
    .deletingLastPathComponent()
    .appendingPathComponent("Applications/Icon Composer.app/Contents/Executables/ictool").path

func export(_ rendition: String, size: Int, generation: Int = 27, to file: URL) throws {
    try run(ictool, [
        bundle.path, "--export-image", "--output-file", file.path,
        "--platform", "macOS", "--rendition", rendition, "--width", "\(size)", "--height", "\(size)",
        "--scale", "1", "--design-generation", "\(generation)",
    ], quiet: true)
}

/// ictool writes 16-bit Display P3; the README and website get a smaller 8-bit sRGB copy.
func exportForWeb(size: Int, to file: URL) throws {
    let exported = compiled.appendingPathComponent("web-\(size).png")
    try export("Default", size: size, to: exported)
    guard let source = CGImageSourceCreateWithURL(exported as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("Could not read \(exported.path)") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let converted = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Could not write \(file.path)") }
    CGImageDestinationAddImage(destination, converted, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(file.path)") }
}

let images = root.appendingPathComponent("docs/images", isDirectory: true)
try fileManager.createDirectory(at: images, withIntermediateDirectories: true)
try exportForWeb(size: 1024, to: images.appendingPathComponent("icon.png"))
try exportForWeb(size: 256, to: images.appendingPathComponent("icon-256.png"))
print("Wrote \(images.path)/icon.png and icon-256.png")

if let flag = CommandLine.arguments.firstIndex(of: "--previews"), CommandLine.arguments.count > flag + 1 {
    let previews = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    try fileManager.createDirectory(at: previews, withIntermediateDirectories: true)
    for generation in [26, 27] {
        for rendition in ["Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark"] {
            try export(rendition, size: 512, generation: generation, to: previews.appendingPathComponent("\(rendition)-512-macOS\(generation).png"))
        }
        for size in [64, 32, 16] {
            for rendition in ["Default", "Dark", "TintedDark", "ClearLight"] {
                try export(rendition, size: size, generation: generation, to: previews.appendingPathComponent("\(rendition)-\(size)-macOS\(generation).png"))
            }
        }
    }
    print("Wrote previews to \(previews.path)")
}
