import Foundation
import TallyCore

/// How the Projects tab reads a project's activity.
enum ProjectStatus {
    /// Quiet for less than this shows no status pill: the server was in use a moment ago.
    static let pillThreshold: TimeInterval = 10 * 60
    /// Quiet for at least this counts as a dev server left running, pointed out in the banner.
    static let idleServerThreshold: TimeInterval = 30 * 60

    /// Working if any process is, barely used if every process is, otherwise idle since the latest activity.
    static func activity(of project: Project) -> DevActivity {
        var earliestUp: Date?
        var allBarelyUsed = true
        var latestActivity: Date?
        for process in project.processes {
            switch process.activity {
            case .working:
                return .working
            case .barelyUsed(let upSince):
                earliestUp = min(earliestUp ?? upSince, upSince)
            case .idle:
                allBarelyUsed = false
            }
            if let date = process.lastActiveDate ?? process.startDate {
                latestActivity = max(latestActivity ?? date, date)
            }
        }
        if allBarelyUsed, let earliestUp { return .barelyUsed(upSince: earliestUp) }
        return .idle(since: latestActivity ?? Date())
    }

    /// A dev server holding ports that has done nothing for a while.
    static func isIdleServer(_ project: Project, now: Date) -> Bool {
        guard !project.ports.isEmpty else { return false }
        switch activity(of: project) {
        case .working: return false
        case .barelyUsed: return true
        case .idle(let since): return now.timeIntervalSince(since) >= idleServerThreshold
        }
    }

    /// The status pill's text and symbol, or nil when the project was busy a few minutes ago.
    static func pill(for activity: DevActivity, now: Date) -> (text: String, symbol: String, working: Bool)? {
        switch activity {
        case .working:
            return ("working", Symbols.power, true)
        case .barelyUsed(let upSince):
            return ("up \(Format.span(now.timeIntervalSince(upSince))), mostly idle", Symbols.moon, false)
        case .idle(let since):
            let quiet = now.timeIntervalSince(since)
            guard quiet >= pillThreshold else { return nil }
            return ("idle \(Format.span(quiet))", Symbols.moon, false)
        }
    }

    /// "working", "idle 12 min", "mostly idle", or nil for a moment of quiet.
    static func processDetail(_ process: DevProcess, now: Date) -> String? {
        switch process.activity {
        case .working:
            return "working"
        case .barelyUsed:
            return "mostly idle"
        case .idle(let since):
            let quiet = now.timeIntervalSince(since)
            return quiet >= 60 ? "idle \(Format.span(quiet))" : nil
        }
    }
}
