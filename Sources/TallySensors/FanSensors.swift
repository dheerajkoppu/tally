import Foundation
import TallyCore

/// Fan speeds from the SMC. Macs without fans report no FNum key, which reads as an empty list.
/// Not thread-safe; the owner serializes access.
final class FanSensors {
    private static let maximumFans = 8

    private let smc: SMCConnection
    private var names: [Int: String] = [:]
    /// The fan count and each fan's rated maximum never change, so they are read once.
    private var count: Int?
    private var maximums: [Int: Double] = [:]

    init(smc: SMCConnection) {
        self.smc = smc
    }

    func read() -> [FanReading] {
        let count = self.count ?? min(Int(smc.value("FNum") ?? 0), Self.maximumFans)
        self.count = count
        guard count >= 1 else { return [] }
        return (0..<count).compactMap { index in
            guard let actual = smc.value("F\(index)Ac"), actual.isFinite, actual < 20_000 else { return nil }
            let minimum = smc.value("F\(index)Mn") ?? 0
            let maximum = maximums[index] ?? smc.value("F\(index)Mx") ?? 0
            if maximum > 0 { maximums[index] = maximum }
            return FanReading(
                id: index,
                name: name(forFan: index, of: count),
                rpm: max(0, actual),
                minRPM: minimum.isFinite ? max(0, minimum) : 0,
                maxRPM: maximum.isFinite ? max(0, maximum) : 0
            )
        }
    }

    private func name(forFan index: Int, of count: Int) -> String {
        if let cached = names[index] { return cached }
        let name = identifiedName(forFan: index) ?? (count == 1 ? "Fan" : "Fan \(index + 1)")
        names[index] = name
        return name
    }

    /// Intel Macs describe each fan in F<n>ID, with the name as text after a four-byte header.
    private func identifiedName(forFan index: Int) -> String? {
        guard let raw = smc.rawValue("F\(index)ID"), raw.bytes.count > 4 else { return nil }
        let text = String(decoding: raw.bytes.dropFirst(4).filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        if lowered.contains("left") { return "Left Fan" }
        if lowered.contains("right") { return "Right Fan" }
        if lowered.contains("exhaust") { return "Exhaust Fan" }
        return text.localizedCapitalized
    }
}
