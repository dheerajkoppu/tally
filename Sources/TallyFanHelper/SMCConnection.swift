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

/// A connection to the System Management Controller. Reading works for any user; writing needs root.
final class SMCConnection {
    struct KeyInfo {
        var size: Int
        var type: String
        var attributes: UInt8
    }

    enum WriteError: Error, CustomStringConvertible {
        case unknownKey(String)
        case wrongSize(String, expected: Int, given: Int)
        case rejected(String, kern_return_t, UInt8)

        var description: String {
            switch self {
            case .unknownKey(let key): "The SMC has no key \(key)"
            case .wrongSize(let key, let expected, let given): "\(key) takes \(expected) bytes, not \(given)"
            case .rejected(let key, kIOReturnNotPrivileged, _): "Writing \(key) needs the helper to run as root"
            case .rejected(let key, let status, let result): String(format: "The SMC refused to write %@ (status 0x%x, result %d)", key, status, result)
            }
        }
    }

    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private static let structSelector: UInt32 = 2

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo?] = [:]

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

    private func call(_ input: inout SMCParameters) -> (status: kern_return_t, output: SMCParameters) {
        var output = SMCParameters()
        var outputSize = MemoryLayout<SMCParameters>.stride
        let status = IOConnectCallStructMethod(connection, Self.structSelector, &input, MemoryLayout<SMCParameters>.stride, &output, &outputSize)
        return (status, output)
    }

    func info(_ name: String) -> KeyInfo? {
        let key = Self.code(name)
        if let cached = infoCache[key] { return cached }
        var input = SMCParameters()
        input.key = key
        input.command = Command.keyInfo.rawValue
        let (status, output) = call(&input)
        let info = status == kIOReturnSuccess && output.result == 0
            ? KeyInfo(size: Int(output.keyInfo.dataSize), type: Self.name(output.keyInfo.dataType), attributes: output.keyInfo.dataAttributes)
            : nil
        infoCache[key] = .some(info)
        return info
    }

    func read(_ name: String) -> (info: KeyInfo, bytes: [UInt8])? {
        guard let info = info(name), info.size > 0, info.size <= 32 else { return nil }
        var input = SMCParameters()
        input.key = Self.code(name)
        input.keyInfo.dataSize = UInt32(info.size)
        input.command = Command.readKey.rawValue
        let (status, output) = call(&input)
        guard status == kIOReturnSuccess, output.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(info.size)) }
        return (info, bytes)
    }

    func value(_ name: String) -> Double? {
        guard let raw = read(name) else { return nil }
        return SMCValue.decode(raw.bytes, type: raw.info.type)
    }

    func write(_ name: String, bytes: [UInt8]) throws {
        guard let info = info(name) else { throw WriteError.unknownKey(name) }
        guard info.size == bytes.count else { throw WriteError.wrongSize(name, expected: info.size, given: bytes.count) }
        var input = SMCParameters()
        input.key = Self.code(name)
        input.keyInfo.dataSize = UInt32(info.size)
        input.command = Command.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        let (status, output) = call(&input)
        guard status == kIOReturnSuccess, output.result == 0 else { throw WriteError.rejected(name, status, output.result) }
    }

    var keyCount: Int { value("#KEY").map { Int($0) } ?? 0 }

    func key(at index: Int) -> String? {
        var input = SMCParameters()
        input.command = Command.keyAtIndex.rawValue
        input.data32 = UInt32(index)
        let (status, output) = call(&input)
        guard status == kIOReturnSuccess, output.result == 0 else { return nil }
        return Self.name(output.key)
    }
}

/// Encodes and decodes the SMC's numeric types: little-endian floats on Apple silicon, big-endian integers and fixed point on Intel.
enum SMCValue {
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "flag":
            return bytes.first.map { Double($0) }
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
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

    static func encode(_ value: Double, type: String, size: Int) -> [UInt8]? {
        switch type {
        case "flt ":
            guard size == 4 else { return nil }
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
        case "ui8 ", "flag":
            guard size == 1, value >= 0, value <= 255 else { return nil }
            return [UInt8(value)]
        case "ui16":
            guard size == 2, value >= 0, value <= 65535 else { return nil }
            let raw = UInt16(value)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        default:
            let characters = Array(type)
            guard type.hasPrefix("fp"), characters.count == 4, size == 2, let fractionBits = characters[3].hexDigitValue else { return nil }
            let scaled = (value * Double(1 << fractionBits)).rounded()
            guard scaled >= 0, scaled <= 65535 else { return nil }
            let raw = UInt16(scaled)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
