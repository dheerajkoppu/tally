import Foundation
import IOKit

/// Reads and forces fan speeds through the SMC.
///
/// Apple silicon: `Ftst` (ui8) unlocks manual control, `F<n>Md` (ui8) is 0 automatic / 1 manual and `F<n>Tg` (flt,
/// little-endian) is the target. Intel: `F<n>Md` where present, otherwise the `FS! ` (ui16) bitmask of forced fans,
/// with `F<n>Tg` in fpe2. Every write is encoded from the key's own type and size as the SMC reports them.
final class FanDriver {
    struct Fan {
        var id: Int
        var rpm: Double
        var minimum: Double
        var maximum: Double
        var target: Double
        var isManual: Bool
        var isForcedByHelper: Bool

        /// JSONSerialization raises an uncatchable exception on NaN or infinity, which an SMC float can hold.
        var dictionary: [String: Any] {
            func number(_ value: Double) -> Double { value.isFinite ? value.rounded() : 0 }
            return ["id": id, "rpm": number(rpm), "min": number(minimum), "max": number(maximum), "target": number(target), "manual": isManual, "forced": isForcedByHelper]
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case noSuchFan(Int)
        case unsupported(String)
        case smc(SMCConnection.WriteError)

        var description: String {
            switch self {
            case .noSuchFan(let fan): "This Mac has no fan \(fan)"
            case .unsupported(let reason): reason
            case .smc(let error): error.description
            }
        }
    }

    private static let maximumFans = 8
    private static let unlockKey = "Ftst"
    private static let forceMaskKey = "FS! "
    /// The SMC takes a moment to hand a fan over after `Ftst` is set, so mode writes are retried briefly.
    private static let modeWriteAttempts = 20
    private static let modeWriteRetryDelay: useconds_t = 100_000

    let fanCount: Int
    let isDryRun: Bool
    private let smc: SMCConnection
    private let log: (String) -> Void
    private(set) var forcedFans: [Int: Double] = [:]

    init(smc: SMCConnection, dryRun: Bool, log: @escaping (String) -> Void) {
        self.smc = smc
        self.isDryRun = dryRun
        self.log = log
        fanCount = min(Int(smc.value("FNum") ?? 0), Self.maximumFans)
    }

    private var hasUnlockKey: Bool { smc.info(Self.unlockKey) != nil }
    private func hasModeKey(_ fan: Int) -> Bool { smc.info("F\(fan)Md") != nil }

    func status() -> [Fan] {
        (0..<fanCount).map { fan in
            let forcedTarget = forcedFans[fan]
            let smcManual = isManualInSMC(fan)
            return Fan(
                id: fan,
                rpm: max(0, smc.value("F\(fan)Ac") ?? 0),
                minimum: max(0, smc.value("F\(fan)Mn") ?? 0),
                maximum: max(0, smc.value("F\(fan)Mx") ?? 0),
                target: isDryRun ? (forcedTarget ?? smc.value("F\(fan)Tg") ?? 0) : (smc.value("F\(fan)Tg") ?? 0),
                isManual: isDryRun ? (forcedTarget != nil || smcManual) : smcManual,
                isForcedByHelper: forcedTarget != nil
            )
        }
    }

    private func isManualInSMC(_ fan: Int) -> Bool {
        if hasModeKey(fan) { return (smc.value("F\(fan)Md") ?? 0) >= 1 }
        return (Int(smc.value(Self.forceMaskKey) ?? 0) >> fan) & 1 == 1
    }

    /// Forces a fan to a speed, clamped to its minimum and maximum. Returns the speed written.
    @discardableResult
    func setManual(_ fan: Int, rpm: Double) throws -> Double {
        guard fan >= 0, fan < fanCount else { throw Failure.noSuchFan(fan) }
        let minimum = max(0, smc.value("F\(fan)Mn") ?? 0)
        let maximum = smc.value("F\(fan)Mx") ?? 0
        guard maximum > minimum else { throw Failure.unsupported("Fan \(fan) reports no speed range") }
        let clamped = min(max(rpm, minimum), maximum).rounded()

        if forcedFans.isEmpty, hasUnlockKey {
            try write(Self.unlockKey, value: 1)
        }
        if forcedFans[fan] == nil || (!isDryRun && !isManualInSMC(fan)) {
            do {
                try hold(fan, manual: true)
            } catch {
                if forcedFans.isEmpty, hasUnlockKey { try? write(Self.unlockKey, value: 0) }
                throw error
            }
        }
        forcedFans[fan] = clamped
        try write("F\(fan)Tg", value: clamped)
        return clamped
    }

