import Foundation
import Darwin

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibilityGetPidResponsibleForPid(_ pid: pid_t) -> pid_t

/// The app a sound-playing process belongs to.
struct AudioOwner: Hashable {
    var id: String
    var name: String
    var bundleIdentifier: String?
    var iconPath: String?
}

/// Folds helper processes into their app: Chrome's helpers go to Google Chrome, WebKit's GPU process to the
/// app that launched it, command-line tools stay themselves.
enum AudioOwnerResolver {
    private static let cryptexPrefixes = [
        "/System/Volumes/Preboot/Cryptexes/App",
        "/System/Volumes/Preboot/Cryptexes/OS",
        "/System/Volumes/Preboot/Cryptexes/Incoming/OS",
    ]
    private static let systemSettingsPath = "/System/Applications/System Settings.app"
    private static let protectedPrefixes = ["/Desktop/", "/Documents/", "/Downloads/", "/Library/Mobile Documents/"].map { NSHomeDirectory() + $0 } + ["/Volumes/"]

    static func owner(pid: pid_t, bundleIdentifier: String?) -> AudioOwner {
        let path = executablePath(pid)
        if let path, let bundle = outermostAppBundle(in: path) {
            return appOwner(bundlePath: bundle)
        }
        let responsible = responsibilityGetPidResponsibleForPid(pid)
        if let path, isServicePath(path), responsible > 0, responsible != pid,
           let responsiblePath = executablePath(responsible), let bundle = outermostAppBundle(in: responsiblePath) {
            return appOwner(bundlePath: bundle)
        }
        guard let path else {
            let name = bundleIdentifier.flatMap { $0.split(separator: ".").last.map(String.init) } ?? "Process \(pid)"
            return AudioOwner(id: "pid-\(pid)", name: name, bundleIdentifier: bundleIdentifier, iconPath: nil)
        }
        let executableName = (path as NSString).lastPathComponent
        if executableName == "systemsoundserverd" {
            return AudioOwner(id: path, name: "System Sounds", bundleIdentifier: bundleIdentifier, iconPath: systemSettingsPath)
        }
        if executableName.hasPrefix("com.apple.WebKit.") {
            return AudioOwner(id: path, name: "Web Content", bundleIdentifier: bundleIdentifier, iconPath: path)
        }
        return AudioOwner(id: path, name: executableName, bundleIdentifier: bundleIdentifier, iconPath: path)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// "/Applications/Google Chrome.app" for any path inside it, including nested helper apps.
    static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return normalized(String(path[..<range.lowerBound]) + ".app")
    }

    /// XPC services and system helpers play audio on behalf of the app that launched them.
    private static func isServicePath(_ path: String) -> Bool {
        path.contains(".xpc/") || path.contains(".appex/") || path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
    }

    /// Safari and other cryptex apps run from the Preboot volume but live in /Applications as far as the user knows.
    private static func normalized(_ bundlePath: String) -> String {
        for prefix in cryptexPrefixes where bundlePath.hasPrefix(prefix) {
            let stripped = String(bundlePath.dropFirst(prefix.count))
            let candidates = [stripped, "/Applications/" + (bundlePath as NSString).lastPathComponent]
            if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) { return existing }
        }
        return bundlePath
    }

    private static func appOwner(bundlePath: String) -> AudioOwner {
        // Reading a bundle in a privacy-protected folder raises a prompt and blocks the audio queue until it is answered.
        if protectedPrefixes.contains(where: { bundlePath.hasPrefix($0) }) {
            let fileName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            return AudioOwner(id: bundlePath, name: fileName, bundleIdentifier: nil, iconPath: bundlePath)
        }
        let bundle = Bundle(path: bundlePath)
        var name = FileManager.default.displayName(atPath: bundlePath)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty {
            name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return AudioOwner(id: bundlePath, name: name, bundleIdentifier: bundle?.bundleIdentifier, iconPath: bundlePath)
    }
}
