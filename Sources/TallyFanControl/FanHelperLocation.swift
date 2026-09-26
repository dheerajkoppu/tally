import Foundation

/// Where the fan helper lives once installed, and how the app talks to it. Must match TallyFanHelper.
enum FanHelperLocation {
    static let label = "io.github.dheerajkoppu.tally.fanhelper"
    static let installedBinaryPath = "/Library/PrivilegedHelperTools/\(label)"
    static let launchDaemonPath = "/Library/LaunchDaemons/\(label).plist"
    static let markerPath = "/var/run/\(label).forced"
    static let expectedVersion = 2

    /// `TALLY_FAN_HELPER_SOCKET` points the app at a helper started by hand with `--socket`, for testing.
    static let testSocketPath = ProcessInfo.processInfo.environment["TALLY_FAN_HELPER_SOCKET"]

    static var socketPath: String { testSocketPath ?? "/var/run/\(label).sock" }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedBinaryPath) && FileManager.default.fileExists(atPath: launchDaemonPath)
    }

    /// The helper inside Tally.app, or next to the executable when running from `swift build`.
    static var bundledBinary: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(label)"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TallyFanHelper"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// SHA-256 of the bundled helper, written into Info.plist by build-app.sh before the app is signed.
    static var expectedBinaryHash: String? {
        guard let hash = Bundle.main.object(forInfoDictionaryKey: "TallyFanHelperSHA256") as? String,
              hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash.lowercased()
    }

    /// The LaunchDaemon: started by launchd when the app connects to the socket, kept alive only while the crash
    /// marker exists so a helper that dies with fans forced is restarted and puts them back to automatic.
    static func launchDaemonPlist(allowedUID: uid_t) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [installedBinaryPath, "--allowed-uid", String(allowedUID)],
            "Sockets": [
                "Listener": [
                    "SockPathName": "/var/run/\(label).sock",
                    "SockPathMode": 0o600,
                    "SockPathOwner": Int(allowedUID),
                ],
            ],
            "KeepAlive": ["PathState": [markerPath: true]],
            "AssociatedBundleIdentifiers": ["io.github.dheerajkoppu.tally"],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
