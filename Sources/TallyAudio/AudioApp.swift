import Foundation

/// An app that is playing sound, or was recently, with its helper processes folded in.
public struct AudioApp: Identifiable, Hashable, Sendable {
    /// The bundle path for apps, the executable path for tools, matching `AppUsage.id`.
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
    /// The app bundle or executable to take the icon from.
    public var iconPath: String?
    public var pids: [Int32]
    /// True while at least one of its processes is sending audio to an output device.
    public var isPlaying: Bool
    /// 0...1, where 1 leaves the app untouched.
    public var volume: Double
    public var isMuted: Bool
    /// True while Tally routes this app's sound through a process tap to change its level.
    public var isTapped: Bool
    /// Set when the volume could not be applied.
    public var problem: String?

    public init(id: String, name: String, bundleIdentifier: String?, iconPath: String?, pids: [Int32], isPlaying: Bool, volume: Double = 1, isMuted: Bool = false, isTapped: Bool = false, problem: String? = nil) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.iconPath = iconPath
        self.pids = pids
        self.isPlaying = isPlaying
        self.volume = volume
        self.isMuted = isMuted
        self.isTapped = isTapped
        self.problem = problem
    }

    public var isAdjusted: Bool { VolumeSetting(volume: volume, isMuted: isMuted).isAdjusted }
}

/// The level the user picked for one app.
public struct VolumeSetting: Hashable, Sendable {
    public var volume: Double
    public var isMuted: Bool

    public init(volume: Double = 1, isMuted: Bool = false) {
        self.volume = volume
        self.isMuted = isMuted
    }

    public var isAdjusted: Bool { isMuted || volume < 0.995 }

    /// Linear gain for the samples. The slider follows a squared taper so equal steps sound roughly equal.
    public var gain: Float {
        if isMuted { return 0 }
        let clamped = min(max(volume, 0), 1)
        return Float(clamped * clamped)
    }
}

/// Whether macOS lets Tally capture app audio, which process taps need.
public enum AudioCapturePermission: String, Sendable {
    case unknown, authorized, denied
}

/// The live state of one tap, for probes and debugging.
public struct AudioTapDiagnostics: Sendable {
    public var appID: String
    public var tapID: UInt32
    public var aggregateDeviceID: UInt32
    public var outputDeviceID: UInt32
    public var processObjectIDs: [UInt32]
    public var gain: Float
    public var renderedFrames: Int
    /// Buffers the I/O proc receives: the output device's own inputs, then the tap.
    public var inputBufferCount: Int
    public var outputChannelCount: Int
    /// Peak sample level captured from the app since the last read, before gain.
    public var inputPeak: Float
}
