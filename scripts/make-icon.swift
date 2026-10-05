// Writes the Tally app icon: the Icon Composer document Resources/AppIcon.icon (vector layers and icon.json),
// Resources/AppIcon.icns (the flattened fallback that actool renders from that document) and the README pictures
// docs/images/icon.png and docs/images/icon-256.png.
// Run from the package root: swift scripts/make-icon.swift [--previews <directory>]
// The geometry and colors match LogoGeometry in Sources/TallyExtras/TallyLogoMark.swift.
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SRGB {
    let red: Double, green: Double, blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(grey: Double) {
        red = grey
        green = grey
        blue = grey
    }

    var encoded: String {
        "extended-srgb:" + [red, green, blue, 1].map { String(format: "%.5f", $0) }.joined(separator: ",")
    }
}

/// The turning points of the activity trace, in points of the 1024 canvas (0,0 top left). It runs in from beyond
/// the left edge, spikes once, settles and ends in a dot.
let tracePoints = [
    CGPoint(x: -80, y: 596), CGPoint(x: 172, y: 596), CGPoint(x: 248, y: 646), CGPoint(x: 338, y: 204),
    CGPoint(x: 430, y: 812), CGPoint(x: 526, y: 438), CGPoint(x: 610, y: 626), CGPoint(x: 688, y: 518),
    CGPoint(x: 780, y: 566),
]
/// How far each curve's handles reach toward the next turning point; smaller makes sharper peaks.
let traceHandleRatio: CGFloat = 0.32
let traceWidth: CGFloat = 38
let dotRadius: CGFloat = 38
/// The graph paper behind the trace: this many cells across and down.
let gridDivisions = 5
let gridLineWidth: CGFloat = 6

/// The app's accent (Palette in Sources/TallyCore/Design/Theme.swift), lifted so it carries on the dark body.
let traceColor = SRGB(0x6F6DF7)
let gridColor = SRGB(0x393A41)
let background = SRGB(0x1F2024)
let darkBackground = SRGB(0x131417)

struct Fill: Encodable {
    var solid: String?
    var automaticGradient: String?

    enum CodingKeys: String, CodingKey {
        case solid
        case automaticGradient = "automatic-gradient"
    }

    static func solid(_ color: SRGB) -> Fill {
        Fill(solid: color.encoded)
    }

    /// The system's own subtle gradient from one colour.
    static func automatic(_ color: SRGB) -> Fill {
        Fill(automaticGradient: color.encoded)
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
    let fillSpecializations: [Specialization<Fill>]

    enum CodingKeys: String, CodingKey {
        case name
        case imageName = "image-name"
        case fillSpecializations = "fill-specializations"
    }

    init(_ name: String, fill: Fill, mono: Double) {
        self.name = name
        imageName = "\(name).svg"
        fillSpecializations = [
            Specialization(value: fill),
            Specialization(appearance: "tinted", value: .solid(SRGB(grey: mono))),
        ]
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

    /// - Parameter isRaised: glass with a highlight and a shadow; the grid lies flat on the body instead.
    init(_ layer: Layer, isRaised: Bool) {
        name = layer.name.capitalized
        layers = [layer]
        shadow = Shadow(kind: isRaised ? "neutral" : "none", opacity: 0.7)
        specular = isRaised
        // Opaque layers keep the 27 renderer's edges sharp.
        translucency = Translucency(enabled: false, value: 0)
    }
}

struct IconDocument: Encodable {
    struct Platforms: Encodable { let squares: [String] }

    let fillSpecializations: [Specialization<Fill>]
    let groups: [Group]
    let supportedPlatforms: Platforms

    enum CodingKeys: String, CodingKey {
        case fillSpecializations = "fill-specializations"
        case groups
        case supportedPlatforms = "supported-platforms"
    }
}

// Groups and their layers run front to back. The system adds the mask, glass, specular highlights and shadows.
let document = IconDocument(
    fillSpecializations: [
        Specialization(value: .automatic(background)),
        Specialization(appearance: "dark", value: .automatic(darkBackground)),
    ],
    groups: [
        Group(Layer("trace", fill: .automatic(traceColor), mono: 1), isRaised: true),
        Group(Layer("grid", fill: .solid(gridColor), mono: 0.3), isRaised: false),
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

/// A smooth curve through the turning points, level at each one, so it never overshoots them.
func waveform(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.move(to: points[0])
    for (start, end) in zip(points, points.dropFirst()) {
        let reach = (end.x - start.x) * traceHandleRatio
        path.addCurve(to: end, control1: CGPoint(x: start.x + reach, y: start.y), control2: CGPoint(x: end.x - reach, y: end.y))
    }
    return path
}

/// A white shape on the square canvas; icon.json supplies the colour.
func svg(_ path: CGPath) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
    <path d="\(pathData(path))" fill="#FFFFFF"/>
    </svg>

    """
}

let end = tracePoints[tracePoints.count - 1]
let trace = waveform(tracePoints)
    .copy(strokingWithWidth: traceWidth, lineCap: .round, lineJoin: .round, miterLimit: 4)
    .union(CGPath(ellipseIn: CGRect(x: end.x - dotRadius, y: end.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2), transform: nil))

let grid = CGMutablePath()
for line in 1..<gridDivisions {
    let offset = 1024 * CGFloat(line) / CGFloat(gridDivisions) - gridLineWidth / 2
    grid.addRect(CGRect(x: offset, y: 0, width: gridLineWidth, height: 1024))
    grid.addRect(CGRect(x: 0, y: offset, width: 1024, height: gridLineWidth))
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
let layers = ["trace": svg(trace), "grid": svg(grid)]
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
], quiet: true)
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
