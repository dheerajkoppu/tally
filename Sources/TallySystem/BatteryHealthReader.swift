import Foundation

/// The Maximum Capacity figure System Settings shows. macOS works it out with its own battery model, a few percent
/// away from the raw capacity ratio, so it is asked for once every few hours on a background queue and reused.
final class BatteryHealthReader {
    private static let lifetime: TimeInterval = 6 * 3600
    private static let retryDelay: TimeInterval = 600
    private static let timeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "tally.battery.health", qos: .background)
    private let lock = NSLock()
    private var percent: Double?
    private var nextRequest: TimeInterval = -.infinity

    /// The latest figure, or nil until the first answer arrives. Starts a refresh when the figure is due.
    func current(now: TimeInterval) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if now >= nextRequest {
            nextRequest = now + Self.retryDelay
            queue.async { [weak self] in
                guard let value = Self.readSystemFigure() else { return }
                self?.store(value, now: MonotonicClock.now())
            }
        }
        return percent
    }

    private func store(_ value: Double, now: TimeInterval) {
        lock.lock()
        percent = value
        nextRequest = now + Self.lifetime
        lock.unlock()
    }

    /// Runs system_profiler with its output going to a temporary file, so a stuck helper can never block a pipe read.
    private static func readSystemFigure() -> Double? {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("tally-power-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .background
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            return nil
        }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: outputURL) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for section in sections {
            guard let health = section["sppower_battery_health_info"] as? [String: Any],
                  let text = health["sppower_battery_health_maximum_capacity"] as? String else { continue }
            let digits = text.filter(\.isNumber)
            if let value = Double(digits), value > 0, value <= 100 { return value }
        }
        return nil
    }
}
