import SwiftUI
import AppKit
import Accessibility

/// A tint for text: darkened on light surfaces, or lightened on dark ones, just enough to reach 4.5:1 against the
/// surface (7:1 with Increase Contrast), keeping its hue. `wash` is the opacity of the same tint behind the text, as on
/// pills. Resolved when drawn, so it costs nothing between samples.
public struct LegibleTint: ShapeStyle {
    private let tint: Color
    private let surface: Color
    private let wash: Float

    public init(_ tint: Color, on surface: Color = Palette.card, wash: Double = 0) {
        self.tint = tint
        self.surface = surface
        self.wash = Float(wash)
    }

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        let foreground = tint.resolve(in: environment)
        var background = surface.resolve(in: environment)
        if wash > 0 {
            background = Color.Resolved(
                red: foreground.red * wash + background.red * (1 - wash),
                green: foreground.green * wash + background.green * (1 - wash),
                blue: foreground.blue * wash + background.blue * (1 - wash)
            )
        }
        // A hair above the minimum, so rounding to 8-bit colour never lands below it.
        let target: Float = (environment.colorSchemeContrast == .increased ? 7 : 4.5) + 0.1
        return Self.adjusted(foreground, against: background, target: target)
    }

    static func luminance(_ color: Color.Resolved) -> Float {
        0.2126 * min(max(color.linearRed, 0), 1) + 0.7152 * min(max(color.linearGreen, 0), 1) + 0.0722 * min(max(color.linearBlue, 0), 1)
    }

    /// Scales the colour toward black, or mixes it toward white, in linear light, which keeps its chromaticity.
    static func adjusted(_ color: Color.Resolved, against background: Color.Resolved, target: Float) -> Color.Resolved {
        let colorLuminance = luminance(color)
        let backgroundLuminance = luminance(background)
        var result = color
        if backgroundLuminance >= colorLuminance {
            let highest = (backgroundLuminance + 0.05) / target - 0.05
            guard colorLuminance > highest, colorLuminance > 0 else { return color }
            let scale = max(highest, 0) / colorLuminance
            result.linearRed *= scale
            result.linearGreen *= scale
            result.linearBlue *= scale
        } else {
            let lowest = min(target * (backgroundLuminance + 0.05) - 0.05, 1)
            guard colorLuminance < lowest, colorLuminance < 1 else { return color }
            let amount = (lowest - colorLuminance) / (1 - colorLuminance)
            result.linearRed += (1 - result.linearRed) * amount
            result.linearGreen += (1 - result.linearGreen) * amount
            result.linearBlue += (1 - result.linearBlue) * amount
        }
        return result
    }
}

/// Outlines a surface with a 3:1 border when Show Borders or Increase Contrast is on.
struct AccessibilityOutline<Outline: InsettableShape>: ViewModifier {
    let shape: Outline
    let includesIncreasedContrast: Bool

    @Environment(\.accessibilityShowBorders) private var showsBorders
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if showsBorders || (includesIncreasedContrast && contrast == .increased) {
                shape.strokeBorder(Palette.outline, lineWidth: 1).allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Outlines a card or tile when Show Borders or Increase Contrast is on.
    public func surfaceOutline<Outline: InsettableShape>(_ shape: Outline) -> some View {
        modifier(AccessibilityOutline(shape: shape, includesIncreasedContrast: true))
    }

    /// Outlines a custom control when Show Borders is on, as the system does for its own buttons.
    public func controlOutline<Outline: InsettableShape>(_ shape: Outline) -> some View {
        modifier(AccessibilityOutline(shape: shape, includesIncreasedContrast: false))
    }
}

extension View {
    /// Makes this one static-text element that VoiceOver reads as "label, value". On macOS an element with a label and
    /// value but no role is exposed without its value, so the pair becomes the text itself.
    public func accessibilityReading(_ label: String, value: String? = nil) -> some View {
        let value = value ?? ""
        return accessibilityElement(children: .ignore)
            .accessibilityLabel(value.isEmpty ? label : (label.isEmpty ? value : "\(label), \(value)"))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Speaks important changes through VoiceOver, such as memory pressure turning critical, never per sample.
@MainActor
public enum AccessibilityAnnouncer {
    private static var lastAnnouncements: [String: Date] = [:]
    private static var announcedPressure = MemoryPressure.normal

    /// Announces `message` if VoiceOver is running and nothing was announced for `key` within `minimumInterval`.
    /// Returns whether it was announced.
    @discardableResult
    public static func announce(_ message: String, key: String, minimumInterval: TimeInterval = 60, isUrgent: Bool = false) -> Bool {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return false }
        let now = Date()
        if let last = lastAnnouncements[key], now.timeIntervalSince(last) < minimumInterval { return false }
        lastAnnouncements[key] = now
        var text = AttributedString(message)
        text.accessibilitySpeechAnnouncementPriority = isUrgent ? .high : .default
        AccessibilityNotification.Announcement(text).post()
        return true
    }

    /// Announces memory pressure rising to Elevated or Critical, and its return to Normal after an announced rise.
    /// Each level is spoken at most once a minute, so a level that flickers does not repeat.
    public static func memoryPressureChanged(to pressure: MemoryPressure) {
        guard pressure != announcedPressure else { return }
        let message = switch pressure {
        case .normal: "Memory pressure is back to normal"
        case .warning: "Memory pressure is elevated"
        case .critical: "Memory pressure is critical"
        }
        if announce(message, key: "memory-pressure-\(pressure.rawValue)", isUrgent: pressure == .critical) {
            announcedPressure = pressure
        }
    }
}

extension View {
    /// Announces memory pressure changes while this view is on screen.
    public func announcesMemoryPressure(_ pressure: MemoryPressure) -> some View {
        onChange(of: pressure) { _, current in
            AccessibilityAnnouncer.memoryPressureChanged(to: current)
        }
    }
}
