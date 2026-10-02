import Foundation
import IOKit
import TallyCore

/// Each NVMe drive's SMART health log: wear, lifetime reads and writes, and warnings the drive raises about itself.
/// The figures move slowly, so they are read on a background queue every minute while a window shows them, and reused.
final class DriveHealthReader {
    private static let refreshVisible: TimeInterval = 60
    private static let refreshHidden: TimeInterval = 1800

    /// UUIDs from IOCFPlugIn.h and NVMeSMARTLibExternal.h, whose macros Swift does not import.
    private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let smartUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    private static let smartInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    /// IONVMeSMARTInterface starts with the four IUnknown pointers and two UInt16 version fields, then SMARTReadData.
    private static let readDataOffset = MemoryLayout<IUnknownVTbl>.size + 8
    private static let logSize = 512

    private let queue = DispatchQueue(label: "tally.system.drive-health", qos: .background)
    private let lock = NSLock()
    private var drives: [DriveHealth] = []
    private var readAt: TimeInterval = -.infinity
    private var isReading = false

    init() {
        isReading = true
        startReading()
    }

    /// The latest figures. Starts a refresh in the background when they are due.
    func current(now: TimeInterval, isVisible: Bool) -> [DriveHealth] {
        lock.lock()
        let isAwaitingFirst = readAt == -.infinity
        lock.unlock()
        // The first read is waited for, so drives arrive with the first sample instead of appearing a sample later.
        if isAwaitingFirst { queue.sync {} }

        lock.lock()
        let isDue = !isReading && now - readAt >= (isVisible ? Self.refreshVisible : Self.refreshHidden)
        if isDue { isReading = true }
        let latest = drives
        lock.unlock()
        if isDue { startReading() }
        return latest
    }

    private func startReading() {
        queue.async { [weak self] in
            let drives = Self.readDrives()
            guard let self else { return }
            self.lock.lock()
            self.drives = drives
            self.readAt = MonotonicClock.now()
            self.isReading = false
            self.lock.unlock()
        }
    }

    private static func readDrives() -> [DriveHealth] {
        let matching = [kIOPropertyMatchKey: ["NVMe SMART Capable": true]] as CFDictionary
        var drives: [DriveHealth] = []
        for device in IORegistry.services(matching: matching) {
            defer { IOObjectRelease(device) }
            guard let log = readLog(device) else { continue }
            let characteristics = IORegistry.property(device, "Device Characteristics") as? [String: Any]
            let protocolCharacteristics = IORegistry.searchParents(device, "Protocol Characteristics") as? [String: Any]
            let model = RegistryValue.string(characteristics?["Product Name"]) ?? RegistryValue.string(IORegistry.searchParents(device, "Model Number")) ?? "SSD"
            drives.append(parse(
                log,
                id: RegistryValue.string(characteristics?["Serial Number"]) ?? String(IORegistry.entryID(device)),
                model: model,
                isInternal: (protocolCharacteristics?["Physical Interconnect Location"] as? String) == "Internal"
            ))
        }
        return drives.sorted { lhs, rhs in
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
    }

    /// The 512-byte SMART / Health Information log page, through the NVMe SMART plug-in macOS ships for this.
    private static func readLog(_ device: io_service_t) -> [UInt8]? {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(device, smartUserClientTypeID, plugInInterfaceID, &plugIn, &score) == KERN_SUCCESS,
              let plugIn, let plugInTable = plugIn.pointee?.pointee else { return nil }
        defer { IODestroyPlugInInterface(plugIn) }

        var interface: LPVOID?
        guard plugInTable.QueryInterface(plugIn, CFUUIDGetUUIDBytes(smartInterfaceID), &interface) == 0, let interface else { return nil }
        let table = interface.load(as: UnsafeRawPointer.self)
        defer { _ = table.load(as: IUnknownVTbl.self).Release(interface) }

        typealias ReadData = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
        guard let readData = table.load(fromByteOffset: readDataOffset, as: ReadData?.self) else { return nil }
        var log = [UInt8](repeating: 0, count: logSize)
        let result = log.withUnsafeMutableBytes { readData(interface, $0.baseAddress) }
        return result == kIOReturnSuccess ? log : nil
    }

    /// Field offsets from the NVMe base specification. Counters are 128-bit; the low half holds any real value.
    static func parse(_ log: [UInt8], id: String, model: String, isInternal: Bool) -> DriveHealth {
        func counter(_ offset: Int) -> UInt64 {
            log.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        }
        // Data units are thousands of 512-byte blocks.
        func dataUnitBytes(_ offset: Int) -> UInt64 {
            let product = counter(offset).multipliedReportingOverflow(by: 512_000)
            return product.overflow ? .max : product.partialValue
        }
        return DriveHealth(
            id: id,
            model: model,
            isInternal: isInternal,
            percentageUsed: Int(log[5]),
            availableSparePercent: Int(log[3]),
            availableSpareThreshold: Int(log[4]),
            hasCriticalWarning: log[0] != 0,
            mediaErrors: counter(160),
            bytesRead: dataUnitBytes(32),
            bytesWritten: dataUnitBytes(48),
            powerOnHours: counter(128),
            powerCycles: counter(112),
            unsafeShutdowns: counter(144)
        )
    }

}
