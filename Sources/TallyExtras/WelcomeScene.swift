import SwiftUI
import AppKit
import TallyCore

extension Palette {
    /// A process dot before it folds into its app.
    static let welcomeProcessDot = Color.dynamic(light: 0xB2C3D9, dark: 0x3F4C60)
    /// The two orbits the app icons sit on.
    static let welcomeRing = Color.dynamic(light: 0x007AFF, dark: 0x409CFF, lightAlpha: 0.16, darkAlpha: 0.22)
    /// The soft light behind the app count.
    static let welcomeGlow = Color.dynamic(light: 0x007AFF, dark: 0x0A84FF, lightAlpha: 0.13, darkAlpha: 0.16)
}

/// Everything the intro needs, captured once from the first sample so nothing jumps while the store updates.
struct WelcomeScene {
    struct Dot {
        /// Where the dot sits at first, in unit coordinates of the window.
        var position: CGPoint
        var radius: CGFloat
        var alpha: Double
        var delay: Double
        /// The ring icon of the app this process belongs to; nil folds it into the count in the middle.
        var target: Int?
        var bend: CGFloat
    }

    struct RingIcon: Identifiable {
        var id: String { app.id }
        var app: AppUsage
        var isInner: Bool
        /// Clockwise from the right, in radians.
        var angle: Double
        var size: CGFloat
        /// Nil for a black, white or grey icon, which gets no coloured glow.
        var tint: Color?
    }

    var processCount: Int
    var appCount: Int
    var dots: [Dot]
    /// The apps with the most processes, busiest first: the inner ring, then the outer one.
    var icons: [RingIcon]
    var activityMonitorPath: String?

    static let innerLimit = 6
    static let outerLimit = 10
    /// How many ring icons stay on, in a row above the feature list.
    static let rowLimit = 10
    static let innerIconSize: CGFloat = 44
    static let outerIconSize: CGFloat = 36

    @MainActor
    init(store: TallyStore) {
        processCount = store.processCount
        appCount = store.apps.count
        activityMonitorPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")?.path

        let ownBundlePath = Bundle.main.bundleIdentifier == nil ? nil : Bundle.main.bundlePath
        // Apps inside a simulator runtime cannot run on the Mac, so their icons are a "prohibited" sign.
        let candidates = store.apps.filter { app in
            app.kind != .system && app.bundlePath != ownBundlePath && !(app.bundlePath ?? app.id).contains("/CoreSimulator/")
        }
        let bundled = candidates.filter { $0.kind == .app && $0.bundlePath != nil }
        let pool = bundled.count >= Self.innerLimit ? bundled : candidates
        let chosen = pool
            .sorted { $0.processCount != $1.processCount ? $0.processCount > $1.processCount : $0.memoryBytes > $1.memoryBytes }
            .prefix(Self.innerLimit + Self.outerLimit)

        let innerCount = min(chosen.count, Self.innerLimit)
        let outerCount = chosen.count - innerCount
        icons = chosen.enumerated().map { rank, app in
            let isInner = rank < innerCount
            let slot = isInner ? rank : rank - innerCount
            let count = Double(isInner ? innerCount : outerCount)
            // Inner icons start up and to the left of the top, outer icons at the top, so the two rings interleave.
            let start = isInner ? -118.0 : -92.0
            let angle = (start + 360 * Double(slot) / count) * .pi / 180
            let image = AppIconCache.shared.icon(for: app)
            return RingIcon(
                app: app,
                isInner: isInner,
                angle: angle,
                size: isInner ? Self.innerIconSize : Self.outerIconSize,
                tint: WelcomeTint.dominant(of: image)
            )
        }

        var iconIndexByApp: [String: Int] = [:]
        for (index, icon) in icons.enumerated() { iconIndexByApp[icon.app.id] = index }
        var appByPid: [Int32: String] = [:]
        for app in store.apps {
            for process in app.processes { appByPid[process.pid] = app.id }
        }

        dots = store.processes.map { process in
            var generator = SeededGenerator(seed: UInt64(UInt32(bitPattern: process.pid)) &* 0x2545_F491_4F6C_DD1D &+ 17)
            let size = Double.random(in: 0...1, using: &generator)
            return Dot(
                position: CGPoint(x: Double.random(in: 0.01...0.99, using: &generator), y: Double.random(in: 0.015...0.985, using: &generator)),
                radius: 1 + 2.4 * pow(size, 2.2),
                alpha: Double.random(in: 0.35...1, using: &generator),
                delay: Double.random(in: 0...0.9, using: &generator),
                target: appByPid[process.pid].flatMap { iconIndexByApp[$0] },
                bend: Double.random(in: -0.2...0.2, using: &generator)
            )
        }
    }
}

/// Where the rings sit in a window of a given size. They are a little wider than tall, to use a landscape window.
struct WelcomeRings {
    let center: CGPoint
    let outer: CGSize
    let inner: CGSize

    init(size: CGSize) {
        center = CGPoint(x: size.width / 2, y: size.height * 0.51)
        let outerHeight = min(size.height * 0.41, 240)
        let outerWidth = min(outerHeight * 1.24, size.width * 0.4)
        outer = CGSize(width: outerWidth, height: outerHeight)
        inner = CGSize(width: outerWidth * 0.66, height: outerHeight * 0.66)
    }

    func position(of icon: WelcomeScene.RingIcon) -> CGPoint {
        let radii = icon.isInner ? inner : outer
        return CGPoint(x: center.x + cos(icon.angle) * radii.width, y: center.y + sin(icon.angle) * radii.height)
    }
}

/// An app icon's main colour, for its glow and for the dots that fly into it.
enum WelcomeTint {
    private static let side = 16

    /// The average of the icon's colourful pixels, or nil for a black, white or grey icon.
    static func dominant(of image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for pixel in 0..<(side * side) {
            let alpha = Double(bytes[pixel * 4 + 3]) / 255
            guard alpha > 0.5 else { continue }
            let pixelRed = Double(bytes[pixel * 4]) / 255 / alpha
            let pixelGreen = Double(bytes[pixel * 4 + 1]) / 255 / alpha
            let pixelBlue = Double(bytes[pixel * 4 + 2]) / 255 / alpha
            let brightest = max(pixelRed, pixelGreen, pixelBlue)
            let darkest = min(pixelRed, pixelGreen, pixelBlue)
            let saturation = brightest > 0 ? (brightest - darkest) / brightest : 0
            let pixelWeight = saturation * saturation * brightest
            red += pixelRed * pixelWeight
            green += pixelGreen * pixelWeight
            blue += pixelBlue * pixelWeight
            weight += pixelWeight
        }
        guard weight > Double(side * side) * 0.03 else { return nil }

        let average = NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: max(saturation, 0.55), brightness: max(brightness, 0.8))
    }
}

/// A small deterministic generator, so each process keeps its place between frames.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x1234_5678 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
