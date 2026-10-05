import Foundation
import TallyExtras

// Usage: probe-update <copy of Tally.app> <release tag>
// Updates that copy in place from the release, as Check for Updates does. Point it at a spare copy.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: probe-update <copy of Tally.app> <release tag, such as v1.1.0>")
    exit(64)
}
let bundle = URL(fileURLWithPath: arguments[1])
let tag = arguments[2]

func version(of bundle: URL) -> String {
    let information = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
    return information?["CFBundleShortVersionString"] as? String ?? "unknown"
}

print("\(bundle.path) is version \(version(of: bundle))")
print("can update in place: \(await UpdateInstaller.canInstall(over: bundle) ? "yes" : "no")")

let started = Date()
do {
    try await UpdateInstaller.install(tag: tag, over: bundle)
    print(String(format: "installed %@ in %.1f s, now version %@", tag, Date().timeIntervalSince(started), version(of: bundle)))
} catch {
    print("not installed: \(error), still version \(version(of: bundle))")
    exit(1)
}
