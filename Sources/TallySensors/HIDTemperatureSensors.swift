import Foundation
import IOKit

private typealias CreateClient = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
private typealias CopyProperty = @convention(c) (UnsafeMutableRawPointer, CFString) -> UnsafeMutableRawPointer?
private typealias CopyEvent = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
private typealias GetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

/// The private IOHIDEventSystemClient functions, looked up at run time so a missing symbol degrades to "no sensors".
private struct HIDFunctions {
    let createClient: CreateClient
    let setMatching: SetMatching
    let copyServices: CopyServices
    let copyProperty: CopyProperty
    let copyEvent: CopyEvent
    let getFloatValue: GetFloatValue

    static let shared: HIDFunctions? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func load<Function>(_ name: String, as type: Function.Type) -> Function? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard
            let createClient = load("IOHIDEventSystemClientCreate", as: CreateClient.self),
            let setMatching = load("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
            let copyServices = load("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
            let copyProperty = load("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
            let copyEvent = load("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
            let getFloatValue = load("IOHIDEventGetFloatValue", as: GetFloatValue.self)
        else { return nil }
        return HIDFunctions(createClient: createClient, setMatching: setMatching, copyServices: copyServices, copyProperty: copyProperty, copyEvent: copyEvent, getFloatValue: getFloatValue)
    }()
}

/// Apple silicon temperature sensors published through the HID event system (usage page 0xff00, usage 5).
/// Not thread-safe; the owner serializes access.
final class HIDTemperatureSensors {
    struct Sensor {
        var name: String
        var label: TemperatureLabel
        fileprivate var service: UnsafeMutableRawPointer
    }

    private static let temperatureEventType: Int64 = 15
    private static let temperatureField = Int32(15 << 16)

    private let functions: HIDFunctions
    private let client: UnsafeMutableRawPointer
    /// Retains the service objects the sensors point into.
    private let serviceArray: CFArray
    let sensors: [Sensor]
    /// Every service name, including the ones not read, for diagnostics.
    let allServiceNames: [String]

    init?() {
        guard let functions = HIDFunctions.shared, let client = functions.createClient(kCFAllocatorDefault) else { return nil }
        let matching = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary
        _ = functions.setMatching(client, matching)
        guard let serviceArray = functions.copyServices(client)?.takeRetainedValue() else {
            Unmanaged<AnyObject>.fromOpaque(client).release()
            return nil
        }
        self.functions = functions
        self.client = client
        self.serviceArray = serviceArray

        var sensors: [Sensor] = []
        var names: [String] = []
        var seenNames = Set<String>()
        for index in 0..<CFArrayGetCount(serviceArray) {
            guard let pointer = CFArrayGetValueAtIndex(serviceArray, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: pointer)
            guard let property = functions.copyProperty(service, "Product" as CFString) else { continue }
            guard let name = Unmanaged<AnyObject>.fromOpaque(property).takeRetainedValue() as? String else { continue }
            names.append(name)
            // Several PMUs publish identical copies of the same sensor; one of each is enough.
            guard let label = Self.label(forServiceNamed: name), seenNames.insert(name).inserted else { continue }
            sensors.append(Sensor(name: name, label: label, service: service))
        }
        self.sensors = sensors
        self.allServiceNames = names
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(client).release()
    }

    static func label(forServiceNamed name: String) -> TemperatureLabel? {
        if name.hasPrefix("pACC MTR Temp Sensor") { return .performanceCores }
        if name.hasPrefix("eACC MTR Temp Sensor") { return .efficiencyCores }
        if name.hasPrefix("GPU MTR Temp Sensor") { return .gpu }
        if name.hasPrefix("SOC MTR Temp Sensor") { return .soc }
        if name.hasPrefix("ANE MTR Temp Sensor") { return .neuralEngine }
        if name.hasPrefix("NAND CH") { return .ssd }
        if name == "gas gauge battery" { return .battery }
        if name.hasPrefix("PMU tdie") { return .powerManager }
        return nil
    }

    func celsius(of sensor: Sensor) -> Double? {
        guard let event = functions.copyEvent(sensor.service, Self.temperatureEventType, 0, 0) else { return nil }
        defer { Unmanaged<AnyObject>.fromOpaque(event).release() }
        let value = functions.getFloatValue(event, Self.temperatureField)
        return value.isFinite ? value : nil
    }
}
