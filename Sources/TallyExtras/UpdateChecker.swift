import AppKit

/// Asks GitHub for the latest release when someone chooses Check for Updates. Tally never checks on its own.
@MainActor
public enum UpdateChecker {
    private enum Outcome {
        case upToDate
        case available(version: String, page: URL)
        case failed
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/dheerajkoppu/tally/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/dheerajkoppu/tally/releases/latest")!
    private static var isChecking = false

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public static func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let outcome = await fetchLatestRelease()
            isChecking = false
            report(outcome)
        }
    }

    private static func fetchLatestRelease() async -> Outcome {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tally/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String else { return .failed }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isVersion(latest, newerThan: currentVersion) else { return .upToDate }
        // Only ever open a GitHub page, whatever the response says.
        var page = releasesPage
        if let link = (release["html_url"] as? String).flatMap(URL.init(string:)), link.scheme == "https", link.host == "github.com" {
            page = link
        }
        return .available(version: latest, page: page)
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    private static func report(_ outcome: Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate:
            alert.messageText = "You're up to date"
            alert.informativeText = "Tally \(currentVersion) is the newest version."
            alert.addButton(withTitle: "OK")
        case .available(let version, _):
            alert.messageText = "Tally \(version) is available"
            alert.informativeText = "You have version \(currentVersion). Download the new version and replace the copy in your Applications folder. Your history and settings stay."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        case .failed:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Tally couldn't reach GitHub. Check your internet connection and try again."
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate()
        let response = alert.runModal()
        if case .available(_, let page) = outcome, response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }
}
