import AppKit

/// Caches app and tool icons as flat 8-bit sRGB bitmaps. Main-thread only.
/// Workspace icons are extended-range images; drawn as-is, one of them makes `ImageRenderer`
/// tone-map a whole view grey, which breaks exported images and harness renders.
@MainActor
public final class AppIconCache {
    public static let shared = AppIconCache()

    /// Twice the largest size an icon is drawn at (60 pt in the welcome window).
    private static let pixelSize = 128
    /// Tools with one-off paths (build products, temporary binaries) would otherwise pile up for the life of the app.
    private static let cacheLimit = 256
    private var cache: [String: NSImage] = [:]

    private init() {}

    public func icon(for app: AppUsage) -> NSImage {
        switch app.kind {
        case .app:
            if let path = app.bundlePath { return icon(forPath: path) }
            if app.id.hasPrefix("/") { return icon(forPath: app.id) }
        case .system:
            return systemIcon
        case .tool:
            if let path = app.processes.first?.executablePath { return icon(forPath: path) }
            if app.id.hasPrefix("/") { return icon(forPath: app.id) }
        }
        return genericIcon
    }

    /// Icon for a history entry, where the app may no longer be running.
    public func icon(appID: String, bundlePath: String?) -> NSImage {
        if appID == "system" { return systemIcon }
        if let bundlePath { return icon(forPath: bundlePath) }
        if appID.hasPrefix("/") { return icon(forPath: appID) }
        return genericIcon
    }

    public func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        // Resolved so an app linked into /Applications (Safari) shows no alias arrow.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let image = Self.flatten(NSWorkspace.shared.icon(forFile: resolved))
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[path] = image
        return image
    }

    public func icon(forBundlePath path: String?) -> NSImage {
        guard let path else { return genericIcon }
        return icon(forPath: path)
    }

    /// The "macOS" group icon.
    public lazy var systemIcon: NSImage = {
        if let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            return icon(forPath: settings.path)
        }
        return genericIcon
    }()

    public lazy var genericIcon: NSImage = {
        Self.flatten(NSWorkspace.shared.icon(for: .unixExecutable))
    }()

    private static func flatten(_ icon: NSImage) -> NSImage {
        let pixels = pixelSize
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return icon }
        context.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return icon }
        return NSImage(cgImage: cgImage, size: NSSize(width: pixels / 2, height: pixels / 2))
    }
}
