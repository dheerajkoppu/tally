import AppKit
import TallyCore

/// Draws the menu bar item as one image: a template in the normal state so it follows the menu bar,
/// full colour when the warning sign replaces the stack glyph.
enum StatusItemArtwork {
    /// Everything the item shows. The image is rebuilt only when this changes.
    struct Content: Equatable {
        var style: MenuBarStyle
        var metrics: [MenuBarMetric]
        var texts: [String]
        /// Graph bar heights in half points, oldest first.
        var bars: [UInt8]
        var warning: StrainLevel?
    }

    static let height: CGFloat = max(18, min(NSStatusBar.system.thickness, 24))
    static let graphLevels = Int(graphSize.height * 2)

    private static let glyphSize = NSSize(width: 16, height: 14)
    private static let warningWidth: CGFloat = 17
    private static let glyphGap: CGFloat = 5
    private static let graphSize = NSSize(width: 29, height: 11)
    private static let barWidth: CGFloat = 2.2
    private static let stackedColumnGap: CGFloat = 6
    private static let stackedLineGap: CGFloat = 2

    private static let figureFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    private static let captionFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    /// The icon-only style, also used before the first sample. Drawn once.
    static let glyphImage: NSImage = {
        let image = NSImage(size: glyphSize, flipped: true) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: stackPath(in: rect)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tally"
        return image
    }()

    /// The glyph at the left of the wider styles, built once for the item height.
    private static let composedGlyph = NSBezierPath(cgPath: stackPath(in: NSRect(x: 0, y: 0, width: glyphSize.width, height: height)))

