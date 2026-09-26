import Foundation
import IOKit

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimits {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuLimit: UInt32 = 0
    var gpuLimit: UInt32 = 0
    var memoryLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

/// Mirrors the driver's 80-byte SMCParamStruct.
private struct SMCParameters {
    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimits = SMCPowerLimits()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
}

/// A connection to the System Management Controller, which owns the fans and most temperature sensors.
/// Not thread-safe; the owner serializes access.
final class SMCConnection {
    struct KeyInfo {
        var size: Int
        var type: String
    }

    private enum Command: UInt8 {
        case readKey = 5
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private static let structSelector: UInt32 = 2

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo?] = [:]
    private var cachedKeyCount: Int?

    init?() {
        guard MemoryLayout<SMCParameters>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    static func code(_ name: String) -> UInt32 {
        name.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func name(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF), UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    private func call(_ input: inout SMCParameters) -> SMCParameters? {
        var output = SMCParameters()
        var outputSize = MemoryLayout<SMCParameters>.stride
        let status = IOConnectCallStructMethod(connection, Self.structSelector, &input, MemoryLayout<SMCParameters>.stride, &output, &outputSize)
        guard status == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    func info(for key: UInt32) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var input = SMCParameters()
        input.key = key
        input.command = Command.keyInfo.rawValue
        let info = call(&input).map { KeyInfo(size: Int($0.keyInfo.dataSize), type: Self.name($0.keyInfo.dataType)) }
        infoCache[key] = .some(info)
        return info
    }

    func rawValue(for key: UInt32) -> (type: String, bytes: [UInt8])? {
        guard let info = info(for: key), info.size > 0, info.size <= 32 else { return nil }
        var input = SMCParameters()
        input.key = key
        input.keyInfo.dataSize = UInt32(info.size)
        input.command = Command.readKey.rawValue
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return (info.type, bytes)
    }

    func value(for key: UInt32) -> Double? {
        guard let raw = rawValue(for: key) else { return nil }
        return Self.decode(raw.bytes, type: raw.type)
    }

    func value(_ name: String) -> Double? {
        value(for: Self.code(name))
    }

    func rawValue(_ name: String) -> (type: String, bytes: [UInt8])? {
        rawValue(for: Self.code(name))
    }

    var keyCount: Int {
        if let cachedKeyCount { return cachedKeyCount }
        let count = value("#KEY").map { Int($0) } ?? 0
        cachedKeyCount = count
        return count
    }

    func key(at index: Int) -> UInt32? {
        var input = SMCParameters()
        input.command = Command.keyAtIndex.rawValue
        input.data32 = UInt32(index)
        return call(&input)?.key
    }

    /// The SMC keeps its keys sorted, so every key starting with one letter sits in one contiguous index range.
    func keys(startingWith letter: Character) -> [UInt32] {
        let count = keyCount
        guard count > 0, let ascii = letter.asciiValue, ascii < 0x7F else { return [] }
        let lowerBound = UInt32(ascii) << 24
        let upperBound = UInt32(ascii + 1) << 24

        func firstIndex(notBelow bound: UInt32) -> Int {
            var low = 0
            var high = count
            while low < high {
                let middle = (low + high) / 2
                if let key = key(at: middle), key < bound {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return low
        }

        let start = firstIndex(notBelow: lowerBound)
        let end = firstIndex(notBelow: upperBound)
        guard start < end else { return [] }
        return (start..<end).compactMap { key(at: $0) }.filter { $0 >= lowerBound && $0 < upperBound }
    }

    /// Decodes the SMC's numeric data types: little-endian floats on Apple silicon, big-endian fixed point on Intel.
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return bytes.first.map { Double($0) }
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        default:
            let characters = Array(type)
            guard characters.count == 4, bytes.count >= 2, let fractionBits = characters[3].hexDigitValue else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let scale = Double(1 << fractionBits)
            if type.hasPrefix("fp") { return Double(raw) / scale }
            if type.hasPrefix("sp") { return Double(Int16(bitPattern: raw)) / scale }
            return nil
        }
    }
}
