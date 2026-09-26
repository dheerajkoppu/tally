import Foundation

/// What Tally needs to know about one .app bundle.
struct BundleRecord {
    /// The path used as the app's id. Cryptex apps such as Safari map back to /Applications.
    var canonicalPath: String
    var name: String
    var identifier: String?
    /// The main executable as processes report it (under the original, not the canonical, path).
    var executablePath: String?
    /// In /Applications, ~/Applications, /System/Applications or Finder: an app people open themselves.
    var isUserFacingLocation: Bool
    /// Part of macOS: /System, /Library/Apple, /usr.
    var isSystemLocation: Bool
}

/// Caches bundle lookups per path. Used only from the sampling queue.
final class BundleCatalog {
    private var chains: [String: [String]] = [:]
    private var records: [String: BundleRecord] = [:]
    /// Canonical path to the real bundle directory, where they differ.
    private var realPaths: [String: String] = [:]
    private let homeApplicationsPrefix = NSHomeDirectory() + "/Applications/"
    private let protectedPrefixes = ["/Desktop/", "/Documents/", "/Downloads/", "/Library/Mobile Documents/"].map { NSHomeDirectory() + $0 } + ["/Volumes/"]
    private let ownBundlePath = Bundle.main.bundlePath

    private static let userFacingPrefixes = ["/Applications/", "/System/Applications/"]
    private static let cryptexApplicationsMarker = "/Cryptexes/App/System/Applications/"
    private static let finderPath = "/System/Library/CoreServices/Finder.app"
    private static let systemBundlePrefixes = ["/System/", "/Library/Apple/", "/usr/", "/private/var/db/", "/Library/Developer/CommandLineTools/"]
    private static let systemExecutablePrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/usr/lib/", "/usr/share/", "/sbin/", "/bin/",
        "/Library/Apple/", "/private/var/db/", "/Library/Developer/CommandLineTools/", "/Library/Developer/PrivateFrameworks/",
    ]

    /// The .app bundles containing an executable, outermost first.
    func appChain(forExecutable path: String) -> [String] {
        if let cached = chains[path] { return cached }
        var chain: [String] = []
        var current = ""
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for component in components.dropLast() {
            current += "/"
            current += component
            if component.count > 4, component.lowercased().hasSuffix(".app") { chain.append(current) }
        }
        if chains.count > 20_000 { chains.removeAll(keepingCapacity: true) }
        chains[path] = chain
        return chain
    }

    func record(forBundle path: String) -> BundleRecord {
        if let cached = records[path] { return cached }
        let canonical = canonicalPath(for: path)
        // Reading a file in a privacy-protected folder can raise a prompt and block until it is answered,
        // so bundles there are described from their path alone.
        let isReadable = !isPrivacyProtected(path)
        let info = isReadable ? CFBundleCopyInfoDictionaryInDirectory(URL(fileURLWithPath: path, isDirectory: true) as CFURL) as? [String: Any] : nil
        let identifier = info?["CFBundleIdentifier"] as? String
        let executableName = info?["CFBundleExecutable"] as? String
        // iPhone and iPad apps keep their executable at the top of the bundle.
        let executablePath = executableName.map { name in
            (FileManager.default.fileExists(atPath: path + "/Contents") ? path + "/Contents/MacOS/" : path + "/") + name
        }
        let record = BundleRecord(
            canonicalPath: canonical,
            name: isReadable ? displayName(forBundle: canonical, info: info) : Self.fileName(ofBundle: path),
            identifier: identifier,
            executablePath: executablePath,
            isUserFacingLocation: isUserFacingLocation(path),
            isSystemLocation: Self.systemBundlePrefixes.contains { path.hasPrefix($0) } && !path.hasPrefix("/usr/local/")
        )
        if records.count > 5_000 { records.removeAll(keepingCapacity: true) }
        records[path] = record
        if canonical != path { realPaths[canonical] = path }
        return record
    }

    /// The bundle's real directory: /Applications/Safari.app is a symlink, and icons drawn from it carry an alias badge.
    func realPath(forCanonical path: String) -> String {
        realPaths[path] ?? path
    }

    /// Desktop, Documents, Downloads, iCloud Drive and other volumes, except this app's own bundle.
    private func isPrivacyProtected(_ path: String) -> Bool {
        guard path != ownBundlePath else { return false }
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }

    private static func fileName(ofBundle path: String) -> String {
        let fileName = (path as NSString).lastPathComponent
        return fileName.lowercased().hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
    }

    func isSystemExecutable(_ path: String) -> Bool {
        Self.systemExecutablePrefixes.contains { path.hasPrefix($0) }
    }

    private func isUserFacingLocation(_ path: String) -> Bool {
        if path == Self.finderPath { return true }
        if Self.userFacingPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        if path.hasPrefix(homeApplicationsPrefix) { return true }
        return path.contains(Self.cryptexApplicationsMarker)
    }

    /// Safari lives in a cryptex (/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app)
    /// but people know it as /Applications/Safari.app, which is a symlink to it.
    private func canonicalPath(for path: String) -> String {
        guard let range = path.range(of: Self.cryptexApplicationsMarker) else { return path }
        let candidate = "/Applications/" + path[range.upperBound...]
        return FileManager.default.fileExists(atPath: candidate) ? candidate : path
    }

    private func displayName(forBundle path: String, info: [String: Any]?) -> String {
        var name = FileManager.default.displayName(atPath: path)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        if !name.isEmpty { return name }
        if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty { return display }
        if let bundleName = info?["CFBundleName"] as? String, !bundleName.isEmpty { return bundleName }
        return Self.fileName(ofBundle: path)
    }
}
