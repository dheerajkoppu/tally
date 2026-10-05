import Foundation
import Combine

/// Tally Wrapped: the year's history summed up, offered through December and January.
@MainActor
public final class WrappedModel: ObservableObject {
    public static let shared = WrappedModel()

    /// Days of history a year needs before its Wrapped is offered.
    public static let minimumDays = 7
    private static let reloadInterval: TimeInterval = 3600

    /// The year in season, once loaded, if it has enough history.
    @Published public private(set) var summary: YearSummary?
    private var loadedYear: Int?
    private var loadedAt = Date.distantPast
    private var isLoading = false

    private init() {}

    /// `--wrapped 2026` offers that year whatever the date, for previewing it.
    private static let forcedYear: Int? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--wrapped"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }()

    /// The year Wrapped covers on a date: the current one in December, the one just ended in January.
    public nonisolated static func year(on date: Date, calendar: Calendar = .current) -> Int? {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year else { return nil }
        switch components.month {
        case 12: return year
        case 1: return year - 1
        default: return nil
        }
    }

    /// Loads the summary off the main thread, at most once an hour since it reads the whole year.
    public func refresh(now: Date = Date()) {
        guard let year = Self.forcedYear ?? Self.year(on: now), let history = TallyStore.shared.history else {
            if summary != nil { summary = nil }
            return
        }
        guard !isLoading, loadedYear != year || now.timeIntervalSince(loadedAt) >= Self.reloadInterval else { return }
        isLoading = true
        Task.detached(priority: .utility) {
            let loaded = history.yearSummary(year: year)
            await MainActor.run {
                self.isLoading = false
                self.loadedYear = year
                self.loadedAt = now
                let summary = loaded.flatMap { $0.activeDays >= Self.minimumDays ? $0 : nil }
                if summary != self.summary { self.summary = summary }
            }
        }
    }
}
