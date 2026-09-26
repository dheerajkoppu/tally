import Foundation
import AppKit

/// Installs and removes the fan helper with one administrator prompt, through AppleScript's
/// `do shell script … with administrator privileges`, so the prompt names Tally.
enum FanHelperInstaller {
    enum Outcome {
        case done
        case cancelled
        case failed(String)
    }

    private static let queue = DispatchQueue(label: "tally.fans.installer", qos: .userInitiated)

    static func install(completion: @escaping (Outcome) -> Void) {
        guard let bundled = FanHelperLocation.bundledBinary else {
            completion(.failed("This copy of Tally has no fan helper. Build the app with scripts/build-app.sh."))
            return
        }
        guard let expectedHash = FanHelperLocation.expectedBinaryHash else {
            completion(.failed("This copy of Tally can't verify its fan helper. Build the app with scripts/build-app.sh."))
            return
        }
        let plistData: Data
        do {
            plistData = try FanHelperLocation.launchDaemonPlist(allowedUID: getuid())
        } catch {
            completion(.failed("Could not prepare the helper settings: \(error.localizedDescription)"))
            return
        }
        let label = FanHelperLocation.label
        let binary = quoted(FanHelperLocation.installedBinaryPath)
        let plist = quoted(FanHelperLocation.launchDaemonPath)
        // Nothing root installs is read back from a place other processes of this user could change during the
        // password prompt: the helper is checked against the hash sealed into the app, and the plist travels inline.
        let commands = [
            "/bin/launchctl bootout system/\(label) 2>/dev/null; true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(quoted(bundled.path)) \(binary)",
            "( [ \"$(/usr/bin/shasum -a 256 \(binary) | /usr/bin/cut -d ' ' -f 1)\" = \(quoted(expectedHash)) ] || ( /bin/rm -f \(binary); false ) )",
            "/bin/echo \(quoted(plistData.base64EncodedString())) | /usr/bin/base64 -D -o \(plist)",
            "/usr/sbin/chown root:wheel \(plist)",
            "/bin/chmod 644 \(plist)",
            "/bin/rm -f \(quoted("/var/run/\(label).sock"))",
            "/bin/launchctl bootstrap system \(plist)",
        ]
        run(commands, prompt: "Tally needs your password to install its fan helper.", completion: completion)
    }

    static func uninstall(completion: @escaping (Outcome) -> Void) {
        let label = FanHelperLocation.label
        let commands = [
            "/bin/launchctl bootout system/\(label) 2>/dev/null; true",
            "/bin/rm -f \(quoted(FanHelperLocation.launchDaemonPath)) \(quoted(FanHelperLocation.installedBinaryPath)) \(quoted("/var/run/\(label).sock")) \(quoted(FanHelperLocation.markerPath))",
        ]
        run(commands, prompt: "Tally needs your password to remove its fan helper.", completion: completion)
    }

    private static func run(_ commands: [String], prompt: String, completion: @escaping (Outcome) -> Void) {
        let shell = commands.joined(separator: " && ")
        let source = "do shell script \"\(escaped(shell))\" with prompt \"\(escaped(prompt))\" with administrator privileges"
        queue.async {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: source)
            script?.executeAndReturnError(&errorInfo)
            let outcome: Outcome
            if let errorInfo {
                let number = errorInfo[NSAppleScript.errorNumber] as? Int
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "The command failed."
                outcome = number == -128 ? .cancelled : .failed(message)
            } else {
                outcome = .done
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
