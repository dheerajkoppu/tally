import Foundation

/// What the user can see right now. The engine hands it to samplers so they skip work nothing on screen needs.
public struct SamplingDemand: Hashable, Sendable {
    /// A window or the menu bar panel is on screen.
    public var isVisible: Bool
    /// Per-app network figures may be on screen: the Network tab, the app inspector or the menu bar panel.
    public var showsAppNetwork: Bool
    /// Low Power Mode is on, so every interval doubles.
    public var isLowPower: Bool

    public init(isVisible: Bool = false, showsAppNetwork: Bool = false, isLowPower: Bool = false) {
        self.isVisible = isVisible
        self.showsAppNetwork = showsAppNetwork
        self.isLowPower = isLowPower
    }

    /// Multiplier for every sampling interval.
    public var intervalScale: Double { isLowPower ? 2 : 1 }
}

/// A sampler that scales its work to what is on screen. Called on the engine queue whenever the demand changes.
public protocol DemandAware: AnyObject {
    func setDemand(_ demand: SamplingDemand)
}

/// History that also takes whole-Mac figures between the less frequent per-app samples.
public protocol SystemHistoryRecording: AnyObject {
    func recordSystem(snapshot: SystemSnapshot)
}
