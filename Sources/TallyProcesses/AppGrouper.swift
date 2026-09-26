import Foundation

/// What grouping needs to know about one process.
struct GroupingInput {
    var pid: Int32
    var parentPid: Int32
    var uid: UInt32
    var executablePath: String?
    /// The executable's file name, worked out once per process.
    var executableName: String?
    var responsiblePid: Int32?
    var fallbackName: String
}

enum GroupKey: Hashable {
    /// Canonical bundle path of the app.
    case bundle(String)
    /// The single "macOS" row.
    case system
    /// Executable path of a command-line tool or daemon.
    case tool(String)
}

struct GroupAssignment {
    var key: GroupKey
    /// The process is the app itself: the main executable of the bundle it is grouped under.
    var isAppMain: Bool
    /// LaunchServices lists the process as a Dock app.
    var isRegularApp: Bool
    var processName: String
}

/// Folds processes into the apps they belong to.
///
/// 1. A process inside a .app belongs to the outermost bundle (or the innermost one that is a Dock app,
///    such as Simulator inside Xcode). Helpers, XPC services and login items go with their app. A tool
///    shipped inside an app but started by another app (Xcode's compiler run from Terminal) goes to that app.
/// 2. Otherwise it joins the app macOS holds responsible for it, or failing that the nearest ancestor's
///    group, so shells and dev servers land under Terminal, iTerm, VS Code or Cursor.
/// 3. What is left of macOS (system paths, system bundles, root and service accounts) is one "macOS" row.
/// 4. Anything else is a tool row keyed by its executable path.
final class AppGrouper {
    private enum Placement {
        /// An app people open themselves: in an Applications folder, Finder, or a Dock app.
        case app(originalBundle: String)
        /// A third-party bundle outside the Applications folders, such as a login item helper.
        case helperBundle(originalBundle: String)
        case systemBundle
        case system
        case unbundled(key: String)
    }

    private let catalog: BundleCatalog
    private let runningApplications: RunningApplications
    private let currentUID = getuid()

    init(catalog: BundleCatalog, runningApplications: RunningApplications) {
        self.catalog = catalog
        self.runningApplications = runningApplications
    }

