import Foundation
import Security

/// Replaces a copy of Tally with a release from GitHub, once the download proves to come from whoever signed that
/// copy and to be notarized by Apple. Only Check for Updates starts it.
public enum UpdateInstaller {
    public enum Failure: Error {
        case download
        case verification
        case replacement
    }

    private static let archiveName = "Tally.zip"
    private static let appName = "Tally.app"

    /// Whether the copy at `bundle` can be swapped where it sits. Development builds, and copies macOS runs from a
    /// read-only or randomized place, are sent to the download page instead.
    public static func canInstall(over bundle: URL) async -> Bool {
        let manager = FileManager.default
        guard bundle.pathExtension == "app", !bundle.path.contains("/AppTranslocation/"),
              manager.isWritableFile(atPath: bundle.path),
              manager.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else { return false }
        return teamIdentifier(of: bundle) != nil
    }

    /// Nothing at `bundle` changes unless every check passes, and then it changes in one rename.
    public static func install(tag: String, over bundle: URL) async throws {
        guard let archiveURL = archiveURL(forTag: tag), let installedVersion = version(of: bundle) else {
            throw Failure.download
        }
        let manager = FileManager.default
        // On the app's own volume, so the swap at the end is a rename.
        guard let staging = try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true) else {
            throw Failure.replacement
        }
        defer { try? manager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(archiveName)
        try await download(archiveURL, to: archive)
        let downloaded = staging.appendingPathComponent(appName, isDirectory: true)
        // The version check stops an older release, validly signed, from being served as an update.
        guard await unpack(archive, into: staging), isTrusted(downloaded, toReplace: bundle),
              let downloadedVersion = version(of: downloaded),
              isVersion(downloadedVersion, newerThan: installedVersion) else {
            throw Failure.verification
        }
        try Task.checkCancellation()
        do {
            // New metadata only, so the copy that lands is exactly the one that was checked.
            _ = try manager.replaceItemAt(bundle, withItemAt: downloaded, options: .usingNewMetadataOnly)
        } catch {
            throw Failure.replacement
        }
    }

    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    /// Built here rather than read from GitHub's answer, so the download can only come from Tally's releases.
    private static func archiveURL(forTag tag: String) -> URL? {
        guard !tag.isEmpty, tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else { return nil }
        return URL(string: "https://github.com/dheerajkoppu/tally/releases/download/\(tag)/\(archiveName)")
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (file, response) = try await session.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            throw Failure.download
        }
    }

    /// ditto, because it made the archive and puts back the symlinks and extended attributes the signature covers.
    private static func unpack(_ archive: URL, into directory: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", archive.path, directory.path]
            ditto.standardOutput = FileHandle.nullDevice
            ditto.standardError = FileHandle.nullDevice
            ditto.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            do {
                try ditto.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    /// The download must satisfy the installed copy's designated requirement (same bundle identifier, same
    /// Developer ID team) with every file intact, and carry Apple's notarization ticket.
    private static func isTrusted(_ downloaded: URL, toReplace bundle: URL) -> Bool {
        guard let installedCode = staticCode(at: bundle), let downloadedCode = staticCode(at: downloaded) else { return false }
        var designated: SecRequirement?
        var notarized: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(installedCode, [], &designated) == errSecSuccess,
              SecRequirementCreateWithString("notarized" as CFString, [], &notarized) == errSecSuccess else { return false }
        let everyFile = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(downloadedCode, everyFile, designated) == errSecSuccess
            && SecStaticCodeCheckValidity(downloadedCode, [], notarized) == errSecSuccess
    }

    /// Nil for ad hoc signatures, whose designated requirement names one exact build and so matches no release.
    private static func teamIdentifier(of bundle: URL) -> String? {
        guard let code = staticCode(at: bundle) else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func staticCode(at bundle: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func version(of bundle: URL) -> String? {
        let information = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        return information?["CFBundleShortVersionString"] as? String
    }
}
