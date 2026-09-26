import Foundation

/// A number and its unit, kept apart so the UI can set the unit smaller and lighter.
public struct Figure: Hashable, Sendable {
    public var value: String
    public var unit: String

    public init(_ value: String, _ unit: String) {
        self.value = value
        self.unit = unit
    }

    /// "53.88 GB"
    public var text: String { unit.isEmpty ? value : (unit == "%" || unit == "°" ? value + unit : "\(value) \(unit)") }
}

/// Formatting rules matching Activity Monitor: memory in binary units, disk and network in decimal units.
public enum Format {
    private static let kilo: Double = 1000
    private static let kibi: Double = 1024

    /// RAM sizes: "53.88 GB", "458 MB", "0 MB".
    public static func memory(_ bytes: UInt64) -> Figure {
        let value = Double(bytes)
        let gib = value / (kibi * kibi * kibi)
        if gib >= 1 { return Figure(String(format: "%.2f", gib), "GB") }
        return Figure(String(format: "%.0f", value / (kibi * kibi)), "MB")
    }

    /// Storage sizes: "479.72 GB", "1.2 TB", "458 MB".
    public static func storage(_ bytes: UInt64) -> Figure {
        let value = Double(bytes)
        let tb = value / (kilo * kilo * kilo * kilo)
        if tb >= 10 { return Figure(String(format: "%.1f", tb), "TB") }
        let gb = value / (kilo * kilo * kilo)
        if gb >= 1 { return Figure(String(format: "%.2f", gb), "GB") }
        let mb = value / (kilo * kilo)
        if mb >= 1 { return Figure(String(format: "%.0f", mb), "MB") }
        return Figure(String(format: "%.0f", value / kilo), "kB")
    }

    /// Amounts moved over time: "4.8 GB", "212 GB", "706 MB".
    public static func total(_ bytes: UInt64) -> Figure {
        let value = Double(bytes)
        let tb = value / (kilo * kilo * kilo * kilo)
        if tb >= 1 { return Figure(String(format: "%.1f", tb), "TB") }
        let gb = value / (kilo * kilo * kilo)
        if gb >= 100 { return Figure(String(format: "%.0f", gb), "GB") }
        if gb >= 1 { return Figure(String(format: "%.1f", gb), "GB") }
        let mb = value / (kilo * kilo)
        if mb >= 1 { return Figure(String(format: "%.0f", mb), "MB") }
        return Figure(String(format: "%.0f", value / kilo), "kB")
    }

    /// Transfer rates: "731 kB/s", "5.3 MB/s", "0 kB/s".
    public static func rate(_ bytesPerSecond: Double) -> Figure {
        let value = max(0, bytesPerSecond)
        let gb = value / (kilo * kilo * kilo)
        if gb >= 1 { return Figure(String(format: "%.1f", gb), "GB/s") }
        let mb = value / (kilo * kilo)
        if mb >= 1 { return Figure(String(format: "%.1f", mb), "MB/s") }
        return Figure(String(format: "%.0f", value / kilo), "kB/s")
    }

    /// Whole percent: "69 %" as a figure.
    public static func percent(_ value: Double) -> Figure {
        Figure(String(format: "%.0f", value.isFinite ? value : 0), "%")
    }

    /// One decimal percent for per-app CPU and GPU: "44.1%".
    public static func precisePercent(_ value: Double) -> String {
        let safe = value.isFinite ? value : 0
        return safe >= 100 ? String(format: "%.0f%%", safe) : String(format: "%.1f%%", safe)
    }

    /// Power: "1.7 W", "427 mW".
    public static func power(_ watts: Double) -> Figure {
        let safe = max(0, watts.isFinite ? watts : 0)
        if safe < 1 { return Figure(String(format: "%.0f", safe * 1000), "mW") }
        return Figure(String(format: "%.1f", safe), "W")
    }

    /// "3h 34m", "45m".
    public static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        return "\(hours)h \(String(format: "%02d", remainder))m"
    }

    /// "Up 3d 4h", "Up 5h 12m".
    public static func uptime(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "Up \(days)d \(hours)h" }
        if hours > 0 { return "Up \(hours)h \(minutes)m" }
        return "Up \(minutes)m"
    }

    /// "45 min", "2 hours", "3 days".
    public static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "a moment" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// "63°" in the chosen unit.
    public static func temperature(_ celsius: Double, unit: TemperatureUnit = .celsius) -> Figure {
        let value = unit == .celsius ? celsius : celsius * 9 / 5 + 32
        return Figure(String(format: "%.0f", value), "°")
    }

    /// "3,460"
    public static func integer(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    /// "96 processes", "1 process"
    public static func processes(_ count: Int) -> String {
        count == 1 ? "1 process" : "\(count) processes"
    }
}