    func setAuto(_ fan: Int) throws {
        guard fan >= 0, fan < fanCount else { throw Failure.noSuchFan(fan) }
        try hold(fan, manual: false)
        forcedFans[fan] = nil
        if forcedFans.isEmpty, hasUnlockKey {
            try write(Self.unlockKey, value: 0)
        }
    }

    /// Puts every fan back to automatic, carrying on past failures so one bad fan cannot keep the others forced.
    func restoreAll() {
        for fan in 0..<fanCount {
            do {
                try hold(fan, manual: false)
            } catch {
                log("Could not return fan \(fan) to automatic: \(error)")
            }
        }
        forcedFans.removeAll()
        if hasUnlockKey {
            do {
                try write(Self.unlockKey, value: 0)
            } catch {
                log("Could not clear \(Self.unlockKey): \(error)")
            }
        }
    }

    private func hold(_ fan: Int, manual: Bool) throws {
        if hasModeKey(fan) {
            try writeMode(fan, manual: manual)
        } else {
            try writeForceMask(fan, forced: manual)
        }
    }

    private func writeMode(_ fan: Int, manual: Bool) throws {
        var attempt = 1
        while true {
            do {
                try write("F\(fan)Md", value: manual ? 1 : 0)
                return
            } catch Failure.smc(.rejected(_, kIOReturnSuccess, _)) where manual && attempt < Self.modeWriteAttempts {
                attempt += 1
                usleep(Self.modeWriteRetryDelay)
            }
        }
    }

    private func writeForceMask(_ fan: Int, forced: Bool) throws {
        guard smc.info(Self.forceMaskKey) != nil else { throw Failure.unsupported("This Mac does not allow fan \(fan) to be forced") }
        let current = Int(smc.value(Self.forceMaskKey) ?? 0)
        let updated = forced ? current | (1 << fan) : current & ~(1 << fan)
        try write(Self.forceMaskKey, value: Double(updated))
    }

    private func write(_ key: String, value: Double) throws {
        guard let info = smc.info(key) else { throw Failure.smc(.unknownKey(key)) }
        guard let bytes = SMCValue.encode(value, type: info.type, size: info.size) else {
            throw Failure.unsupported("Cannot encode \(value) as \(info.type) for \(key)")
        }
        let description = "\(key) \(info.type) size \(info.size) value \(value) bytes [\(SMCValue.hex(bytes))]"
        if isDryRun {
            log("dry run: would write \(description)")
            return
        }
        do {
            try smc.write(key, bytes: bytes)
            log("wrote \(description)")
        } catch let error as SMCConnection.WriteError {
            throw Failure.smc(error)
        }
    }

    /// Lists every fan key with its type, size, attributes and value, for exploring a new Mac.
    func probe() -> String {
        var lines = ["FNum = \(fanCount)"]
        var keys = [Self.unlockKey, Self.forceMaskKey]
        for fan in 0..<fanCount {
            keys += ["Ac", "Mn", "Mx", "Md", "Tg", "St", "Dc", "ID"].map { "F\(fan)\($0)" }
        }
        for key in keys {
            guard let raw = smc.read(key) else {
                lines.append("\(key)  (absent)")
                continue
            }
            let writable = raw.info.attributes & 0x40 != 0 ? "writable" : "read-only"
            let value = SMCValue.decode(raw.bytes, type: raw.info.type).map { String($0) } ?? "-"
            lines.append("\(key)  type '\(raw.info.type)' size \(raw.info.size) attributes 0x\(String(raw.info.attributes, radix: 16)) \(writable)  bytes [\(SMCValue.hex(raw.bytes))] = \(value)")
        }
        return lines.joined(separator: "\n")
    }
}
