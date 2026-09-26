import Foundation

/// The audio-capture privacy permission process taps need. macOS has no public API to read or request it, so
/// this uses the TCC calls System Settings uses, and reports `.unknown` when they are missing.
enum AudioCaptureAccess {
    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFunction: PreflightFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestFunction: RequestFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    /// True when the permission can be checked and requested ahead of creating a tap.
    static var canAsk: Bool { preflightFunction != nil && requestFunction != nil }

    static func status() -> AudioCapturePermission {
        guard let preflightFunction else { return .unknown }
        switch preflightFunction(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user has not answered yet. The completion runs on an arbitrary thread.
    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let requestFunction else {
            completion(true)
            return
        }
        requestFunction(service, nil) { granted in completion(granted) }
    }

    /// Privacy & Security › Screen & System Audio Recording.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}