    func assign(_ inputs: [GroupingInput]) -> [GroupAssignment] {
        let count = inputs.count
        var indexByPid = [Int32: Int](minimumCapacity: count)
        for (index, input) in inputs.enumerated() { indexByPid[input.pid] = index }

        var chains = [[String]](repeating: [], count: count)
        var mainBundles = [String?](repeating: nil, count: count)
        var isRegular = [Bool](repeating: false, count: count)
        var regularBundles = Set<String>()
        for (index, input) in inputs.enumerated() {
            guard let path = input.executablePath else { continue }
            let chain = catalog.appChain(forExecutable: path)
            guard let innermost = chain.last else { continue }
            chains[index] = chain
            mainBundles[index] = chain.last { catalog.record(forBundle: $0).executablePath == path }
            if runningApplications.isRegular(pid: input.pid, executableName: input.executableName) {
                isRegular[index] = true
                regularBundles.insert(innermost)
            }
        }

        var placements = [Placement](repeating: .system, count: count)
        var userFacingApps = Set<String>()
        var appsByIdentifier: [String: String] = [:]
        for index in 0..<count {
            let placement = place(inputs[index], chain: chains[index], regularBundles: regularBundles)
            placements[index] = placement
            if case .app(let original) = placement {
                let record = catalog.record(forBundle: original)
                userFacingApps.insert(record.canonicalPath)
                if let identifier = record.identifier { appsByIdentifier[identifier] = record.canonicalPath }
            }
        }

        func canonicalMainBundle(_ index: Int) -> String? {
            mainBundles[index].map { catalog.record(forBundle: $0).canonicalPath }
        }

        // Who each running app's main process answers to. An app started from Terminal passes Terminal on to
        // everything it launches, and those processes still belong to the app.
        var mainResponsibles: [String: Set<Int32>] = [:]
        for index in 0..<count {
            guard let bundle = canonicalMainBundle(index) else { continue }
            mainResponsibles[bundle, default: []].insert(inputs[index].responsiblePid ?? inputs[index].pid)
        }

        var resolved = [GroupKey?](repeating: nil, count: count)
        var visiting = [Bool](repeating: false, count: count)

        func ownKey(_ index: Int) -> GroupKey {
            switch placements[index] {
            case .app(let original), .helperBundle(let original):
                return .bundle(catalog.record(forBundle: original).canonicalPath)
            case .systemBundle, .system:
                return .system
            case .unbundled(let key):
                return .tool(key)
            }
        }

        func responsibleGroup(_ index: Int) -> GroupKey? {
            let input = inputs[index]
            guard let responsible = input.responsiblePid, responsible > 1, responsible != input.pid,
                  let other = indexByPid[responsible] else { return nil }
            let key = resolve(other)
            return key == .system ? nil : key
        }

        func ancestorGroup(_ index: Int) -> GroupKey? {
            let input = inputs[index]
            guard input.parentPid > 1, input.parentPid != input.pid, let other = indexByPid[input.parentPid] else { return nil }
            let key = resolve(other)
            return key == .system ? nil : key
        }

        func hasAncestor(_ index: Int, thatIsMainOf bundle: String) -> Bool {
            var current = inputs[index].parentPid
            var steps = 0
            while current > 1, steps < 64, let other = indexByPid[current] {
                if canonicalMainBundle(other) == bundle { return true }
                current = inputs[other].parentPid
                steps += 1
            }
            return false
        }

        /// A running app whose bundle id prefixes this one: "pro.usage.mac.Helper" belongs to "pro.usage.mac".
        func identifierParent(of identifier: String?) -> String? {
            guard let identifier else { return nil }
            var components = identifier.split(separator: ".")
            while components.count > 3 {
                components.removeLast()
                if let app = appsByIdentifier[components.joined(separator: ".")] { return app }
            }
            return nil
        }

        func decide(_ index: Int) -> GroupKey {
            let own = ownKey(index)
            switch placements[index] {
            case .app:
                guard mainBundles[index] == nil, case .bundle(let ownBundle) = own,
                      let responsible = inputs[index].responsiblePid,
                      mainResponsibles[ownBundle]?.contains(responsible) != true,
                      let joined = responsibleGroup(index), joined != own,
                      case .bundle(let joinedBundle) = joined, userFacingApps.contains(joinedBundle),
                      !hasAncestor(index, thatIsMainOf: ownBundle) else { return own }
                return joined
            case .helperBundle(let original):
                if let joined = responsibleGroup(index), case .bundle = joined { return joined }
                if let parent = identifierParent(of: catalog.record(forBundle: original).identifier) { return .bundle(parent) }
                return own
            case .system:
                if let joined = responsibleGroup(index) ?? ancestorGroup(index) { return joined }
                // Privileged helpers and system extensions are named after their app's bundle id.
                if let path = inputs[index].executablePath, !catalog.isSystemExecutable(path),
                   let parent = identifierParent(of: inputs[index].executableName) {
                    return .bundle(parent)
                }
                return own
            case .systemBundle, .unbundled:
                return responsibleGroup(index) ?? ancestorGroup(index) ?? own
            }
        }

        func resolve(_ index: Int) -> GroupKey {
            if let key = resolved[index] { return key }
            if visiting[index] { return ownKey(index) }
            visiting[index] = true
            let key = decide(index)
            visiting[index] = false
            resolved[index] = key
            return key
        }

        var assignments: [GroupAssignment] = []
        assignments.reserveCapacity(count)
        for index in 0..<count {
            let key = resolve(index)
            var isAppMain = false
            if case .bundle(let bundle) = key { isAppMain = canonicalMainBundle(index) == bundle }
            assignments.append(GroupAssignment(
                key: key,
                isAppMain: isAppMain,
                isRegularApp: isRegular[index],
                processName: processName(inputs[index], mainBundle: mainBundles[index])
            ))
        }
        return assignments
    }

    /// The group name for a key.
    func groupName(for key: GroupKey) -> String {
        switch key {
        case .bundle(let path): return catalog.record(forBundle: path).name
        case .system: return "macOS"
        case .tool(let key):
            let fileName = (key as NSString).lastPathComponent
            // Each booted iOS simulator runs its own launchd, and everything inside the device answers to it.
            return fileName == "launchd_sim" ? "Simulator" : fileName
        }
    }

    func bundleIdentifier(forBundle path: String) -> String? {
        catalog.record(forBundle: path).identifier
    }

    func realBundlePath(forBundle path: String) -> String {
        catalog.realPath(forCanonical: path)
    }

    private func place(_ input: GroupingInput, chain: [String], regularBundles: Set<String>) -> Placement {
        let isServiceAccount = input.uid < 500 && input.uid != currentUID
        guard let path = input.executablePath else {
            return isServiceAccount ? .system : .unbundled(key: input.fallbackName)
        }
        if let outermost = chain.first {
            let chosen = chain.last { regularBundles.contains($0) } ?? outermost
            let record = catalog.record(forBundle: chosen)
            if regularBundles.contains(chosen) || record.isUserFacingLocation { return .app(originalBundle: chosen) }
            if record.isSystemLocation { return .systemBundle }
            return .helperBundle(originalBundle: chosen)
        }
        if isServiceAccount || catalog.isSystemExecutable(path) { return .system }
        return .unbundled(key: path)
    }

    /// The name macOS shows for registered apps and helpers ("Safari Web Content"), else the bundle's name
    /// for a main executable, else the full file name.
    private func processName(_ input: GroupingInput, mainBundle: String?) -> String {
        if let localized = runningApplications.localizedName(pid: input.pid, executableName: input.executableName) { return localized }
        if let mainBundle { return catalog.record(forBundle: mainBundle).name }
        if let fileName = input.executableName, !fileName.isEmpty { return fileName }
        return input.fallbackName
    }
}