    private static let warningSymbols: [StrainLevel: NSImage] = {
        var symbols: [StrainLevel: NSImage] = [:]
        for (level, color) in [(StrainLevel.warning, NSColor.systemOrange), (.critical, .systemRed)] {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, color]))
            symbols[level] = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
                .withSymbolConfiguration(configuration)
        }
        return symbols
    }()

    /// Text colours: black for the template image, label colours (resolved against the menu bar) for the warning image.
    private struct Ink {
        var primary: NSColor
        var secondary: NSColor

        static let template = Ink(primary: .black, secondary: NSColor.black.withAlphaComponent(0.6))
        static let warning = Ink(primary: .labelColor, secondary: .secondaryLabelColor)
    }

    private struct PlacedText {
        var string: NSAttributedString
        var origin: NSPoint
    }

    private enum TextRole: Int {
        case figure, caption, value

        var font: NSFont {
            switch self {
            case .figure: StatusItemArtwork.figureFont
            case .caption: StatusItemArtwork.captionFont
            case .value: StatusItemArtwork.valueFont
            }
        }
    }

    @MainActor private static var measuredWidths: [String: CGFloat] = [:]

    @MainActor
    private static func width(_ text: String, _ role: TextRole) -> CGFloat {
        let key = "\(role.rawValue)|\(text)"
        if let cached = measuredWidths[key] { return cached }
        if measuredWidths.count > 512 { measuredWidths.removeAll(keepingCapacity: true) }
        let measured = ceil(NSAttributedString(string: text, attributes: [.font: role.font]).size().width)
        measuredWidths[key] = measured
        return measured
    }

    @MainActor
    static func image(for content: Content) -> NSImage {
        if content.style == .icon, content.warning == nil { return glyphImage }
        let height = Self.height
        let warning = content.warning
        let ink = warning == nil ? Ink.template : Ink.warning
        let glyphWidth = warning == nil ? glyphSize.width : warningWidth
        var x = glyphWidth
        var texts: [PlacedText] = []
        var graphRect: NSRect?

        func place(_ text: String, _ role: TextRole, color: NSColor, x: CGFloat, baseline: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = role == .caption
                ? [.font: role.font, .foregroundColor: color, .kern: 0.2]
                : [.font: role.font, .foregroundColor: color]
            texts.append(PlacedText(string: NSAttributedString(string: text, attributes: attributes), origin: NSPoint(x: x, y: baseline - role.font.ascender)))
        }

        switch content.style {
        case .icon:
            break
        case .figure, .graph:
            if content.style == .graph, !content.bars.isEmpty {
                x += glyphGap
                graphRect = NSRect(x: x, y: ((height - graphSize.height) / 2).rounded(), width: graphSize.width, height: graphSize.height)
                x += graphSize.width
            }
            if let text = content.texts.first, let metric = content.metrics.first {
                x += glyphGap
                let textWidth = width(text, .figure)
                let reserved = max(textWidth, width(MenuBarReadings.widthTemplate(for: metric, compact: false), .figure))
                let baseline = ((height + figureFont.capHeight) / 2).rounded()
                place(text, .figure, color: ink.primary, x: x + reserved - textWidth, baseline: baseline)
                x += reserved
            }
        case .stacked:
            x += glyphGap
            let block = captionFont.capHeight + stackedLineGap + valueFont.capHeight
            let captionBaseline = ((height - block) / 2 + captionFont.capHeight).rounded()
            let valueBaseline = ((captionBaseline + stackedLineGap + valueFont.capHeight) * 2).rounded() / 2
            for (index, metric) in content.metrics.enumerated() where index < content.texts.count {
                if index > 0 { x += stackedColumnGap }
                let caption = metric.shortLabel
                let value = content.texts[index]
                let captionWidth = width(caption, .caption)
                let valueWidth = width(value, .value)
                let column = max(captionWidth, valueWidth, width(MenuBarReadings.widthTemplate(for: metric, compact: true), .value))
                place(caption, .caption, color: ink.secondary, x: x + (column - captionWidth) / 2, baseline: captionBaseline)
                place(value, .value, color: ink.primary, x: x + (column - valueWidth) / 2, baseline: valueBaseline)
                x += column
            }
        }

        let bars = content.bars
        let image = NSImage(size: NSSize(width: ceil(x), height: height), flipped: true) { _ in
            let glyphRect = NSRect(x: 0, y: 0, width: glyphWidth, height: height)
            if let warning {
                drawWarning(warning, in: glyphRect)
            } else {
                NSColor.black.setFill()
                composedGlyph.fill()
            }
            if let graphRect {
                drawBars(bars, in: graphRect, color: warning == nil ? .black : .labelColor)
            }
            for text in texts {
                text.string.draw(at: text.origin)
            }
            return true
        }
        image.isTemplate = warning == nil
        return image
    }

    /// The pile of tiles from the app icon: three rounded squares stepping down and to the right, the front one cut
    /// with a 2×2 grid of app cells. Whole-point geometry on a 14 pt grid keeps every edge on the pixel grid at 1x and 2x.
    static func stackPath(in rect: NSRect) -> CGPath {
        let origin = CGPoint(x: (rect.midX - 7).rounded(.down), y: (rect.midY - 7).rounded(.down))
        func square(_ offset: CGFloat, outset: CGFloat = 0) -> CGPath {
            let frame = CGRect(x: origin.x + offset, y: origin.y + offset, width: 10, height: 10).insetBy(dx: -outset, dy: -outset)
            return CGPath(roundedRect: frame, cornerWidth: 2.5 + outset, cornerHeight: 2.5 + outset, transform: nil)
        }
        let cells = CGMutablePath()
        for row in 0..<2 {
            for column in 0..<2 {
                let cell = CGRect(x: origin.x + 6 + CGFloat(column) * 4, y: origin.y + 6 + CGFloat(row) * 4, width: 2, height: 2)
                cells.addRoundedRect(in: cell, cornerWidth: 0.5, cornerHeight: 0.5)
            }
        }
        // Each square gives up a 1 pt gap around the one in front of it.
        return square(0).subtracting(square(2, outset: 1))
            .union(square(2).subtracting(square(4, outset: 1)))
            .union(square(4).subtracting(cells))
    }

    private static func drawBars(_ levels: [UInt8], in rect: NSRect, color: NSColor) {
        guard !levels.isEmpty else { return }
        let slot = rect.width / CGFloat(levels.count)
        let width = min(barWidth, slot)
        let radius = min(width / 2, 1)
        color.setFill()
        for (index, level) in levels.enumerated() {
            let barHeight = max(1.5, CGFloat(level) / 2)
            let barX = rect.minX + CGFloat(index) * slot + (slot - width) / 2
            let bar = NSRect(x: barX, y: rect.maxY - barHeight, width: width, height: barHeight)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bar.minX, y: bar.maxY))
            path.line(to: NSPoint(x: bar.minX, y: bar.minY + radius))
            path.appendArc(withCenter: NSPoint(x: bar.minX + radius, y: bar.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: bar.maxX - radius, y: bar.minY))
            path.appendArc(withCenter: NSPoint(x: bar.maxX - radius, y: bar.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: bar.maxX, y: bar.maxY))
            path.close()
            path.fill()
        }
    }

    private static func drawWarning(_ level: StrainLevel, in rect: NSRect) {
        guard let symbol = warningSymbols[level] else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(origin: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), size: size))
    }
}
