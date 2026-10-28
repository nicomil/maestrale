import Darwin
import Foundation
import IOKit.ps

/// A snapshot of the Mac's health for the menu bar monitor.
public struct SystemSnapshot: Sendable {
    public let cpuUsage: Double          // 0...1, all cores
    public let memoryUsed: UInt64        // app + wired + compressed
    public let memoryTotal: UInt64
    public let diskFree: Int64           // space available for important usage
    public let diskTotal: Int64
    public let batteryLevel: Double?     // 0...1, nil on desktops
    public let isCharging: Bool

    public var memoryPressure: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
    public var diskUsedFraction: Double { diskTotal == 0 ? 0 : 1 - Double(diskFree) / Double(diskTotal) }
}

/// Reads CPU, memory, disk and battery with public APIs. Keep one instance:
/// CPU usage is measured between two calls.
public final class SystemMonitor: @unchecked Sendable {
    private var previousTicks: (used: UInt64, total: UInt64)?
    private let lock = NSLock()

    public init() {}

    public func snapshot() -> SystemSnapshot {
        let memory = Self.memory()
        let disk = Self.disk()
        let battery = Self.battery()
        return SystemSnapshot(cpuUsage: cpu(), memoryUsed: memory.used, memoryTotal: memory.total,
                              diskFree: disk.free, diskTotal: disk.total,
                              batteryLevel: battery.level, isCharging: battery.charging)
    }

    private func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice, total = used + idle
        lock.lock(); defer { lock.unlock() }
        defer { previousTicks = (used, total) }
        guard let previous = previousTicks, total > previous.total else { return 0 }
        return Double(used - previous.used) / Double(total - previous.total)
    }

    /// Activity Monitor's "Cached Files": file-backed pages plus purgeable
    /// memory, what `purge` throws away.
    static func cachedFiles() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * UInt64(getpagesize())
    }

    static func memory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(getpagesize())
        // Same idea as Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    static func disk() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    static func battery() -> (level: Double?, charging: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            return (Double(current) / Double(max), charging)
        }
        return (nil, false)
    }
}
