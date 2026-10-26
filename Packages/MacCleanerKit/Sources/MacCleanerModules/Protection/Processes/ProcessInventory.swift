import Darwin
import Foundation
import MacCleanerCore

/// One running process, as libproc describes it.
public struct ProcessRecord: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let parent: Int32
    public let uid: uid_t
    public let name: String
    /// The executable, when the process let us read it (other users' processes do not).
    public let path: String?
    public let started: Date?
    public var id: Int32 { pid }

    public init(pid: Int32, parent: Int32, uid: uid_t, name: String, path: String?, started: Date?) {
        self.pid = pid
        self.parent = parent
        self.uid = uid
        self.name = name
        self.path = path
        self.started = started
    }
}

/// Raw counters of a process at one instant.
public struct ProcessCounters: Sendable, Equatable {
    public var cpuNanoseconds: UInt64 = 0     // user + system
    public var memory: UInt64 = 0             // physical footprint
    public var diskRead: UInt64 = 0
    public var diskWritten: UInt64 = 0
    public var threads: Int = 0

    public init() {}
}

/// Lists processes and reads their counters with public libproc calls.
public enum ProcessInventory {
    public static func pids() -> [Int32] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var buffer = [Int32](repeating: 0, count: Int(count) / MemoryLayout<Int32>.size + 16)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return [] }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<Int32>.size)).filter { $0 > 0 }
    }

    public static func record(_ pid: Int32) -> ProcessRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafePointer(to: &info.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) * 2 + 1) { String(cString: $0) }
        }
        let comm = withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        let started = info.pbi_start_tvsec > 0 ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)) : nil
        return ProcessRecord(pid: pid, parent: Int32(info.pbi_ppid), uid: info.pbi_uid,
                             name: name.isEmpty ? comm : name, path: path(pid), started: started)
    }

    public static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func counters(_ pid: Int32) -> ProcessCounters? {
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else { return nil }
        var counters = ProcessCounters()
        // The task times are in Mach absolute time units (not nanoseconds on Apple silicon).
        counters.cpuNanoseconds = toNanoseconds(task.pti_total_user + task.pti_total_system)
        counters.memory = task.pti_resident_size
        counters.threads = Int(task.pti_threadnum)
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if result == 0 {
            counters.memory = usage.ri_phys_footprint
            counters.diskRead = usage.ri_diskio_bytesread
            counters.diskWritten = usage.ri_diskio_byteswritten
        }
        return counters
    }

    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func toNanoseconds(_ units: UInt64) -> UInt64 {
        timebase.denom == 0 ? units : units * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    public static func all() -> [ProcessRecord] {
        pids().compactMap(record)
    }
}
