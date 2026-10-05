// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tally",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TallyCore"),
        .target(
            name: "TallySystem",
            dependencies: ["TallyCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("SystemConfiguration"), .linkedFramework("CoreWLAN")]
        ),
        .target(
            name: "TallyProcesses",
            dependencies: ["TallyCore"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "TallySensors",
            dependencies: ["TallyCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOBluetooth")]
        ),
        .target(
            name: "TallyHistory",
            dependencies: ["TallyCore"],
            linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("UserNotifications")]
        ),
        .target(name: "TallyProjects", dependencies: ["TallyCore"]),
        .target(name: "TallyDashboard", dependencies: ["TallyCore"]),
        .target(name: "TallyMenuBar", dependencies: ["TallyCore"]),
        .target(
            name: "TallyExtras",
            dependencies: ["TallyCore"],
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .target(name: "TallyFanControl", dependencies: ["TallyCore"]),
        // The root fan helper. Kept free of SwiftUI and AppKit; build-app.sh copies it into the app bundle.
        .executableTarget(name: "TallyFanHelper", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(
            name: "Tally",
            dependencies: [
                "TallyCore", "TallySystem", "TallyProcesses", "TallySensors", "TallyHistory",
                "TallyProjects", "TallyDashboard", "TallyMenuBar", "TallyExtras",
                "TallyFanControl",
            ]
        ),
        .executableTarget(name: "probe-system", dependencies: ["TallyCore", "TallySystem"], path: "Probes/probe-system"),
        .executableTarget(name: "probe-processes", dependencies: ["TallyCore", "TallyProcesses"], path: "Probes/probe-processes"),
        .executableTarget(name: "probe-sensors", dependencies: ["TallyCore", "TallySensors"], path: "Probes/probe-sensors"),
        .executableTarget(name: "probe-history", dependencies: ["TallyCore", "TallyHistory"], path: "Probes/probe-history"),
        .executableTarget(name: "probe-projects", dependencies: ["TallyCore", "TallyProjects"], path: "Probes/probe-projects"),
        .executableTarget(name: "probe-update", dependencies: ["TallyExtras"], path: "Probes/probe-update"),
    ],
    swiftLanguageModes: [.v5]
)
