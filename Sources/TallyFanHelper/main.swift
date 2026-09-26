import Foundation
import os

/// The privileged fan helper. Installed as a root LaunchDaemon with socket activation, so it only runs while Tally
/// talks to it and exits shortly after every fan is back to automatic.
///
///   io.github.dheerajkoppu.tally.fanhelper [--allowed-uid UID]                 launchd mode
///   io.github.dheerajkoppu.tally.fanhelper --socket PATH [--dry-run] [--idle-exit SECONDS] [--allowed-uid UID]
///   io.github.dheerajkoppu.tally.fanhelper --probe                             print the fan keys and exit
/// `--dry-run` logs each SMC write with its encoding instead of making it; `--marker PATH` moves the crash marker.
let label = "io.github.dheerajkoppu.tally.fanhelper"
let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let socketPath = argument(after: "--socket")
let isDryRun = arguments.contains("--dry-run")
let logger = Logger(subsystem: label, category: "fans")
setvbuf(stderr, nil, _IOLBF, 0)

func log(_ message: String) {
    if socketPath != nil || isDryRun {
        FileHandle.standardError.write(Data("[fanhelper] \(message)\n".utf8))
    } else {
        logger.log("\(message, privacy: .public)")
    }
}

if arguments.contains("--version") {
    print(HelperServer.version)
    exit(0)
}

let markerPath = argument(after: "--marker") ?? socketPath.map { $0 + ".forced" } ?? "/var/run/\(label).forced"

/// Gives up without leaving the crash marker behind, so launchd does not keep restarting a helper that cannot run.
func giveUp(_ message: String, restoring driver: FanDriver? = nil) -> Never {
    log(message)
    if let driver, FileManager.default.fileExists(atPath: markerPath) { driver.restoreAll() }
    unlink(markerPath)
    exit(1)
}

guard let smc = SMCConnection() else { giveUp("Could not open the SMC") }
let driver = FanDriver(smc: smc, dryRun: isDryRun, log: log)

if arguments.contains("--probe") {
    print(driver.probe())
    exit(0)
}

let allowedUID: uid_t? = argument(after: "--allowed-uid").flatMap { UInt32($0) } ?? (socketPath != nil ? getuid() : nil)
let idleExitDelay = argument(after: "--idle-exit").flatMap(TimeInterval.init) ?? 10

let listener: Int32
if let testSocket = socketPath {
    guard let bound = UnixSocket.listen(at: testSocket) else { giveUp("Could not listen on \(testSocket)", restoring: driver) }
    listener = bound
    atexit { if let path = socketPath { unlink(path) } }
} else {
    guard let activated = UnixSocket.activateFromLaunchd(name: "Listener") else {
        giveUp("No socket from launchd; run with --socket PATH to test by hand", restoring: driver)
    }
    listener = activated
}

log("Started\(isDryRun ? " in dry run" : ""), \(driver.fanCount) fans, allowed uid \(allowedUID.map(String.init) ?? "root only")")
let server = HelperServer(listener: listener, driver: driver, allowedUID: allowedUID, idleExitDelay: idleExitDelay, markerPath: markerPath, log: log)
server.start()
dispatchMain()
