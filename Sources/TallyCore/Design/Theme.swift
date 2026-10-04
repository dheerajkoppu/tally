import SwiftUI
import AppKit

extension Color {
    /// A color with separate light and dark values, given as 0xRRGGBB (and optional alpha).
    public static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        dynamic(light: light, dark: dark, increasedContrastLight: light, increasedContrastDark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha)
    }

    /// A color that also has stronger values for when Increase Contrast is on.
    public static func dynamic(light: UInt32, dark: UInt32, increasedContrastLight: UInt32, increasedContrastDark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1, increasedContrastAlpha: Double? = nil) -> Color {
        let lightColor = NSColor(hex: light, alpha: lightAlpha)
        let darkColor = NSColor(hex: dark, alpha: darkAlpha)
        let contrastLightColor = NSColor(hex: increasedContrastLight, alpha: increasedContrastAlpha ?? lightAlpha)
        let contrastDarkColor = NSColor(hex: increasedContrastDark, alpha: increasedContrastAlpha ?? darkAlpha)
        // SwiftUI resolves with a plain Aqua or Dark Aqua appearance, so the system setting is checked as well.
        return Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let isIncreased = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            switch (isDark, isIncreased) {
            case (false, false): return lightColor
            case (true, false): return darkColor
            case (false, true): return contrastLightColor
            case (true, true): return contrastDarkColor
            }
        })
    }
}

extension NSColor {
    public convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// The palette: neutral surfaces, one accent with two companions for charts, and three status colours.
/// Every color has a stronger variant that macOS picks when Increase Contrast is on. Secondary text reaches 4.5:1 on
/// cards and accents reach 3:1 as chart marks (4.5:1 with Increase Contrast); text in an accent goes through `LegibleTint`.
public enum Palette {
    public static let background = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    public static let card = Color.dynamic(light: 0xF5F5F7, dark: 0x2A2A2C)
    public static let cardHighlight = Color.dynamic(light: 0xE8E8ED, dark: 0x38383B, increasedContrastLight: 0xDCDCE2, increasedContrastDark: 0x47474B)
    /// Selected or top rows inside a card.
    public static let raised = Color.dynamic(light: 0xFFFFFF, dark: 0x353538)
    public static let ink = Color.dynamic(light: 0x1D1D1F, dark: 0xF5F5F7, increasedContrastLight: 0x000000, increasedContrastDark: 0xFFFFFF)
    public static let ink2 = Color.dynamic(light: 0x68686D, dark: 0xA1A1A6, increasedContrastLight: 0x3A3A3C, increasedContrastDark: 0xD1D1D6)
    /// Chevrons, placeholders and other marks that need 3:1, never small text.
    public static let ink3 = Color.dynamic(light: 0x8A8A8F, dark: 0x808085, increasedContrastLight: 0x55555A, increasedContrastDark: 0xB4B4B9)
    public static let line = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, increasedContrastLight: 0x000000, increasedContrastDark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10, increasedContrastAlpha: 0.32)
    /// The outline cards get when Increase Contrast is on.
    public static let cardEdge = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, increasedContrastLight: 0x000000, increasedContrastDark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.14, increasedContrastAlpha: 0.45)
    /// The 3:1 outline cards and controls get when Show Borders or Increase Contrast is on.
    public static let outline = Color.dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.45, darkAlpha: 0.42)

    /// The one colour every chart, gauge and selection uses.
    public static let accent = Color.dynamic(light: 0x5856D6, dark: 0x6B69F4, increasedContrastLight: 0x3F3DB8, increasedContrastDark: 0x9D9BFF)
    /// The second and third series beside the accent: system over user, wired and compressed over app.
    public static let accentSecond = Color.dynamic(light: 0x0A84FF, dark: 0x2E9BFF, increasedContrastLight: 0x0060C8, increasedContrastDark: 0x74BCFF)
    public static let accentThird = Color.dynamic(light: 0x12998A, dark: 0x3DD6C0, increasedContrastLight: 0x0A7468, increasedContrastDark: 0x7EE8D8)
    /// The unfilled part of a bar, ring or gauge.
    public static let track = Color.dynamic(light: 0x5856D6, dark: 0x8D8BFF, increasedContrastLight: 0x3F3DB8, increasedContrastDark: 0xB5B3FF, lightAlpha: 0.12, darkAlpha: 0.16, increasedContrastAlpha: 0.30)

    /// Status, never decoration: healthy, worth a look, needs attention.
    public static let good = Color.dynamic(light: 0x008300, dark: 0x30B845, increasedContrastLight: 0x006400, increasedContrastDark: 0x5CCB64)
    public static let caution = Color.dynamic(light: 0xC27400, dark: 0xF0A020, increasedContrastLight: 0x945600, increasedContrastDark: 0xFFC25C)
    public static let red = Color.dynamic(light: 0xE0352B, dark: 0xFF5A50, increasedContrastLight: 0xB0211A, increasedContrastDark: 0xFF807A)

    /// Memory-by-type segments.
    public static let memoryApp = accent
    public static let memoryWired = accentSecond
    public static let memoryCompressed = accentThird
    public static let memoryCached = Color.dynamic(light: 0x8C8C91, dark: 0x6E6E73, increasedContrastLight: 0x6E6E73, increasedContrastDark: 0x98989D)
    public static let memoryFree = Color.dynamic(light: 0xE8E8ED, dark: 0x414145, increasedContrastLight: 0xD1D1D6, increasedContrastDark: 0x55555A)
}

