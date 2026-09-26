import Foundation
import TallyCore

/// CPU, memory, disk, network, GPU and battery for the whole Mac.
public final class SystemSampler: SystemSampling, DemandAware {
    private let lock = NSLock()
    private let cpu = CPUReader()
    private let memory = MemoryReader()
    private let disk = DiskReader()
    private let network = NetworkReader()
    private let gpu: GPUReader
    private let battery = BatteryReader()

    public init() {
        gpu = GPUReader(chipName: cpu.chipName)
    }

    public func setDemand(_ demand: SamplingDemand) {
        lock.lock()
        disk.isVisible = demand.isVisible
        battery.isVisible = demand.isVisible
        network.isVisible = demand.isVisible
        lock.unlock()
    }

    public func sample() -> SystemSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = SystemSnapshot()
        snapshot.date = Date()
        snapshot.cpu = cpu.read()
        snapshot.memory = memory.read()
        snapshot.disk = disk.read()
        snapshot.network = network.read()
        snapshot.gpu = gpu.read()
        snapshot.battery = battery.read()
        snapshot.uptime = MachineInfo.uptime()
        snapshot.machineName = MachineInfo.name
        return snapshot
    }
}
