import AppKit

/// Asks GitHub for the latest release when someone chooses Check for Updates, and installs it if they agree.
/// Tally never checks on its own.
@MainActor
public enum UpdateChecker {
    private enum Outcome {
        case upToDate
        case available(version: String, tag: String, page: URL, installsInPlace: Bool)
        case failed
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/dheerajkoppu/tally/releases/latest")!
    private static let releasesPage = URL(string: "https://github.com/dheerajkoppu/tally/releases/latest")!
    private static var isChecking = false
    private static var installResult: Result<Void, Error>?

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public static func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let outcome = await fetchLatestRelease()
            isChecking = false
            // An alert opened from a main-queue job holds up the main actor, which the install needs while its alert is up.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { report(outcome) }
            }
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
        guard UpdateInstaller.isVersion(latest, newerThan: currentVersion) else { return .upToDate }
        // Only ever open a GitHub page, whatever the response says.
        var page = releasesPage
        if let link = (release["html_url"] as? String).flatMap(URL.init(string:)), link.scheme == "https", link.host == "github.com" {
            page = link
        }
        let installsInPlace = await UpdateInstaller.canInstall(over: Bundle.main.bundleURL)
        return .available(version: latest, tag: tag, page: page, installsInPlace: installsInPlace)
    }

    private static func report(_ outcome: Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate:
            alert.messageText = "You're up to date"
            alert.informativeText = "Tally \(currentVersion) is the newest version."
            alert.addButton(withTitle: "OK")
        case .available(let version, _, _, let installsInPlace):
            alert.messageText = "Tally \(version) is available"
            if installsInPlace {
                alert.informativeText = "You have version \(currentVersion). Tally downloads the new version from GitHub, checks that it's signed and notarized, and reopens. Your history and settings stay."
                alert.addButton(withTitle: "Install and Relaunch")
            } else {
                alert.informativeText = "You have version \(currentVersion). Download the new version and replace the copy in your Applications folder. Your history and settings stay."
                alert.addButton(withTitle: "Download")
            }
            alert.addButton(withTitle: "Later")
        case .failed:
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Tally couldn't reach GitHub. Check your internet connection and try again."
            alert.addButton(withTitle: "OK")
        }
        NSApp.activate()
        let response = alert.runModal()
        guard case .available(let version, let tag, let page, let installsInPlace) = outcome, response == .alertFirstButtonReturn else { return }
        if installsInPlace {
            install(version: version, tag: tag, page: page)
        } else {
            NSWorkspace.shared.open(page)
        }
    }

    private static func install(version: String, tag: String, page: URL) {
        let progress = NSAlert()
        progress.messageText = "Updating to Tally \(version)"
        progress.informativeText = "Downloading the new version and checking its signature."
        let indicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 228, height: 20))
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        progress.accessoryView = indicator
        progress.addButton(withTitle: "Cancel")

        let bundle = Bundle.main.bundleURL
        installResult = nil
        let installation = Task {
            do {
                try await UpdateInstaller.install(tag: tag, over: bundle)
                installResult = .success(())
            } catch {
                installResult = .failure(error)
            }
            // After Cancel the alert is gone, and aborting then would end some later alert.
            if NSApp.modalWindow === progress.window { NSApp.abortModal() }
        }
        progress.runModal()
        installation.cancel()

        switch installResult {
        case .success:
            relaunch()
        case .failure(let failure as UpdateInstaller.Failure):
            explain(failure, version: version, page: page)
        default:
            break
        }
    }

    private static func explain(_ failure: UpdateInstaller.Failure, version: String, page: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't install Tally \(version)"
        switch failure {
        case .download:
            alert.informativeText = "Tally couldn't download the new version. Check your internet connection and try again."
            alert.addButton(withTitle: "OK")
        case .verification:
            // No link to the download here: a release that fails these checks shouldn't be installed by hand either.
            alert.informativeText = "The download didn't pass Tally's signature checks, so nothing was installed. Try again later."
            alert.addButton(withTitle: "OK")
        case .replacement:
            alert.informativeText = "Tally couldn't replace the copy on this Mac. Download the new version and replace it yourself. Your history and settings stay."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        }
        let response = alert.runModal()
        if case .replacement = failure, response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(page)
        }
    }

    /// Leaves a shell waiting for this copy to quit, which then opens the one that replaced it.
    private static func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
        ]
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        try? waiter.run()
        NSApp.terminate(nil)
    }
}
