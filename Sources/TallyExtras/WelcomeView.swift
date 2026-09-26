import SwiftUI
import AppKit
import TallyCore

/// First-launch screen, after the launch video: every process as a dot, the dots folding into a ring of apps, then
/// what Tally does. The intro runs once for about ten seconds, then rests on a static frame with no timeline running.
/// Under Reduce Motion the stages cross-fade without moving.
public struct WelcomeView: View {
    /// The three beats of the intro.
    public enum Stage: Int, CaseIterable, Sendable {
        /// Every process as a dot: what Activity Monitor shows.
        case processes
        /// The dots fold into a ring of app icons: what Tally shows.
        case apps
        /// What Tally does, and Get Started.
        case features
    }

    private let onFinish: () -> Void
    private let fixedStage: Stage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene: WelcomeScene?
    @State private var start: Date?
    @State private var isSettled = false
    @State private var isClosed = false
    /// The stage shown under Reduce Motion.
    @State private var restingStage: Stage = .processes
    /// True while nothing moves, so the timeline draws no frames.
    @State private var isHolding = false

    public init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        self.fixedStage = nil
    }

    /// Shows one stage at rest, without playing the intro. For previews and screenshots.
    public init(onFinish: @escaping () -> Void, stage: Stage) {
        self.onFinish = onFinish
        self.fixedStage = stage
    }

    public var body: some View {
        GeometryReader { geometry in
            content(size: geometry.size)
        }
        .ignoresSafeArea()
        .frame(minWidth: 560, idealWidth: 760, maxWidth: .infinity, minHeight: 480, idealHeight: 560, maxHeight: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .background(WindowCloseObserver(onClose: close))
        .onAppear { begin(hasSample: TallyStore.shared.hasSample) }
        // The publisher fires before the store's value changes, so the new value is passed along.
        // Its first value is the current one, which `onAppear` already handles.
        .onReceive(TallyStore.shared.$hasSample.dropFirst().removeDuplicates()) { hasSample in
            begin(hasSample: hasSample)
        }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if isClosed {
            Color.clear
        } else if let scene = scene ?? unplayedScene {
            if let fixedStage {
                canvas(scene, time: WelcomeTiming.restingTime(fixedStage), size: size)
            } else if start == nil {
                canvas(scene, time: Self.unplayedTime, size: size)
            } else if isSettled {
                canvas(scene, time: WelcomeTiming.restingTime(.features), size: size)
            } else if reduceMotion {
                ZStack {
                    canvas(scene, time: WelcomeTiming.restingTime(restingStage), size: size)
                        .id(restingStage)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.6), value: restingStage)
            } else if let start {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isHolding)) { context in
                    canvas(scene, time: context.date.timeIntervalSince(start), size: size)
                }
            }
        } else {
            VStack(spacing: 16) {
                TallyLogoMark(size: 56)
                    .accessibilityHidden(true)
                ProgressView()
                    .controlSize(.small)
                Text("Looking at your Mac…")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func canvas(_ scene: WelcomeScene, time: TimeInterval, size: CGSize) -> some View {
        WelcomeCanvas(scene: scene, time: time, size: size, onFinish: onFinish, onSkip: skip)
    }

    /// A scene for a view that is drawn without appearing, as the render harness does.
    private var unplayedScene: WelcomeScene? {
        guard start == nil, TallyStore.shared.hasSample else { return nil }
        return WelcomeScene(store: TallyStore.shared)
    }

    /// The render harness draws one moment of the intro: the ring of apps, or the second given in TALLY_WELCOME_TIME.
    private static var unplayedTime: TimeInterval {
        ProcessInfo.processInfo.environment["TALLY_WELCOME_TIME"].flatMap(Double.init) ?? WelcomeTiming.restingTime(.apps)
    }

    private static let isRendering = CommandLine.arguments.contains("--render")

    /// Starts the intro once the first sample is in, so every figure in it is real.
    private func begin(hasSample: Bool) {
        guard fixedStage == nil, start == nil, !isClosed, hasSample else { return }
        scene = WelcomeScene(store: TallyStore.shared)
        restart(at: Self.isRendering ? Self.unplayedTime : 0)
    }

    private func skip() {
        guard let start else { return }
        let target = reduceMotion ? WelcomeTiming.featuresStart : WelcomeTiming.featuresStart - 0.05
        guard Date().timeIntervalSince(start) < target else { return }
        restart(at: target)
    }

    /// Plays on from `elapsed` seconds into the intro. Nothing repeats: a few one-shot calls move it along.
    private func restart(at elapsed: TimeInterval) {
        let begun = Date().addingTimeInterval(-elapsed)
        start = begun
        isSettled = false
        isHolding = WelcomeTiming.holds.contains { $0.contains(elapsed) }
        updateRestingStage()
        func after(_ moment: TimeInterval, _ action: @escaping () -> Void) {
            guard moment > elapsed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + moment - elapsed) {
                if start == begun, !isClosed { action() }
            }
        }
        after(WelcomeTiming.gatherStart) { updateRestingStage() }
        after(WelcomeTiming.featuresStart) { updateRestingStage() }
        for hold in WelcomeTiming.holds {
            after(hold.lowerBound) { isHolding = true }
            after(hold.upperBound) { isHolding = false }
        }
        after(WelcomeTiming.settled + 0.1) { isSettled = true }
    }

    private func updateRestingStage() {
        guard let start, !isClosed else { return }
        let stage = WelcomeTiming.stage(at: Date().timeIntervalSince(start) + 0.01)
        if stage.rawValue > restingStage.rawValue { restingStage = stage }
    }

    /// Drops the whole scene when the window closes, however it closes.
    private func close() {
        isClosed = true
        scene = nil
        // The shell asks for fast sampling while the welcome window is up.
        AppRouter.shared.engine?.endFastSampling("welcome")
    }
}

/// Calls `onClose` when the window holding this view closes.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onClose: onClose)
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onClose = onClose
    }

    final class ObserverView: NSView {
        var onClose: () -> Void
        private var observer: NSObjectProtocol?

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// When each beat of the intro happens, in seconds from the first sample.
enum WelcomeTiming {
    /// The process count climbs while the dots appear.
    static let countUp: TimeInterval = 1.3
    /// The dots start folding into apps.
    static let gatherStart: TimeInterval = 2.9
    static let featuresStart: TimeInterval = 8
    static let settled: TimeInterval = 10.2

    /// The rest are seconds after `gatherStart`.
    static let countDownStart: TimeInterval = 0.3
    static let countDownLength: TimeInterval = 1.8
    static let ringsStart: TimeInterval = 0.8
    static let iconsStart: TimeInterval = 0.9
    static let appsNounStart: TimeInterval = 2.1
    /// Every dot has reached its icon or faded by now.
    static let dotsGone: TimeInterval = 2.3
    /// Stretches in which nothing moves: the dots are all in, then the ring has settled.
    static let holds: [ClosedRange<TimeInterval>] = [1.45...gatherStart, 6.1...featuresStart]

    static func restingTime(_ stage: WelcomeView.Stage) -> TimeInterval {
        switch stage {
        case .processes: gatherStart - 0.1
        case .apps: featuresStart - 0.1
        case .features: settled + 1
        }
    }

    static func stage(at time: TimeInterval) -> WelcomeView.Stage {
        time < gatherStart ? .processes : (time < featuresStart ? .apps : .features)
    }
}