/// The look of each tab: its SF Symbol. Every tab draws in the one accent.
extension TallyTab {
    public var tint: Color { Palette.accent }

    public var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "globe"
        case .gpu: "square.3.layers.3d"
        case .battery: "battery.75percent"
        case .sensors: "thermometer.medium"
        case .projects: "folder"
        }
    }
}

extension MemoryPressure {
    public var tint: Color {
        switch self {
        case .normal: Palette.good
        case .warning: Palette.caution
        case .critical: Palette.red
        }
    }
}

extension TemperatureRange {
    /// Only a high reading is marked; the rest stay quiet.
    public var statusTint: Color? {
        self == .high ? Palette.red : nil
    }

    public var tint: Color {
        self == .high ? Palette.red : Palette.accent
    }
}

public enum Symbols {
    public static let power = "bolt"
    public static let temperature = "thermometer.medium"
    public static let fan = "fan"
    public static let apps = "square.grid.2x2"
    public static let lock = "lock"
    public static let download = "arrow.down"
    public static let upload = "arrow.up"
    public static let chart = "chart.bar"
    public static let wifi = "wifi"
    public static let moon = "moon"
    public static let clock = "clock"
    public static let check = "checkmark"
}

/// Type styles shared by every tab, all in SF Pro. Nothing is smaller than 10 pt.
/// Figures are bold with tabular digits.
public enum Typography {
    public static func figure(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold).monospacedDigit()
    }

    public static func figureUnit(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }

    /// The figure at the top of a metric tab ("66 %").
    public static let heroFigureSize: CGFloat = 40
    /// The figure on an Overview card ("69 %").
    public static let cardFigureSize: CGFloat = 28
    /// The figure in a stat tile ("46%"), a sensor tile or an inspector tile.
    public static let tileFigureSize: CGFloat = 20
    /// The unit beside the hero figure ("%", "GB").
    public static let heroUnit = Font.system(size: 18, weight: .semibold)
    /// The centre of a donut chart ("43 %") and its caption.
    public static let donutTitle = Font.system(size: 14, weight: .bold).monospacedDigit()
    public static let donutSubtitle = Font.system(size: minimumSize)

    /// A sheet's title ("Google Chrome").
    public static let sheetTitle = Font.system(size: 19, weight: .bold)
    /// The name in the Top App tile.
    public static let tileName = Font.system(size: 14, weight: .semibold)
    /// The figure under the Top App tile's name.
    public static let tileFootnote = Font.system(size: 11.5, weight: .semibold).monospacedDigit()
    /// Tab switcher titles and symbols.
    public static let tabTitle = Font.system(size: 13, weight: .medium)
    public static let tabSymbol = Font.system(size: 12, weight: .medium)
    /// Segmented ranges ("Live", "12 h").
    public static let segment = Font.system(size: 11, weight: .medium).monospacedDigit()
    /// Short tags ("8 P", "Macintosh HD").
    public static let tag = Font.system(size: 11, weight: .semibold).monospacedDigit()
    /// The value and time over a hovered chart point.
    public static let chartLabel = Font.system(size: 11, weight: .semibold).monospacedDigit()
    public static let chartLabelDetail = Font.system(size: 11).monospacedDigit()

    /// Running text and messages ("No apps running").
    public static let body = Font.system(size: 12.5)
    /// A bold line in a list ("Chrome is using a lot of CPU").
    public static let bodyEmphasis = Font.system(size: 12.5, weight: .semibold)
    /// Names and figures in a table ("mds_stores", "4.1%").
    public static let tableText = Font.system(size: 12.5, weight: .medium)
    public static let tableValue = Font.system(size: 12.5, weight: .semibold).monospacedDigit()
    /// The title of a panel with nothing to show ("No history yet").
    public static let emptyTitle = Font.system(size: 13, weight: .semibold)
    /// The title of a whole tab with nothing to show ("No dev servers running").
    public static let largeEmptyTitle = Font.system(size: 15, weight: .semibold)

    /// Capsule buttons ("Done", "Quit").
    public static let button = Font.system(size: 12.5, weight: .semibold)
    /// Smaller capsule buttons inside rows ("Inspect", "Stop").
    public static let compactButton = Font.system(size: 12, weight: .semibold)
    /// The smallest buttons, in table rows ("Quit").
    public static let miniButton = Font.system(size: 11, weight: .semibold)
    /// Full-width text buttons under a list ("Show All 42 Apps").
    public static let listButton = Font.system(size: 12.5, weight: .medium)

    /// Chevrons and other glyphs that follow a line of text.
    public static let chevron = Font.system(size: 8, weight: .semibold)
    public static let inlineSymbol = Font.system(size: 9, weight: .semibold)

    /// Card titles beside their symbol ("CPU", "Memory by App").
    public static let cardTitle = Font.system(size: 12.5, weight: .semibold)
    public static let cardSymbol = Font.system(size: 12, weight: .medium)
    /// The grey line under a card's figure ("15.62 of 24 GB").
    public static let cardDetail = Font.system(size: 12, weight: .medium).monospacedDigit()
    /// A chip's label and its value ("Charging 58m").
    public static let chipLabel = Font.system(size: 11, weight: .medium)
    public static let chipValue = Font.system(size: 11, weight: .semibold).monospacedDigit()
    /// The line above a figure ("Now", "In Use of 64 GB").
    public static let caption = Font.system(size: 11)
    /// Key-value labels and column headers ("Average today", "App").
    public static let label = Font.system(size: 12)
    public static let value = Font.system(size: 12, weight: .semibold).monospacedDigit()
    /// Captions over the three stats on an Overview card ("User", "Average Today").
    public static let statLabel = Font.system(size: 10.5)
    public static let statValue = Font.system(size: 12, weight: .semibold).monospacedDigit()
    /// Stat tile subtitles ("Your apps").
    public static let tileSubtitle = Font.system(size: 11.5)
    /// Donut legends.
    public static let legend = Font.system(size: 11.5)
    public static let pill = Font.system(size: 12, weight: .semibold)
    public static let rowTitle = Font.system(size: 13.5, weight: .semibold)
    public static let rowSubtitle = Font.system(size: 11.5)
    public static let rowValue = Font.system(size: 13.5, weight: .semibold).monospacedDigit()
    public static let sectionCaps = Font.system(size: 11, weight: .semibold)
    /// The smallest text size anywhere in the app.
    public static let minimumSize: CGFloat = 10
}

public enum Metrics {
    public static let cardRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 14
    public static let gridSpacing: CGFloat = 12
    public static let badgeSize: CGFloat = 22
    public static let badgeRadius: CGFloat = 7
    /// Small tiles, such as the device tiles on the Sensors tab.
    public static let tileRadius: CGFloat = 10
    public static let chipRadius: CGFloat = 5
    /// Height of the bar chart along the bottom of an Overview card.
    public static let sparklineHeight: CGFloat = 30
}
