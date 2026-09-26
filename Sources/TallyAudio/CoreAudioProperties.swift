import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    var operation: String
    var status: OSStatus

    var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((UInt32(bitPattern: status) >> $0) & 0xFF) }
        let isPrintable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        let code = isPrintable ? "'\(String(decoding: bytes, as: UTF8.self))'" : "\(status)"
        return "\(operation) failed (\(code))"
    }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
}

/// Typed reads of Core Audio object properties.
enum AudioProperty {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var propertyAddress = address(selector, scope: scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &result)
        return status == noErr ? result : nil
    }

    static func array<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of type: T.Type) -> [T] {
        var propertyAddress = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &propertyAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, buffer) == noErr else { return [] }
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &result)
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let device = value(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        guard let device, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func streamFormat(tap: AudioObjectID) -> AudioStreamBasicDescription? {
        value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
    }
}
