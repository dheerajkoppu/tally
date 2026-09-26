import AppKit
import TallyCore

/// Something the user asked to stop in the Projects tab, waiting for confirmation.
struct StopRequest: Identifiable, Hashable {
    var id: String
    var title: String
    var message: String
    var pids: [Int32]
    /// The polite action's button title: "Stop" or "Stop All".
    var stopTitle: String = "Stop"
    /// Offer Force Quit only, as the "Force Quit Project" menu item asks.
    var forceOnly = false
    /// When each process started, so a pid reused while the confirmation is open is never stopped.
    var startDates: [Int32: Date] = [:]

    var quitRequest: QuitRequest {
        QuitRequest(id: id, title: title, message: message, pids: pids, appPid: nil, startDates: startDates)
    }
}

/// Confirmation requests and Finder, Terminal and browser actions for the Projects tab.
enum ProjectActions {
    static func stopRequest(for project: Project, force: Bool) -> StopRequest {
        let ports = Array(Set(project.ports)).sorted()
        let verb = force ? "Ends" : "Stops"
        var message = "\(verb) \(Format.processes(project.processes.count))"
        message += ports.isEmpty ? "" : " and frees \(ProjectText.ports(ports))"
        message += force ? " right away, without letting them clean up." : "."
        message += " Your Terminal windows stay open."
        return StopRequest(
            id: "project-\(project.path)",
            title: force ? "Force Quit \(project.name)?" : "Stop \(project.name)?",
            message: message,
            pids: project.processes.map(\.pid),
            forceOnly: force,
            startDates: startDates(of: project.processes)
        )
    }

    static func stopRequest(for process: DevProcess, in project: Project) -> StopRequest {
        let summary = ProjectText.command(process, in: project)
        var message = "Stops \(summary) (pid \(process.pid))"
        message += process.ports.isEmpty ? "." : " and frees \(ProjectText.ports(process.ports))."
        return StopRequest(id: "dev-\(process.pid)", title: "Stop \(process.name) in \(project.name)?", message: message, pids: [process.pid], startDates: startDates(of: [process]))
    }

    static func stopRequest(forIdle projects: [Project]) -> StopRequest {
        let processes = projects.flatMap(\.processes)
        let ports = Array(Set(projects.flatMap(\.ports))).sorted()
        let memory = Format.memory(projects.reduce(0) { $0 + $1.memoryBytes }).text
        let names = ProjectText.list(projects.map(\.name))
        let count = projects.count
        let title = count == 1 ? "Stop \(projects[0].name)?" : "Stop \(count) idle dev servers?"
        var message = "Stops \(Format.processes(processes.count)) in \(names)"
        message += ports.isEmpty ? " and frees \(memory)." : ", freeing \(memory) and \(ProjectText.ports(ports))."
        message += " Your Terminal windows stay open."
        return StopRequest(id: "idle-servers", title: title, message: message, pids: processes.map(\.pid), stopTitle: count == 1 ? "Stop" : "Stop All", startDates: startDates(of: processes))
    }

    private static func startDates(of processes: [DevProcess]) -> [Int32: Date] {
        var dates: [Int32: Date] = [:]
        for process in processes {
            if let startDate = process.startDate { dates[process.pid] = startDate }
        }
        return dates
    }

    static func showInFinder(_ project: Project) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path, isDirectory: true)])
    }

    static func openInTerminal(_ project: Project) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: project.path, isDirectory: true)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openInBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Wording shared by the rows, the banner and the confirmations.
enum ProjectText {
    /// "port 3000", "ports 3000, 4321, 8000"
    static func ports(_ ports: [Int]) -> String {
        let list = ports.map(String.init).joined(separator: ", ")
        return ports.count == 1 ? "port \(list)" : "ports \(list)"
    }

    /// "a", "a and b", "a, b and c"
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// The command line with the project folder and home folder shortened: "node server.js", "npm run dev".
    static func command(_ process: DevProcess, in project: Project) -> String {
        let home = NSHomeDirectory()
        let words = process.commandLine.split(separator: " ", omittingEmptySubsequences: true).map { word -> String in
            var text = String(word)
            if text.hasPrefix(project.path + "/") { text = String(text.dropFirst(project.path.count + 1)) }
            else if text.hasPrefix(home + "/") { text = "~" + text.dropFirst(home.count) }
            return text
        }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? process.name : joined
    }

    /// "~/Code/storefront"
    static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func runtime(_ process: DevProcess) -> String {
        process.kind == .other ? process.name : process.kind.label
    }
}
