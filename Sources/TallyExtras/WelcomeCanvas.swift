import SwiftUI
import AppKit
import TallyCore

/// One frame of the intro at a given time: the processes as dots, the dots folding into a ring of apps, then the features.
struct WelcomeCanvas: View {
    let scene: WelcomeScene
    let time: TimeInterval
    let size: CGSize
    let onFinish: () -> Void
    let onSkip: () -> Void

    /// Seconds since the dots began folding into apps.
    private var gather: Double { time - WelcomeTiming.gatherStart }
    private var features: Double { time - WelcomeTiming.featuresStart }
    private var rings: WelcomeRings { WelcomeRings(size: size) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if gather > WelcomeTiming.ringsStart {
                glow
                if features < 0.6 {
                    orbit
                }
            }
            if gather < WelcomeTiming.dotsGone {
                dots
            }
            ForEach(Array(scene.icons.enumerated()), id: \.element.id) { rank, icon in
                iconView(icon, rank: rank)
            }
            .accessibilityHidden(true)
            if features < 0.4 {
                headline
            }
            WelcomeFeatureList(scene: scene, features: features, size: size, onFinish: onFinish)
            if features < 0 {
                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
                    .position(x: size.width - 40, y: size.height - 28)
                    .opacity(clamp01(time / 0.6))
                    .help("Skip to the end of the intro")
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Opacity steps the dots are drawn in, so each frame is a few filled paths rather than one fill per dot.
    private static let opacityLevels = 16

    /// Hundreds of moving dots: one canvas is far cheaper than a view per dot while the intro plays.
    private var dots: some View {
        Canvas { context, _ in
            let rings = self.rings
            let targets = scene.icons.map { rings.position(of: $0) }
            // Shading 0 is the grey of a loose process, 1 the accent, then one per ring icon.
            let accent = context.resolve(GraphicsContext.Shading.color(Palette.accent))
            let shadings = [context.resolve(GraphicsContext.Shading.color(Palette.welcomeProcessDot)), accent]
                + scene.icons.map { $0.tint.map { context.resolve(GraphicsContext.Shading.color($0)) } ?? accent }
            let levels = Self.opacityLevels
            var paths = [Path](repeating: Path(), count: shadings.count * (levels + 1))
            func add(_ rect: CGRect, shading: Int, alpha: Double) {
                let level = Int((alpha * Double(levels)).rounded())
                if level > 0 { paths[shading * (levels + 1) + min(level, levels)].addEllipse(in: rect) }
            }

            for dot in scene.dots {
                let base = CGPoint(x: dot.position.x * size.width, y: dot.position.y * size.height)
                var alpha = dot.alpha * clamp01((time - dot.delay) / 0.5)
                var radius = dot.radius
                var point = base
                var tintAmount = 0.0
                let progress = clamp01((gather - dot.delay * 0.8) / 1.5)
                if progress > 0 {
                    let eased = easeInOut(progress)
                    tintAmount = clamp01(progress * 1.8)
                    if let target = dot.target {
                        let destination = targets[target]
                        let straight = lerp(base, destination, eased)
                        let bend = dot.bend * sin(.pi * eased)
                        point = CGPoint(x: straight.x - (destination.y - base.y) * bend, y: straight.y + (destination.x - base.x) * bend)
                        radius *= 1 - 0.4 * eased
                        alpha *= 1 - clamp01((progress - 0.75) / 0.25)
                    } else {
                        // Processes of apps off the ring drift into the count and fade.
                        let destination = CGPoint(x: rings.center.x + (base.x - rings.center.x) * 0.16, y: rings.center.y + (base.y - rings.center.y) * 0.16)
                        point = lerp(base, destination, eased)
                        radius *= 1 - 0.3 * eased
                        alpha *= 1 - clamp01((progress - 0.3) / 0.7)
                    }
                }
                guard alpha > 0.01 else { continue }
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                // A dot changing colour is drawn twice, fading from grey into its app's tint.
                if tintAmount < 1 { add(rect, shading: 0, alpha: alpha * (1 - tintAmount)) }
                if tintAmount > 0 { add(rect, shading: dot.target.map { $0 + 2 } ?? 1, alpha: alpha * tintAmount) }
            }

            for (index, path) in paths.enumerated() where !path.isEmpty {
                var layer = context
                layer.opacity = Double(index % (levels + 1)) / Double(levels)
                layer.fill(path, with: shadings[index / (levels + 1)])
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The soft light behind the count, which drifts up behind the feature list.
    private var glow: some View {
        let rings = self.rings
        let lift = easeInOut(features / 1.2)
        return Ellipse()
            .fill(RadialGradient(colors: [Palette.welcomeGlow, Palette.welcomeGlow.opacity(0)], center: .center, startRadius: 0, endRadius: rings.outer.height * 1.25))
            .frame(width: rings.outer.width * 2.6, height: rings.outer.height * 2.5)
            .opacity(clamp01((gather - WelcomeTiming.ringsStart) / 1.2) * (1 - 0.35 * lift))
            .position(lerp(rings.center, CGPoint(x: rings.center.x, y: 0), lift))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The two rings the icons sit on.
    private var orbit: some View {
        let rings = self.rings
        let draw = easeInOut((gather - WelcomeTiming.ringsStart) / 1.6)
        return ZStack {
            ring(rings.outer, draw: draw, from: -0.28)
            ring(rings.inner, draw: draw, from: 0.2)
        }
        .position(rings.center)
        .opacity(1 - clamp01(features / 0.5))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ring(_ radii: CGSize, draw: Double, from start: Double) -> some View {
        Ellipse()
            .trim(from: 0, to: draw)
            .stroke(Palette.welcomeRing, lineWidth: 1)
            .frame(width: radii.width * 2, height: radii.height * 2)
            .rotationEffect(.radians(start * .pi))
    }

    private static let rowSize: CGFloat = 32
    private static let rowSpacing: CGFloat = 12

    private func rowPosition(_ rank: Int) -> CGPoint {
        let count = min(scene.icons.count, WelcomeScene.rowLimit)
        let width = CGFloat(count) * Self.rowSize + CGFloat(count - 1) * Self.rowSpacing
        let x = (size.width - width) / 2 + Self.rowSize / 2 + CGFloat(rank) * (Self.rowSize + Self.rowSpacing)
        return CGPoint(x: x, y: 66)
    }

    @ViewBuilder
    private func iconView(_ icon: WelcomeScene.RingIcon, rank: Int) -> some View {
        let appearStart = WelcomeTiming.iconsStart + Double(rank) * 0.05
        let appear = clamp01((gather - appearStart) / 0.5)
        let settle = clamp01((gather - appearStart - 0.3) / 1.2)
        let move = easeInOut((features - Double(rank) * 0.02) / 0.7)
        let inRow = rank < WelcomeScene.rowLimit
        let ringPoint = rings.position(of: icon)
        let position = inRow ? lerp(ringPoint, rowPosition(rank), move) : ringPoint
        let side = inRow ? icon.size + (Self.rowSize - icon.size) * move : icon.size * (1 - 0.35 * move)
        let opacity = min(1, appear * 1.8) * (inRow ? 1 : 1 - clamp01(features / 0.45))
        let accents = 1 - clamp01(features / 0.3)
        if opacity > 0.001 {
            ZStack {
                if let tint = icon.tint {
                    Circle()
                        .fill(RadialGradient(colors: [tint.opacity(0.3), tint.opacity(0)], center: .center, startRadius: 0, endRadius: side))
                        .frame(width: side * 2, height: side * 2)
                        .opacity(accents)
                }
                // The frosted tile each icon arrives in, as in the launch video.
                RoundedRectangle(cornerRadius: side * 0.42, style: .continuous)
                    .fill(Palette.background.opacity(0.6))
                    .overlay {
                        RoundedRectangle(cornerRadius: side * 0.42, style: .continuous)
                            .strokeBorder((icon.tint ?? Palette.accent).opacity(0.28), lineWidth: 1)
                    }
                    .frame(width: side * 1.5, height: side * 1.5)
                    .scaleEffect(1.08 - 0.08 * settle)
                    .opacity((1 - settle) * min(1, appear * 2))
                // Drawn at one size and scaled, so the animation does not make a thumbnail for every frame's size.
                AppIconView(icon.app, size: icon.size)
                    .scaleEffect(side / icon.size)
                    .shadow(color: Palette.thumbShadow, radius: 2, y: 1)
                WelcomeCountBadge(count: icon.app.processCount, isSmall: !icon.isInner)
                    .position(x: side * 1.96, y: side * 1.96)
                    .frame(width: side * 3, height: side * 3)
                    .opacity(accents * clamp01((appear - 0.5) / 0.5))
            }
            .frame(width: side * 3, height: side * 3)
            .scaleEffect(0.3 + 0.7 * easeOutBack(appear))
            .opacity(opacity)
            .position(position)
            .allowsHitTesting(false)
        }
    }

    private var headline: some View {
        let rings = self.rings
        let swap = easeInOut(gather / 0.45)
        let visibility = clamp01(time / 0.5) * (1 - clamp01(features / 0.35))
        return VStack(spacing: 6) {
            ZStack {
                WelcomeSourceLabel(isTally: false, path: scene.activityMonitorPath)
                    .opacity(1 - swap)
                WelcomeSourceLabel(isTally: true, path: nil)
                    .opacity(swap)
            }
            WelcomeHeadlineLayout(reveal: nounReveal) {
                Text(WelcomeHeadlineLayout.format(figure))
                    .foregroundStyle(Palette.ink)
                Text(noun)
                    .foregroundStyle(gather < WelcomeTiming.countDownStart + WelcomeTiming.countDownLength ? Palette.ink2 : Palette.accent)
                    .opacity(clamp01(nounReveal * 1.5 - 0.5))
            }
            .font(.system(size: 60, weight: .bold).monospacedDigit())
            .tracking(-1.6)
        }
        .fixedSize()
        .opacity(visibility)
        .offset(y: -10 * clamp01(features / 0.35))
        .position(x: rings.center.x, y: rings.center.y - 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gather < WelcomeTiming.appsNounStart
            ? "Activity Monitor shows \(Format.processes(scene.processCount))"
            : "Tally shows \(scene.appCount == 1 ? "1 app" : "\(scene.appCount) apps")")
    }

    /// Counts up to the processes while the dots appear, then down to the apps as they fold.
    private var figure: Int {
        let processes = Double(scene.processCount)
        let apps = Double(scene.appCount)
        let countDown = easeInOut((gather - WelcomeTiming.countDownStart) / WelcomeTiming.countDownLength)
        let value = gather < WelcomeTiming.countDownStart
            ? processes * easeOut(time / WelcomeTiming.countUp)
            : processes + (apps - processes) * countDown
        return Int(value.rounded())
    }

    private var noun: String {
        if gather < WelcomeTiming.countDownStart + WelcomeTiming.countDownLength {
            return scene.processCount == 1 ? "process" : "processes"
        }
        return scene.appCount == 1 ? "app" : "apps"
    }

    /// "processes" folds away as the count starts to fall; "apps" opens once it lands.
    private var nounReveal: Double {
        if gather < WelcomeTiming.countDownStart + WelcomeTiming.countDownLength {
            return 1 - easeInOut(gather / 0.45)
        }
        return easeInOut((gather - WelcomeTiming.appsNounStart) / 0.5)
    }
}

/// The small icon and name over the count: Activity Monitor first, then Tally.
private struct WelcomeSourceLabel: View {
    let isTally: Bool
    let path: String?

    var body: some View {
        HStack(spacing: 8) {
            if isTally {
                TallyLogoMark(size: 26)
            } else if let path {
                Image(nsImage: AppIconCache.shared.icon(forPath: path))
                    .resizable()
                    .frame(width: 28, height: 28)
            }
            Text(isTally ? "Tally" : "Activity Monitor")
                .font(.system(size: 21, weight: isTally ? .bold : .semibold))
                .tracking(-0.3)
                .foregroundStyle(isTally ? Palette.ink : Palette.ink2)
        }
        .accessibilityHidden(true)
    }
}

/// The tag on an icon's corner with its number of processes.
private struct WelcomeCountBadge: View {
    let count: Int
    let isSmall: Bool

    var body: some View {
        let height: CGFloat = isSmall ? 16 : 18
        Text("\(count)")
            .font(.system(size: isSmall ? 10 : 11, weight: .bold).monospacedDigit())
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 5)
            .frame(minWidth: height, minHeight: height)
            .background(Palette.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 0.5))
            .shadow(color: Palette.thumbShadow, radius: 2, y: 1)
            .fixedSize()
    }
}

/// The count and its noun on one line, with the noun opening or folding by `reveal` so the count stays centred.
struct WelcomeHeadlineLayout: Layout {
    var reveal: Double
    var spacing: CGFloat = 16

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// "1,042", with one formatter for every frame.
    static func format(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let figure = subviews[0].sizeThatFits(.unspecified)
        let noun = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: figure.width + (spacing + noun.width) * reveal, height: max(figure.height, noun.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let figure = subviews[0].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.minX + figure.width + spacing, y: bounds.minY), proposal: .unspecified)
    }
}

/// "Welcome to Tally", what it does, and Get Started.
private struct WelcomeFeatureList: View {
    let scene: WelcomeScene
    /// Seconds since the feature stage began.
    let features: Double
    let size: CGSize
    let onFinish: () -> Void

    private func reveal(_ delay: Double) -> Double {
        easeInOut((features - 0.7 - delay) / 0.5)
    }

    var body: some View {
        if features > 0.6 {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Welcome to Tally")
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Palette.ink)
                    Text("Your \(WelcomeHeadlineLayout.format(scene.processCount)) \(scene.processCount == 1 ? "process" : "processes"), grouped into \(WelcomeHeadlineLayout.format(scene.appCount)) \(scene.appCount == 1 ? "app" : "apps"). Here is what else it does.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink2)
                }
                .opacity(reveal(0))
                .offset(y: 8 * (1 - reveal(0)))
                .padding(.bottom, 24)

                let columns = [Array(WelcomeFeature.all.prefix(3)), Array(WelcomeFeature.all.dropFirst(3))]
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns.indices, id: \.self) { column in
                        VStack(spacing: 10) {
                            ForEach(Array(columns[column].enumerated()), id: \.element.title) { row, feature in
                                let amount = reveal(0.12 + Double(row * 2 + column) * 0.06)
                                WelcomeFeatureTile(feature: feature)
                                    .opacity(amount)
                                    .offset(y: 10 * (1 - amount))
                            }
                        }
                    }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 40)

                Spacer(minLength: 16)

                Button(action: onFinish) {
                    Text("Get Started")
                        .padding(.horizontal, 18)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .opacity(reveal(0.55))
                .scaleEffect(0.96 + 0.04 * reveal(0.55))
                .padding(.bottom, 40)
            }
            .frame(width: size.width, height: size.height - 108)
            .offset(y: 108)
        }
    }
}

private func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

private func easeInOut(_ value: Double) -> Double {
    let x = clamp01(value)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}

private func easeOut(_ value: Double) -> Double {
    1 - pow(1 - clamp01(value), 3)
}

private func easeOutBack(_ value: Double) -> Double {
    let x = clamp01(value)
    let overshoot = 1.5
    return 1 + (overshoot + 1) * pow(x - 1, 3) + overshoot * pow(x - 1, 2)
}

private func lerp(_ from: CGPoint, _ to: CGPoint, _ amount: Double) -> CGPoint {
    CGPoint(x: from.x + (to.x - from.x) * amount, y: from.y + (to.y - from.y) * amount)
}
