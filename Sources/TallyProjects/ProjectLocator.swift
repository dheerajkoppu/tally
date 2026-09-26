import Darwin
import Foundation

/// Finds the project folder a path belongs to: the nearest folder with a project marker, never above the home folder.
///
/// Folders are never listed. Each marker name is checked with one `access` call, most common first, and the answer
/// is cached for ten minutes, so a folder costs nothing on later scans. Checking a file inside ~/Documents,
/// ~/Downloads or ~/Desktop can raise a privacy prompt; the scanner runs off the sampling queue, so a pending
/// prompt only delays the Projects list.
final class ProjectLocator {
    private static let markerNames = [
        ".git", "package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml", "Gemfile", "composer.json",
        "deno.json", "deno.jsonc", "bun.lock", "bun.lockb", "pnpm-workspace.yaml", "setup.py", "Pipfile", "manage.py",
        "mix.exs", "Package.swift", "pom.xml", "build.gradle", "build.gradle.kts", "compose.yaml", "compose.yml",
        "docker-compose.yml", "docker-compose.yaml", "Procfile", "project.clj", "deps.edn", "build.sbt", "stack.yaml",
        "dune-project", "pubspec.yaml", "global.json",
    ]

    /// Folders that belong to a project's dependencies or build output, never a project of their own.
    private static let vendorComponents: Set<String> = [
        "node_modules", ".venv", "venv", "site-packages", "__pycache__", ".git", "vendor", ".build", "target", "dist", ".next",
    ]

    /// Outside the home folder, these never hold projects.
    private static let systemRoots = [
        "/System", "/usr", "/bin", "/sbin", "/Library", "/Applications", "/private/var", "/var", "/opt", "/etc", "/dev", "/cores",
        "/nix",
    ]

    private static let cacheLifetime: TimeInterval = 600
    /// Uncached folders checked per scan. A process whose folder did not fit waits for the next scan.
    private static let folderChecksPerScan = 48

    private struct CachedAnswer {
        var value: Bool
        var checked: Date
    }

    let home: String
    private var projectFolders: [String: CachedAnswer] = [:]
    private var files: [String: CachedAnswer] = [:]
    private var checksLeft = folderChecksPerScan

    init(home: String = NSHomeDirectory()) {
        self.home = (home as NSString).standardizingPath
    }

    /// Resets the per-scan budget of uncached folder checks.
    func beginScan() {
        checksLeft = Self.folderChecksPerScan
    }

    enum Lookup {
        case found(String)
        case missing
        /// This scan ran out of folder checks before finding out.
        case deferred
    }

    /// The nearest folder at or above `directory` with a project marker.
    func lookUpRoot(from directory: String, now: Date) -> Lookup {
        guard var current = startingPoint(for: directory) else { return .missing }
        while isEligible(current) {
            guard let isProject = isProjectFolder(current, now: now) else { return .deferred }
            if isProject { return .found(current) }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return .missing
    }

    /// The nearest folder at or above `directory` with a project marker, or nil when there is none or this scan
    /// could not find out.
    func root(from directory: String, now: Date) -> String? {
        if case .found(let root) = lookUpRoot(from: directory, now: now) { return root }
        return nil
    }

    /// A folder without markers that can still stand in as a project, for a process that listens on a port there.
    func fallbackRoot(for directory: String) -> String? {
        guard let start = startingPoint(for: directory), isEligible(start) else { return nil }
        return start
    }

    /// Whether a file of this name sits in the folder, cached like the markers.
    func hasFile(named name: String, in directory: String, now: Date) -> Bool {
        let path = directory + "/" + name
        if let cached = files[path], now.timeIntervalSince(cached.checked) < Self.cacheLifetime { return cached.value }
        let exists = access(path, F_OK) == 0
        files[path] = CachedAnswer(value: exists, checked: now)
        return exists
    }

    func pruneCache(now: Date) {
        projectFolders = projectFolders.filter { now.timeIntervalSince($0.value.checked) < Self.cacheLifetime }
        files = files.filter { now.timeIntervalSince($0.value.checked) < Self.cacheLifetime }
    }

    /// True for the home folder itself and the root, where the working directory says nothing about the project.
    func isUninformative(_ directory: String) -> Bool {
        let path = (directory as NSString).standardizingPath
        return path == "/" || path == home || path.isEmpty
    }

    /// Nil when the folder is not cached and this scan has no checks left.
    private func isProjectFolder(_ directory: String, now: Date) -> Bool? {
        if let cached = projectFolders[directory], now.timeIntervalSince(cached.checked) < Self.cacheLifetime { return cached.value }
        guard checksLeft > 0 else { return nil }
        checksLeft -= 1
        let isProject = Self.markerNames.contains { access(directory + "/" + $0, F_OK) == 0 }
        projectFolders[directory] = CachedAnswer(value: isProject, checked: now)
        return isProject
    }

    /// Cuts a path at the first dependency or build folder, so `app/node_modules/vite` becomes `app`.
    private func startingPoint(for directory: String) -> String? {
        let path = (directory as NSString).standardizingPath
        guard path.hasPrefix("/") else { return nil }
        var kept: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if Self.vendorComponents.contains(String(component)) { break }
            kept.append(String(component))
        }
        return "/" + kept.joined(separator: "/")
    }

    private func isEligible(_ path: String) -> Bool {
        if path == home || path == "/" { return false }
        if path.hasPrefix(home + "/") {
            let relative = path.dropFirst(home.count + 1)
            let top = relative.split(separator: "/").first.map(String.init) ?? ""
            return !top.hasPrefix(".") && top != "Library"
        }
        if Self.systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        let components = path.split(separator: "/")
        if components.first == "Users" && components.count <= 2 { return false }
        if components.first == "Volumes" && components.count <= 2 { return false }
        if path == "/tmp" || path == "/private/tmp" || path == "/private" { return false }
        return true
    }
}
